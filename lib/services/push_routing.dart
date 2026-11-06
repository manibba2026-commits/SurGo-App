import 'push_transport.dart';

/// Where a notification tap sends the user.
///
/// The sender names a destination with `data.link`; `data.type` is the fallback
/// for a message that names its kind but not a screen. Both are answered from
/// this one table so a route is only ever one the app actually has: a link
/// invented by a misconfigured function, or sent by an old build, lands on the
/// user's own dashboard instead of pushing a route that does not exist.
///
/// The ten events SurGo sends map onto this table as:
///
/// | event                        | link          |
/// | ---------------------------- | ------------- |
/// | ride request received        | `incoming`    |
/// | rider accepted               | `trip`        |
/// | rider approaching            | `trip`        |
/// | rider arrived                | `trip`        |
/// | trip started                 | `trip`        |
/// | trip completed               | `receipt`     |
/// | cancellation                 | `trip`        |
/// | rental update                | `rental`      |
/// | pasuyo update                | `pasuyo`      |
/// | verification update          | `verification`|
///
/// A cancelled or completed trip still opens the trip screen on purpose: that
/// is where the app already explains what happened, and a receipt on a screen
/// the user cannot reach helps nobody.
String routeForPush(PushMessage message, {required String homeRoute}) {
  final link = message.link;
  if (link != null) {
    final route = _linkRoutes[link];
    if (route != null) return route == _dashboard ? homeRoute : route;
  }
  final byType = message.type == null ? null : _typeRoutes[message.type];
  if (byType != null) return byType == _dashboard ? homeRoute : byType;
  return homeRoute;
}

/// Marks the entries that mean "the user's own dashboard", resolved by the
/// caller because only the app knows which mode it is in.
const String _dashboard = '@dashboard';

const Map<String, String> _linkRoutes = {
  'incoming': _dashboard,
  'trip': '/livetrip',
  'receipt': '/livetrip',
  'chat': '/ride_chat',
  'pasuyo': '/pasuyo',
  'rental': '/active_rental',
  'verification': '/profile',
  'wallet': _dashboard,
  'promo': _dashboard,
};

const Map<String, String> _typeRoutes = {
  'ride': '/livetrip',
  'pasuyo': '/pasuyo',
  'rental': '/rental',
  'verification': '/profile',
  'payment': _dashboard,
  'wallet': _dashboard,
  'promo': _dashboard,
  'system': _dashboard,
  'safety': _dashboard,
  'rating': '/livetrip',
};
