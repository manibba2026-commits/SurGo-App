import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;

import '../repositories/edge_functions.dart';
import '../repositories/repository_failure.dart';
import 'push_transport.dart';

/// Keeps this device's push token pointed at the account that is signed in.
///
/// The token is Firebase's, the profile is Supabase's, and the only bridge is
/// `register-device-token`, called as the signed-in user so the function can
/// read the same auth subject the app just used. The client never writes
/// `device_tokens` itself — the `authenticated` role has no write privilege on
/// it — so a stolen build cannot attach its device to somebody else's account.
class DeviceTokenRegistry {
  DeviceTokenRegistry({
    required PushTransport transport,
    required EdgeInvoker Function() invoker,
    String? Function()? platform,
  })  : _transport = transport,
        _invokerOf = invoker,
        _platformOf = platform ?? pushPlatformName;

  static const String functionName = 'register-device-token';

  final PushTransport _transport;
  final EdgeInvoker Function() _invokerOf;
  final String? Function() _platformOf;

  EdgeInvoker? _cachedInvoker;
  StreamSubscription<String>? _rotation;

  /// The last failure, kept for a diagnostics note rather than a dialog.
  ///
  /// A token that could not be stored costs the user one notification on one
  /// device; it must never interrupt a sign-in or pretend to have succeeded.
  RepositoryFailure? lastFailure;

  /// The token this device last handed to the server, if any.
  String? get registeredToken => _sentToken;
  String? _sentToken;

  /// Registers the current token, and keeps registering it as FCM rotates it.
  Future<bool> start() async {
    if (!_transport.isSupported) return false;
    final registered = await register();
    _rotation ??= _transport.tokenRefreshes.listen((_) => register());
    return registered;
  }

  /// Stops listening and detaches the token from this profile.
  ///
  /// Sign-out has to deactivate rather than merely forget: a token left
  /// pointed at the account would keep delivering that person's ride and
  /// wallet messages to a device that is no longer theirs.
  Future<void> stop() async {
    await _rotation?.cancel();
    _rotation = null;
    if (!_transport.isSupported) return;
    await _send(active: false);
  }

  /// Sends the token the transport currently holds.
  Future<bool> register() async {
    if (!_transport.isSupported) return false;
    return _send(active: true);
  }

  Future<bool> _send({required bool active}) async {
    final platform = _platformOf();
    if (platform == null) {
      lastFailure = null;
      return false;
    }
    final token = await _transport.token();
    if (token == null || token.isEmpty) {
      // No token is not an error the user can act on — it is the ordinary
      // answer on a device that has not finished registering with FCM.
      lastFailure = null;
      return false;
    }
    try {
      await _invoker.invoke(functionName, {
        'token': token,
        'platform': platform,
        'active': active,
      });
      lastFailure = null;
      _sentToken = active ? token : null;
      return true;
    } catch (error) {
      lastFailure = error is RepositoryFailure
          ? error
          : RepositoryFailure(RepositoryFailureKind.unknown, '$error',
              cause: error);
      return false;
    }
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
      TargetPlatform.fuchsia =>
        null,
    };
