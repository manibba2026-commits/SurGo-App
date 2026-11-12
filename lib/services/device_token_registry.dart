// Public named arguments must initialize private fields, not private formals.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../repositories/edge_functions.dart';
import '../repositories/repository_failure.dart';
import 'push_transport.dart';

/// Keeps this device's push token pointed at the account that is signed in.
/// Only the authenticated register-device-token function writes the token.
class DeviceTokenRegistry {
  DeviceTokenRegistry({
    required PushTransport transport,
    required EdgeInvoker Function() invoker,
    String? Function()? platform,
  }) : _transport = transport,
       _invokerOf = invoker,
       _platformOf = platform ?? pushPlatformName;

  static const String functionName = 'register-device-token';

  final PushTransport _transport;
  final EdgeInvoker Function() _invokerOf;
  final String? Function() _platformOf;

  EdgeInvoker? _cachedInvoker;
  StreamSubscription<String>? _rotation;
  Future<bool>? _starting;
  Future<void> _writes = Future<void>.value();
  bool _active = false;
  int _generation = 0;
  int _tokenRevision = 0;

  /// Safe diagnostics only; transport and function errors may contain tokens.
  RepositoryFailure? lastFailure;

  /// The token successfully registered by the current generation, if any.
  String? get registeredToken => _sentToken;
  String? _sentToken;

  // Retain the issued payload even if its response fails: the server may have
  // accepted it. A stop must detach this token, not a newer transport lookup.
  (String token, String platform)? _attachment;

  /// Coalesces startup and watches rotations only for this active generation.
  Future<bool> start() {
    if (!_transport.isSupported) return Future<bool>.value(false);
    if (!_active) {
      _active = true;
      _generation++;
    }
    final pending = _starting;
    if (pending != null) return pending;
    final generation = _generation;
    return _starting =
        Future<bool>.microtask(() async {
          if (!_isActive(generation)) return false;
          try {
            _rotation ??= _transport.tokenRefreshes.listen(
              (token) {
                if (_isActive(generation)) {
                  unawaited(_register(generation, rotatedToken: token));
                }
              },
              onError: (Object error, StackTrace stack) {
                if (_isActive(generation)) {
                  lastFailure = RepositoryFailure.unavailable();
                }
              },
            );
            return await _register(generation);
          } catch (_) {
            if (_isActive(generation)) {
              lastFailure = RepositoryFailure.unavailable();
            }
            return false;
          }
        }).whenComplete(() {
          if (_generation == generation) _starting = null;
        });
  }

  /// Invalidates pending lookups immediately, then orders detach after any
  /// already-issued write. A new start cannot overtake this detach.
  Future<void> stop() {
    _active = false;
    final generation = ++_generation;
    _tokenRevision++;
    _starting = null;
    _sentToken = null;
    final rotation = _rotation;
    _rotation = null;
    final attachment = _attachment;
    _attachment = null;
    final detach = _serialize(() async {
      if (!_transport.isSupported || attachment == null) return false;
      try {
        await _invoker.invoke(functionName, {
          'token': attachment.$1,
          'platform': attachment.$2,
          'active': false,
        });
        if (_generation == generation) lastFailure = null;
        return true;
      } catch (_) {
        if (_generation == generation) {
          lastFailure = RepositoryFailure.unavailable();
        }
        return false;
      }
    });
    return Future.wait<void>([
      _cancelRotation(rotation, generation),
      detach.then<void>((_) {}),
    ]).then<void>((_) {});
  }

  Future<void> _cancelRotation(
    StreamSubscription<String>? rotation,
    int generation,
  ) async {
    try {
      await rotation?.cancel();
    } catch (_) {
      if (_generation == generation) {
        lastFailure = RepositoryFailure.unavailable();
      }
    }
  }

  /// Sends the current token once; callers may also use this without a watch.
  Future<bool> register() {
    if (!_transport.isSupported) return Future<bool>.value(false);
    return _register(_generation);
  }

  Future<bool> _register(int generation, {String? rotatedToken}) async {
    final revision = ++_tokenRevision;
    bool current() => _generation == generation && _tokenRevision == revision;
    try {
      final platform = _platformOf();
      if (platform == null) {
        if (current()) lastFailure = null;
        return false;
      }
      // Lookup is not a write: stop need not wait for the device to answer.
      final token = rotatedToken ?? await _transport.token();
      if (!current()) return false;
      if (token == null || token.isEmpty) {
        lastFailure = null;
        return false;
      }
      if (_sentToken != token) _sentToken = null;
      return await _serialize(() async {
        if (!current()) return false;
        _attachment = (token, platform);
        try {
          await _invoker.invoke(functionName, {
            'token': token,
            'platform': platform,
            'active': true,
          });
          if (!current()) return false;
          lastFailure = null;
          _sentToken = token;
          return true;
        } catch (_) {
          if (current()) {
            _sentToken = null;
            lastFailure = RepositoryFailure.unavailable();
          }
          return false;
        }
      });
    } catch (_) {
      if (current()) {
        lastFailure = RepositoryFailure.unavailable();
      }
      return false;
    }
  }

  bool _isActive(int generation) => _active && _generation == generation;

  Future<bool> _serialize(Future<bool> Function() operation) {
    final result = _writes.then((_) => operation());
    // Keep the queue usable even if an unexpected operation fails.
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  EdgeInvoker get _invoker => _cachedInvoker ??= _invokerOf();
}

/// The `device_platform` value for the platform this binary is running on.
String? pushPlatformName([TargetPlatform? platform]) =>
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'ios',
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.fuchsia => null,
    };
