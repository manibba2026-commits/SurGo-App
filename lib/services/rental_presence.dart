import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db_models.dart';
import '../repositories/backend.dart';
import 'location_publisher.dart';
import 'location_service.dart';

/// The other party's last shared position on one rental.
class RentalPartnerPosition {
  const RentalPartnerPosition({
    required this.profileId,
    required this.role,
    required this.point,
    required this.seenAt,
  });

  final String profileId;

  /// `renter` or `owner`, as published by the other client.
  final String role;
  final MapPoint point;
  final DateTime seenAt;
}

/// Shares this device's position with the other party of one rental.
///
/// The channel is scoped to the booking, so only the two screens showing that
/// booking meet. Nothing is written to a table: leaving the screen removes the
/// share, and a dropped socket expires on the server.
class RentalPresenceSession {
  RentalPresenceSession({
    required this.presence,
    required this.rentalId,
    required this.profileId,
    required this.role,
    LocationService? locationService,
  }) : _location = locationService ?? LocationService.instance;

  /// Re-announced even when the device has not moved, so a peer can tell a
  /// stationary partner from a disconnected one.
  static const Duration _heartbeat = Duration(seconds: 20);

  /// The server allows five presence messages per client per thirty seconds
  /// and closes the channel past that. GPS fires far more often than a peer
  /// needs, so announcements are paced well under the limit.
  static const Duration _minPublishGap = Duration(seconds: 12);

  final SurgoPresenceBackend presence;
  final String rentalId;
  final String profileId;
  final String role;
  final LocationService _location;

  final ValueNotifier<RentalPartnerPosition?> partner =
      ValueNotifier<RentalPartnerPosition?>(null);
  final ValueNotifier<MapPoint?> ownPosition = ValueNotifier<MapPoint?>(null);

  /// False until a GPS fix arrives, so the screen can say whether this device
  /// is actually sharing or only listening.
  final ValueNotifier<bool> hasFix = ValueNotifier<bool>(false);

  SurgoPresenceSession? _channel;
  StreamSubscription<List<Map<String, dynamic>>>? _members;
  StreamSubscription<LocationFix>? _fixes;
  Timer? _heartbeatTimer;
  DateTime? _lastPublishAt;
  bool _closed = false;

  bool get isSharing => _channel != null && !_closed;

  Future<void> start() async {
    if (_closed || _channel != null) return;
    final channel = presence.joinPresence(
      channel: 'rental-$rentalId',
      key: profileId,
      self: {'profile_id': profileId, 'role': role},
    );
    _channel = channel;
    _members = channel.members.listen(_onMembers, onError: (Object _) {});
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) => _publish());
    final fixes = await _location.trackPositions();
    if (_closed || fixes == null) return;
    _fixes = fixes.listen(_onFix, onError: (Object _) {});
  }

  void _onFix(LocationFix fix) {
    if (_closed) return;
    ownPosition.value = MapPoint(fix.latitude, fix.longitude);
    if (!hasFix.value) hasFix.value = true;
    _publish();
  }

  void _publish() {
    final channel = _channel;
    if (_closed || channel == null) return;
    final now = DateTime.now();
    final last = _lastPublishAt;
    if (last != null && now.difference(last) < _minPublishGap) return;
    _lastPublishAt = now;
    final point = ownPosition.value;
    unawaited(
      channel
          .track({
            'profile_id': profileId,
            'role': role,
            'latitude': point?.latitude,
            'longitude': point?.longitude,
            'at': now.toUtc().toIso8601String(),
          })
          .catchError((Object _) {}),
    );
  }

  void _onMembers(List<Map<String, dynamic>> members) {
    if (_closed) return;
    for (final member in members) {
      if ('${member['profile_id']}' == profileId) continue;
      final latitude = (member['latitude'] as num?)?.toDouble();
      final longitude = (member['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) continue;
      partner.value = RentalPartnerPosition(
        profileId: '${member['profile_id']}',
        role: '${member['role']}',
        point: MapPoint(latitude, longitude),
        seenAt:
            DateTime.tryParse('${member['at']}')?.toLocal() ?? DateTime.now(),
      );
      return;
    }
    // The other party is connected but has not shared a fix (permission off,
    // or still waiting for GPS), so there is no position to draw.
    partner.value = null;
  }

  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final fixes = _fixes;
    _fixes = null;
    if (fixes != null) await fixes.cancel();
    final members = _members;
    _members = null;
    if (members != null) await members.cancel();
    final channel = _channel;
    _channel = null;
    await channel?.close();
  }
}
