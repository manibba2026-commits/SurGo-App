import 'dart:async';

/// What the operating system said about showing this app's notifications.
///
/// [unsupported] is not a refusal: it means no push transport is installed, so
/// the app must not ask again or explain a permission the user was never shown.
enum PushPermission { unsupported, granted, denied, notDetermined }

/// One message as the transport delivered it.
///
/// The payload is deliberately left as the server sent it. `title` and `body`
/// are what the device shows; `data` is what the app routes on, and a client
/// that invented its own meaning for a missing key would be guessing at a
/// decision the sender already made.
class PushMessage {
  const PushMessage({
    this.title = '',
    this.body = '',
    this.data = const <String, Object?>{},
    this.wasOpened = false,
  });

  final String title;
  final String body;
  final Map<String, Object?> data;

  /// True when the user tapped the notification rather than the app merely
  /// receiving it. Only a tap is allowed to change the screen.
  final bool wasOpened;

  Object? _value(String key) => data[key];

  /// Where the sender says to go, when it says anything.
  String? get link {
    final raw = _value('link');
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  /// Which kind of notification this is, using the server's own vocabulary.
  String? get type {
    final raw = _value('type');
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  String? get rideId {
    final raw = _value('ride_id');
    return raw is String && raw.isNotEmpty ? raw : null;
  }
}

/// The device-side half of push: whatever can hand this app a token and a
/// message.
///
/// Firebase Cloud Messaging is the intended implementation, installed by
/// `main` once the Firebase configuration exists. Until then the app runs on
/// [NoopPushTransport], and every caller has to cope with a transport that
/// says it cannot do the thing being asked — which is the same answer a
/// browser without notification permission gives.
abstract interface class PushTransport {
  /// Whether this build can receive push at all.
  bool get isSupported;

  /// Asks the operating system, if it has not decided yet.
  Future<PushPermission> requestPermission();

  /// The current registration token, or null when there is none yet.
  Future<String?> token();

  /// Emitted when the token changes, which FCM does on its own schedule.
  Stream<String> get tokenRefreshes;

  /// Every message, foreground arrivals and taps alike.
  Stream<PushMessage> get messages;
}

/// The transport a build without Firebase runs on.
///
/// Inert by design: nothing registers, nothing navigates, and nothing is
/// reported as an error, because a demo that has no push configured is not
/// broken.
class NoopPushTransport implements PushTransport {
  const NoopPushTransport();

  @override
  bool get isSupported => false;

  @override
  Future<PushPermission> requestPermission() async =>
      PushPermission.unsupported;

  @override
  Future<String?> token() async => null;

  @override
  Stream<String> get tokenRefreshes => const Stream<String>.empty();

  @override
  Stream<PushMessage> get messages => const Stream<PushMessage>.empty();
}
