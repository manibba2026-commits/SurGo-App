import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/state/ride_status.dart';

class _Call {
  _Call(this.function, this.params);
  final String function;
  final Map<String, dynamic> params;
}

class _Backend implements SurgoBackend, SurgoWriteBackend {
  _Backend(this.responses);

  final Map<String, Object?> responses;
  final List<_Call> calls = [];

  @override
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async =>
      const [];

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async =>
      null;

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) async {
    calls.add(_Call(function, params));
    return responses[function];
  }

  @override
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {}
}

const _rideRow = {
  'id': 'ride-1',
  'passenger_id': 'p1',
  'rider_id': 'r1',
  'service_area_id': 'sa1',
  'status': 'accepted',
  'pickup_address': 'San Isidro',
  'dropoff_address': 'Bongtod',
};

const _presenceRow = {
  'profile_id': 'r1',
  'is_online': true,
  'is_available': true,
  'latitude': 9.0785,
  'longitude': 126.2025,
  'is_simulated': true,
  'source': 'demo',
};

void main() {
  test('discovery asks the database and keeps the simulated marker', () async {
    final backend = _Backend({
      'find_available_riders': [
        {
          'profile_id': 'r1',
          'full_name': 'Carlo Mendoza',
          'rating': 4.8,
          'total_trips': 12,
          'latitude': 9.0785,
          'longitude': 126.2025,
          'is_simulated': true,
          'distance_km': 1.2,
        },
      ],
    });
    final repository = SupabaseRideRepository(backend, writer: backend);

    final riders = await repository.findAvailableRiders(
      pickupLatitude: 9.0705,
      pickupLongitude: 126.1945,
      excludeProfileId: 'p1',
    );

    expect(backend.calls.single.function, 'find_available_riders');
    expect(backend.calls.single.params['p_pickup_latitude'], 9.0705);
    expect(backend.calls.single.params['p_exclude_profile_id'], 'p1');
    expect(riders.single.fullName, 'Carlo Mendoza');
    expect(riders.single.isSimulated, isTrue);
    expect(riders.single.hasPosition, isTrue);
  });

  test('going online writes presence without inventing coordinates', () async {
    final backend = _Backend({'set_rider_presence': _presenceRow});
    final repository = SupabaseRideRepository(backend, writer: backend);

    final presence = await repository.setPresence(online: true);

    final call = backend.calls.single;
    expect(call.function, 'set_rider_presence');
    expect(call.params['p_is_online'], isTrue);
    expect(call.params['p_latitude'], isNull);
    expect(call.params['p_longitude'], isNull);
    expect(presence.isOnline, isTrue);
    expect(presence.isSimulated, isTrue);
    expect(presence.source, 'demo');
  });

  test('advancing a hosted trip sends the enum wire value', () async {
    final backend = _Backend({'advance_ride_status': _rideRow});
    final repository = SupabaseRideRepository(backend, writer: backend);

    await repository.advanceRideStatus(
      rideId: 'ride-1',
      status: RideStatus.headingToPickup.wireValue,
    );

    expect(backend.calls.single.function, 'advance_ride_status');
    expect(backend.calls.single.params['p_status'], 'heading_to_pickup');
  });

  test('every status maps to the database enum token', () {
    expect(RideStatus.searching.wireValue, 'searching');
    expect(RideStatus.awaitingAcceptance.wireValue, 'awaiting_acceptance');
    expect(RideStatus.accepted.wireValue, 'accepted');
    expect(RideStatus.headingToPickup.wireValue, 'heading_to_pickup');
    expect(RideStatus.arrived.wireValue, 'arrived');
    expect(RideStatus.inProgress.wireValue, 'in_progress');
    expect(RideStatus.completed.wireValue, 'completed');
    expect(RideStatus.cancelled.wireValue, 'cancelled');
  });

  test('the wire token parses back to the same status', () {
    for (final status in RideStatus.values) {
      expect(RideStatus.fromJson(status.wireValue), status);
    }
  });
}
