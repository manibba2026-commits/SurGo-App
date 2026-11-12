import 'dart:async';

import 'package:flutter/foundation.dart';

import '../repositories/backend.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/ride_location_repository.dart';
import '../repositories/ride_repository.dart';

class RideTracking extends ChangeNotifier {
  RideTracking({
    required this.rides,
    required this.locations,
    this.realtime,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const reconciliationInterval = Duration(seconds: 15);
  static const maxPositionAge = Duration(seconds: 45);
  static const maxFutureSkew = Duration(seconds: 15);

  final RideRepository rides;
  final RideLocationRepository locations;
  final SurgoRealtimeBackend? realtime;
  final DateTime Function() _clock;

  _TrackingSession? _session;
  int _generation = 0;
  bool _disposed = false;
  final List<StreamSubscription<void>> _subscriptions = [];
  final List<bool> _connected = [false, false, false];
  final List<RepositoryFailure?> _realtimeFailures = [null, null, null];
  Timer? _poll;
  Timer? _expiry;
  Timer? _presenceExpiry;
  RideLocationRecord? _position;
  RiderPresenceRecord? _presence;
  RideRecord? _latestRide;
  RepositoryFailure? _readFailure;

  RiderPresenceRecord? get presence {
    final record = _presence;
    return record != null && (record.isSimulated || _freshPresence(record))
        ? record
        : null;
  }

  /// Only a verified, fresh point is drawable. No seed or fallback coordinates.
  RideLocationRecord? get position {
    final record = _position;
    return record != null && _fresh(record) ? record : null;
  }

  bool get stale => position == null;
  RideRecord? get latestRide => _latestRide;

  bool get realtimeConnected => _connected.every((connected) => connected);

  RepositoryFailure? get failure =>
      _readFailure ??
      _realtimeFailures[0] ??
      _realtimeFailures[1] ??
      _realtimeFailures[2];

  void start(String rideId, String riderId) {
    if (_disposed) return;
    _clearSession();
    if (rideId.isEmpty || riderId.isEmpty) {
      _readFailure = RepositoryFailure.invalidData(
        'Tracking requires a ride and its assigned rider.',
      );
      notifyListeners();
      return;
    }
    final session = _TrackingSession(_generation, rideId, riderId);
    _session = session;
    notifyListeners();
    if (!_current(session)) return;
    _poll = Timer.periodic(reconciliationInterval, (_) {
      if (!_current(session)) return;
      _expirePosition();
      unawaited(_queueRefresh(session));
    });
    if (realtime != null) {
      _watch(session, 0, 'ride_locations', 'ride_id');
      if (_current(session)) _watch(session, 1, 'ride_requests', 'id');
      if (_current(session)) _watch(session, 2, 'rider_presence', 'profile_id');
    }
    if (_current(session)) unawaited(_queueRefresh(session));
  }

  /// Serial within one session. Bursts request at most one follow-up read.
  Future<void> refresh() {
    final session = _session;
    return session == null ? Future<void>.value() : _queueRefresh(session);
  }

  void _watch(
    _TrackingSession session,
    int index,
    String table,
    String column,
  ) {
    try {
      final subscription = realtime!
          .watchRows(
            table: table,
            column: column,
            value: table == 'rider_presence' ? session.riderId : session.rideId,
          )
          .listen(
            (_) {
              if (!_current(session)) return;
              _connected[index] = true;
              _realtimeFailures[index] = null;
              notifyListeners();
              unawaited(_queueRefresh(session));
            },
            onError: (Object error) {
              if (!_current(session)) return;
              _connected[index] = false;
              _realtimeFailures[index] = mapBackendError(error);
              notifyListeners();
              unawaited(_queueRefresh(session));
            },
            onDone: () {
              if (!_current(session)) return;
              _connected[index] = false;
              _realtimeFailures[index] ??= RepositoryFailure.unavailable();
              notifyListeners();
              unawaited(_queueRefresh(session));
            },
          );
      if (_current(session)) {
        _subscriptions.add(subscription);
      } else {
        _cancel(subscription);
      }
    } catch (error) {
      if (!_current(session)) return;
      _connected[index] = false;
      _realtimeFailures[index] = mapBackendError(error);
      notifyListeners();
    }
  }

  Future<void> _queueRefresh(_TrackingSession session) {
    if (!_current(session)) return Future<void>.value();
    session.pending = true;
    return session.refreshing ??= _drain(session);
  }

  Future<void> _drain(_TrackingSession session) async {
    try {
      do {
        session.pending = false;
        await _read(session);
      } while (_current(session) && session.pending);
    } finally {
      session.refreshing = null;
    }
  }

  Future<void> _read(_TrackingSession session) async {
    try {
      final ride = await rides.fetchRide(session.rideId);
      if (!_current(session)) return;
      _latestRide = ride;
      if (ride == null) {
        _setPresence(null);
        throw RepositoryFailure.notFound();
      }
      if (ride.id != session.rideId || ride.riderId != session.riderId) {
        _setPresence(null);
        throw RepositoryFailure.invalidData(
          'This ride is not assigned to the tracked rider.',
        );
      }
      if (ride.status.isTerminal) {
        _setPresence(null);
        _setPosition(null);
        _readFailure = null;
        notifyListeners();
        return;
      }
      final presence = await rides.fetchPresence(session.riderId);
      if (!_current(session)) return;
      _setPresence(
        presence != null &&
                presence.profileId == session.riderId &&
                presence.isOnline &&
                presence.latitude != null &&
                presence.longitude != null &&
                presence.latitude!.isFinite &&
                presence.longitude!.isFinite &&
                presence.latitude!.abs() <= 90 &&
                presence.longitude!.abs() <= 180 &&
                (presence.latitude != 0 || presence.longitude != 0) &&
                (presence.isSimulated || _freshPresence(presence))
            ? presence
            : null,
      );
      final records = await locations.fetchRecentPositions(
        session.rideId,
        limit: 1,
      );
      if (!_current(session)) return;
      final record = records.isEmpty ? null : records.first;
      if (record != null) {
        if (record.rideId != session.rideId ||
            record.riderId != session.riderId) {
          throw RepositoryFailure.invalidData(
            'The location does not belong to this ride and assigned rider.',
          );
        }
        if (!record.latitude.isFinite ||
            !record.longitude.isFinite ||
            !record.isTrustworthy ||
            (record.latitude == 0 && record.longitude == 0) ||
            record.recordedAt == null ||
            record.recordedAt!.difference(_clock()) > maxFutureSkew) {
          throw RepositoryFailure.invalidData('The location is not valid.');
        }
      }
      _setPosition(record != null && _fresh(record) ? record : null);
      _readFailure = null;
    } catch (error) {
      if (!_current(session)) return;
      _readFailure = mapBackendError(error);
      _setPosition(null);
    }
    if (_current(session)) notifyListeners();
  }

  bool _fresh(RideLocationRecord record) {
    final recordedAt = record.recordedAt;
    if (recordedAt == null) return false;
    final age = _clock().difference(recordedAt);
    return age <= maxPositionAge && age >= -maxFutureSkew;
  }

  bool _freshPresence(RiderPresenceRecord record) {
    final updatedAt = record.updatedAt;
    if (updatedAt == null) return false;
    final age = _clock().difference(updatedAt);
    return age <= maxPositionAge && age >= -maxFutureSkew;
  }

  void _setPresence(RiderPresenceRecord? record) {
    _presenceExpiry?.cancel();
    _presenceExpiry = null;
    _presence = record;
    final session = _session;
    if (record == null || record.isSimulated || session == null) return;
    final remaining = record.updatedAt!
        .add(maxPositionAge)
        .difference(_clock());
    _presenceExpiry = Timer(remaining + const Duration(microseconds: 1), () {
      if (!_current(session)) return;
      _setPresence(null);
      notifyListeners();
    });
  }

  void _setPosition(RideLocationRecord? record) {
    _expiry?.cancel();
    _expiry = null;
    _position = record;
    final session = _session;
    if (record == null || session == null) return;
    final remaining = record.recordedAt!
        .add(maxPositionAge)
        .difference(_clock());
    _expiry = Timer(remaining + const Duration(microseconds: 1), () {
      if (!_current(session)) return;
      _expirePosition();
    });
  }

  void _expirePosition() {
    if (_position != null && !_fresh(_position!)) {
      _setPosition(null);
      notifyListeners();
    }
  }

  bool _current(_TrackingSession session) =>
      !_disposed &&
      identical(_session, session) &&
      session.generation == _generation;

  void stop() {
    if (_disposed) return;
    _clearSession();
    notifyListeners();
  }

  void _clearSession() {
    _generation++;
    _session = null;
    _poll?.cancel();
    _poll = null;
    _expiry?.cancel();
    _expiry = null;
    _presenceExpiry?.cancel();
    _presenceExpiry = null;
    for (final subscription in _subscriptions) {
      _cancel(subscription);
    }
    _subscriptions.clear();
    _position = null;
    _presence = null;
    _latestRide = null;
    _readFailure = null;
    for (var i = 0; i < _connected.length; i++) {
      _connected[i] = false;
      _realtimeFailures[i] = null;
    }
  }

  void _cancel(StreamSubscription<void> subscription) {
    unawaited(
      subscription.cancel().catchError((Object error) {
        // Cancellation cannot report into a replacement session or disposed UI.
        debugPrint('Ride tracking cancellation failed: $error');
      }),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearSession();
    super.dispose();
  }
}

class _TrackingSession {
  _TrackingSession(this.generation, this.rideId, this.riderId);

  final int generation;
  final String rideId;
  final String riderId;
  bool pending = false;
  Future<void>? refreshing;
}
