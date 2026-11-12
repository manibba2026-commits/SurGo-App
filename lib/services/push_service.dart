// Public named arguments must initialize private fields, not private formals.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';

import '../repositories/repository_failure.dart';
import 'device_token_registry.dart';
import 'push_routing.dart';
import 'push_transport.dart';

/// Routes taps for the signed-in session without making push a sign-in
/// prerequisite. The message subscription spans sessions to retain cold taps.
class PushService {
  PushService({
    required PushTransport transport,
    required DeviceTokenRegistry registry,
    required String Function() homeRoute,
    required void Function(String route) navigate,
    void Function(PushMessage message)? showInForeground,
    bool Function()? canNavigate,
  }) : _transport = transport,
       _registry = registry,
       _homeRoute = homeRoute,
       _navigate = navigate,
       _showInForeground = showInForeground,
       _canNavigate = canNavigate {
    if (_transport.isSupported) {
      try {
        _subscription = _transport.messages.listen(
          _handle,
          onError: (Object error, StackTrace stack) {
            if (!_disposed) lastFailure = RepositoryFailure.unavailable();
          },
        );
      } catch (_) {
        lastFailure = RepositoryFailure.unavailable();
      }
    }
  }

  final PushTransport _transport;
  final DeviceTokenRegistry _registry;
  final String Function() _homeRoute;
  final void Function(String route) _navigate;
  final void Function(PushMessage message)? _showInForeground;
  final bool Function()? _canNavigate;

  StreamSubscription<PushMessage>? _subscription;
  bool _sessionActive = false;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _starting;
  Future<void>? _disposing;
  final Queue<String> _pendingRoutes = Queue<String>();

  /// Safe diagnostics only; permission errors may include device information.
  RepositoryFailure? lastFailure;

  PushMessage? get lastMessage => _lastMessage;
  PushMessage? _lastMessage;

  /// The next tap awaiting sign-in or the PIN/onboarding/recovery gate.
  String? get pendingRoute =>
      _pendingRoutes.isEmpty ? null : _pendingRoutes.first;

  /// Permission refusal still permits registration. A failed permission or
  /// registration attempt is recorded, never thrown, and can be retried.
  Future<void> onSignedIn() {
    if (_disposed) return Future<void>.value();
    if (!_sessionActive) {
      _sessionActive = true;
      _generation++;
    }
    flushPending();
    if (!_transport.isSupported || _started) return Future<void>.value();
    final pending = _starting;
    if (pending != null) return pending;
    final generation = _generation;
    return _starting =
        Future<void>.microtask(() async {
          if (!_isCurrent(generation)) return;
          try {
            await _transport.requestPermission();
            if (!_isCurrent(generation)) return;
            final registered = await _registry.start();
            if (!_isCurrent(generation)) return;
            _started = registered;
            lastFailure = _registry.lastFailure == null
                ? null
                : RepositoryFailure.unavailable();
          } catch (_) {
            if (_isCurrent(generation)) {
              lastFailure = RepositoryFailure.unavailable();
            }
          }
        }).whenComplete(() {
          if (_generation == generation) _starting = null;
        });
  }

  /// Stops registration immediately; the message stream stays subscribed so
  /// signed-out taps can wait for the next authenticated, unlocked session.
  Future<void> onSignedOut() {
    if (_disposed) return _disposing ?? Future<void>.value();
    _sessionActive = false;
    _started = false;
    _starting = null;
    return _stopRegistry(++_generation);
  }

  /// Call explicitly when PIN/onboarding/recovery gates permit navigation.
  /// Checks the gate for each queued tap, including if navigation changes it.
  void flushPending() {
    try {
      while (!_disposed &&
          _sessionActive &&
          _pendingRoutes.isNotEmpty &&
          (_canNavigate?.call() ?? true)) {
        _navigate(_pendingRoutes.removeFirst());
      }
    } catch (_) {
      if (!_disposed) lastFailure = RepositoryFailure.unavailable();
    }
  }

  void _handle(PushMessage message) {
    if (_disposed) return;
    _lastMessage = message;
    try {
      if (!message.wasOpened) {
        if (_sessionActive) _showInForeground?.call(message);
        return;
      }
      _pendingRoutes.add(routeForPush(message, homeRoute: _homeRoute()));
      flushPending();
    } catch (_) {
      lastFailure = RepositoryFailure.unavailable();
    }
  }

  bool _isCurrent(int generation) =>
      !_disposed && _sessionActive && _generation == generation;

  Future<void> _stopRegistry(int generation) async {
    try {
      await _registry.stop();
      if (!_disposed && _generation == generation) {
        lastFailure = _registry.lastFailure == null
            ? null
            : RepositoryFailure.unavailable();
      }
    } catch (_) {
      if (!_disposed && _generation == generation) {
        lastFailure = RepositoryFailure.unavailable();
      }
    }
  }

  /// Invalidates async startup before cancelling messages and detaching.
  Future<void> dispose() {
    final pending = _disposing;
    if (pending != null) return pending;
    _disposed = true;
    _sessionActive = false;
    _started = false;
    _starting = null;
    _pendingRoutes.clear();
    final stop = _stopRegistry(++_generation);
    final subscription = _subscription;
    _subscription = null;
    return _disposing = Future.wait<void>([
      stop,
      _cancelMessages(subscription),
    ]).then<void>((_) {});
  }

  Future<void> _cancelMessages(
    StreamSubscription<PushMessage>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {
      // Disposal must still finish detaching even if cancellation fails.
    }
  }
}
