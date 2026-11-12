import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/db_models.dart';
import '../repositories/backend.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/ride_repository.dart';

abstract interface class DemoRideRequestStore {
  Future<RideRequestItem?> read(String profileId);
  Future<void> write(String profileId, RideRequestItem? request);
}

class SharedPreferencesDemoRideRequestStore implements DemoRideRequestStore {
  Future<void> _writes = Future.value();

  String _key(String profileId) => 'surgo.demo.ride.$profileId';

  @override
  Future<RideRequestItem?> read(String profileId) async {
    await _writes.catchError((Object error) {});
    final preferences = await SharedPreferences.getInstance();
    final json = preferences.getString(_key(profileId));
    if (json == null) return null;
    try {
      final request = RideRequestItem.fromJson(
        Map<String, dynamic>.from(jsonDecode(json) as Map),
      );
      if (request.passengerId != profileId || request.status.isTerminal) {
        return null;
      }
      return request;
    } on Object {
      await preferences.remove(_key(profileId));
      return null;
    }
  }

  @override
  Future<void> write(String profileId, RideRequestItem? request) {
    final json = request == null ? null : jsonEncode(request.toJson());
    return _writes = _writes.catchError((Object error) {}).then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (json == null) {
        await preferences.remove(_key(profileId));
      } else {
        await preferences.setString(_key(profileId), json);
      }
    });
  }
}

class PassengerRideSession {
  PassengerRideSession({
    required this.rides,
    required this.profileId,
    required this.onChanged,
    this.realtime,
  });

  final RideRepository rides;
  final String profileId;
  final SurgoRealtimeBackend? realtime;
  final void Function(RideRecord? ride, RepositoryFailure? failure) onChanged;
  StreamSubscription<void>? _subscription;
  Timer? _poll;
  Future<void>? _refreshing;
  bool _pending = false;
  bool _stopped = false;
  int _revision = 0;
  String? _rideId;

  void start() {
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(refresh());
    });
    if (realtime != null) {
      try {
        _subscription = realtime!
            .watchRows(
              table: 'ride_requests',
              column: 'passenger_id',
              value: profileId,
            )
            .listen(
              (_) => unawaited(refresh()),
              onError: (Object error) {
                if (!_stopped) unawaited(refresh());
              },
            );
      } catch (error) {
        onChanged(null, mapBackendError(error));
      }
    }
  }

  void recordWrite(RideRecord record) {
    _revision++;
    _rideId = record.id;
  }

  Future<void> refresh() {
    if (_stopped) return Future.value();
    _pending = true;
    return _refreshing ??= _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _pending = false;
        final revision = _revision;
        try {
          final records = await rides.fetchRidesForPassenger(profileId);
          if (_stopped) return;
          if (revision != _revision) {
            _pending = true;
            continue;
          }
          final owned = records.where((ride) => ride.passengerId == profileId);
          RideRecord? live;
          RideRecord? previous;
          for (final record in owned) {
            if (record.id == _rideId) previous = record;
            if (!record.status.isTerminal && live == null) live = record;
          }
          final selected = live ?? previous;
          _rideId = live?.id;
          onChanged(selected, null);
        } catch (error) {
          if (!_stopped) {
            if (revision != _revision) {
              _pending = true;
            } else {
              onChanged(null, mapBackendError(error));
            }
          }
        }
      } while (!_stopped && _pending);
    } finally {
      _refreshing = null;
    }
  }

  void stop() {
    _stopped = true;
    _poll?.cancel();
    _poll = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object error) {}));
    }
  }
}
