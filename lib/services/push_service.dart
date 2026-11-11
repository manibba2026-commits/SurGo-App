import 'dart:async';

import 'device_token_registry.dart';
import 'push_routing.dart';
import 'push_transport.dart';

/// Runs the push layer for one session.
///
/// AppState tells it when a session starts and ends; it decides what to ask
/// the device for, keeps the token pointed at the right profile, and turns a
/// tap into a route. It never reads business data and never claims a
/// notification was delivered — the server decides that.
class PushService {
  PushService({
    required this._transport,
    required this._registry,
    required this._homeRoute,
    required this._navigate,
    this._showInForeground,
  });

  final PushTransport _transport;
  final DeviceTokenRegistry _registry;
  final String Function() _homeRoute;
  final void Function(String route) _navigate;
  final void Function(PushMessage message)? _showInForeground;

  StreamSubscription<PushMessage>? _subscription;
  bool _sessionActive = false;

  /// The most recent message, for a diagnostics note.
  PushMessage? get lastMessage => _lastMessage;
  PushMessage? _lastMessage;

  /// A tap that arrived while no session was up — a cold start, or a push on a
  /// signed-out device. Consumed by the next sign-in, because the destination
  /// is a screen inside the account's own data and there is nothing to open
  /// before the session exists.
  String? get pendingRoute => _pendingRoute;
  String? _pendingRoute;

  /// Asks for permission, registers the token and starts routing taps.
  ///
  /// Permission is requested but not required for registration: a device the
  /// user silenced still has a token, and the in-app feed is what carries the
  /// message when push is refused.
  Future<void> onSignedIn() async {
    if (_sessionActive) return;
    _sessionActive = true;
    if (!_transport.isSupported) return;

    await _transport.requestPermission();
    await _registry.start();
    _subscription ??= _transport.messages.listen(_handle);

    final waiting = _pendingRoute;
    if (waiting != null) {
      _pendingRoute = null;
      _navigate(waiting);
    }
  }

  /// Detaches the token and stops routing, for sign-out.
  Future<void> onSignedOut() async {
    _sessionActive = false;
    await _subscription?.cancel();
    _subscription = null;
    await _registry.stop();
  }

  /// Only a tap moves the user. A message that arrives while the app is
  /// already open is the app's own screen to annotate, never a page to leave.
  void _handle(PushMessage message) {
    _lastMessage = message;
    if (!message.wasOpened) {
      _showInForeground?.call(message);
      return;
    }
    final route = routeForPush(message, homeRoute: _homeRoute());
    if (!_sessionActive) {
      _pendingRoute = route;
      return;
    }
    _navigate(route);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
