import 'dart:math' as math;

import '../data/db_models.dart';
import '../data/db_service.dart';
import '../state/ride_status.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;
import 'repository_failure.dart';

/// Ride requests, rider presence, discovery and the dispatch lifecycle.
///
/// Reads are scoped the way RLS scopes them: a passenger sees their own
/// requests, a rider sees the ones they took plus the open pool, and the open
/// pool is only visible to an approved ride provider in the first place.
///
/// Writes are server-side functions. The client has no INSERT/UPDATE grant on
/// `ride_requests` or `rider_presence`; the functions check `auth.uid()` and
/// the ride state before changing anything.
abstract interface class RideRepository {
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  });

  /// The passenger's terminal rides — completed and cancelled — newest first.
  /// Requests still being matched are not bookings yet, so they stay out of
  /// the history the home screen's Recent Bookings card lists.
  Future<List<RideRecord>> fetchRideHistory(String passengerId, {int? limit});

  Future<List<RideRecord>> fetchRidesForRider(String riderId, {int? limit});

  /// Requests still waiting for a rider. Empty for anyone RLS will not show
  /// them to, which is indistinguishable from "no open rides" at the client.
  Future<List<RideRecord>> fetchOpenPool(String serviceAreaId, {int? limit});

  Future<RideRecord?> fetchRide(String rideId);

  Future<List<RideStatusEventRecord>> fetchStatusEvents(String rideId);

  Future<List<RideRatingRecord>> fetchRatingsForRide(String rideId);

  /// Online, available riders near a pickup, as returned by the database.
  ///
  /// The discovery function only returns safe display fields. A rider who is
  /// offline, on a trip, suspended, or not approved for rides never appears.
  Future<List<RiderCandidateRecord>> findAvailableRiders({
    String? serviceAreaId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? excludeProfileId,
    int limit = 20,
  });

  /// The signed-in rider's own presence row, or null before they first went
  /// online. RLS lets a rider read their own row even while offline.
  Future<RiderPresenceRecord?> fetchPresence(String profileId);

  /// Turns the signed-in rider online or offline. Coordinates are optional on
  /// an offline toggle and reuse the last known fix when omitted.
  Future<RiderPresenceRecord> setPresence({
    required bool online,
    double? latitude,
    double? longitude,
    double? headingDegrees,
    String? barangayId,
  });

  /// Creates a ride request for the signed-in passenger.
  Future<RideRecord> createRideRequest({
    required String pickupAddress,
    String? pickupBarangay,
    String? pickupPurok,
    double? pickupLatitude,
    double? pickupLongitude,
    required String dropoffAddress,
    String? dropoffBarangay,
    String? dropoffPurok,
    double? dropoffLatitude,
    double? dropoffLongitude,
    required double distanceKm,
    required int etaMinutes,
    required int fareCentavos,
    required int platformFeeCentavos,
    String? note,
    String? serviceAreaId,
  });

  /// Offers [rideId] to [riderId]. Only the passenger can call this, and only
  /// while the request is still searching.
  Future<RideRecord> assignRider({
    required String rideId,
    required String riderId,
  });

  /// Accepts or declines a request that was assigned to the signed-in rider.
  Future<RideRecord> respondToRide({
    required String rideId,
    required bool accept,
  });

  /// Cancels a ride as either participant.
  Future<RideRecord> cancelRide({required String rideId, String? reason});

  /// Moves a trip through accepted → heading → arrived → in progress →
  /// completed. The database rejects any other transition.
  Future<RideRecord> advanceRideStatus({
    required String rideId,
    required String status,
  });
}

const String _rideColumns =
    'id, passenger_id, rider_id, service_area_id, status, pickup_address, '
    'pickup_barangay_id, pickup_purok_id, pickup_latitude, pickup_longitude, '
    'dropoff_address, dropoff_barangay_id, dropoff_purok_id, dropoff_latitude, '
    'dropoff_longitude, distance_km, eta_minutes, fare_centavos, '
    'platform_fee_centavos, payment_method, note, requested_at, accepted_at, '
    'started_at, completed_at, cancelled_at, cancellation_reason, '
    'passenger:profiles!ride_requests_passenger_id_fkey(full_name), '
    'rider:profiles!ride_requests_rider_id_fkey(full_name), '
    'pickup_barangay:barangays!ride_requests_pickup_barangay_fkey(name), '
    'dropoff_barangay:barangays!ride_requests_dropoff_barangay_fkey(name)';

const String _presenceColumns =
    'profile_id, is_online, is_available, latitude, longitude, heading_degrees, '
    'barangay_id, vehicle_type, vehicle_label, vehicle_plate, is_simulated, '
    'source, updated_at';

class SupabaseRideRepository implements RideRepository {
  SupabaseRideRepository(SurgoBackend backend, {SurgoWriteBackend? writer})
      : _backend = backend,
        _writer = writer;

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;

  SurgoWriteBackend get _write {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot submit ride changes.',
      );
    }
    return writer;
  }

  @override
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  }) =>
      _read(eq: {'passenger_id': passengerId}, limit: limit);

  @override
  Future<List<RideRecord>> fetchRideHistory(
    String passengerId, {
    int? limit,
  }) =>
      _read(
        eq: {'passenger_id': passengerId},
        whereIn: {
          'status': const ['completed', 'cancelled'],
        },
        limit: limit,
      );

  @override
  Future<List<RideRecord>> fetchRidesForRider(
    String riderId, {
    int? limit,
  }) =>
      _read(eq: {'rider_id': riderId}, limit: limit);

  @override
  Future<List<RideRecord>> fetchOpenPool(
    String serviceAreaId, {
    int? limit,
  }) =>
      _read(
        eq: {'service_area_id': serviceAreaId},
        whereIn: {
          'status': const ['searching', 'awaiting_acceptance'],
        },
        limit: limit,
      );

  @override
  Future<RideRecord?> fetchRide(String rideId) async {
    final row = await _backend.row(
      table: 'ride_requests',
      columns: _rideColumns,
      eq: {'id': rideId},
    );
    return row == null ? null : RideRecord.fromRow(row);
  }

  @override
  Future<List<RideStatusEventRecord>> fetchStatusEvents(String rideId) async {
    final rows = await _backend.rows(
      table: 'ride_status_events',
      columns: 'id, ride_id, status, actor_profile_id, note, created_at',
      eq: {'ride_id': rideId},
      orderBy: 'created_at',
      ascending: true,
    );
    return [for (final row in rows) RideStatusEventRecord.fromRow(row)];
  }

  @override
  Future<List<RideRatingRecord>> fetchRatingsForRide(String rideId) async {
    final rows = await _backend.rows(
      table: 'ride_ratings',
      columns: 'id, ride_id, rater_id, ratee_id, stars, comment, created_at',
      eq: {'ride_id': rideId},
    );
    return [for (final row in rows) RideRatingRecord.fromRow(row)];
  }

  @override
  Future<List<RiderCandidateRecord>> findAvailableRiders({
    String? serviceAreaId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? excludeProfileId,
    int limit = 20,
  }) async {
    final result = await _write.rpc(
      function: 'find_available_riders',
      params: {
        'p_service_area_id': serviceAreaId,
        'p_pickup_latitude': pickupLatitude,
        'p_pickup_longitude': pickupLongitude,
        'p_exclude_profile_id': excludeProfileId,
        'p_limit': limit,
      },
    );
    if (result is! List) {
      throw RepositoryFailure.invalidData(
        'Rider discovery returned an unexpected shape.',
      );
    }
    return [
      for (final row in result)
        if (row is Map)
          RiderCandidateRecord.fromRow(Map<String, dynamic>.from(row)),
    ];
  }

  @override
  Future<RiderPresenceRecord?> fetchPresence(String profileId) async {
    final row = await _backend.row(
      table: 'rider_presence',
      columns: _presenceColumns,
      eq: {'profile_id': profileId},
    );
    return row == null ? null : RiderPresenceRecord.fromRow(row);
  }

  @override
  Future<RiderPresenceRecord> setPresence({
    required bool online,
    double? latitude,
    double? longitude,
    double? headingDegrees,
    String? barangayId,
  }) async {
    final result = await _write.rpc(
      function: 'set_rider_presence',
      params: {
        'p_is_online': online,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_heading_degrees': headingDegrees,
        'p_barangay_id': barangayId,
      },
    );
    return RiderPresenceRecord.fromRow(_rpcRow(result));
  }

  @override
  Future<RideRecord> createRideRequest({
    required String pickupAddress,
    String? pickupBarangay,
    String? pickupPurok,
    double? pickupLatitude,
    double? pickupLongitude,
    required String dropoffAddress,
    String? dropoffBarangay,
    String? dropoffPurok,
    double? dropoffLatitude,
    double? dropoffLongitude,
    required double distanceKm,
    required int etaMinutes,
    required int fareCentavos,
    required int platformFeeCentavos,
    String? note,
    String? serviceAreaId,
  }) async {
    final result = await _write.rpc(
      function: 'create_ride_request',
      params: {
        'p_pickup_address': pickupAddress,
        'p_pickup_barangay': pickupBarangay,
        'p_pickup_purok': pickupPurok,
        'p_pickup_latitude': pickupLatitude,
        'p_pickup_longitude': pickupLongitude,
        'p_dropoff_address': dropoffAddress,
        'p_dropoff_barangay': dropoffBarangay,
        'p_dropoff_purok': dropoffPurok,
        'p_dropoff_latitude': dropoffLatitude,
        'p_dropoff_longitude': dropoffLongitude,
        'p_distance_km': distanceKm,
        'p_eta_minutes': etaMinutes,
        'p_fare_centavos': fareCentavos,
        'p_platform_fee_centavos': platformFeeCentavos,
        'p_note': note,
        'p_service_area_id': serviceAreaId,
      },
    );
    return RideRecord.fromRow(_rpcRow(result));
  }

  @override
  Future<RideRecord> assignRider({
    required String rideId,
    required String riderId,
  }) async {
    final result = await _write.rpc(
      function: 'assign_ride_request',
      params: {'p_ride_id': rideId, 'p_rider_id': riderId},
    );
    return RideRecord.fromRow(_rpcRow(result));
  }

  @override
  Future<RideRecord> respondToRide({
    required String rideId,
    required bool accept,
  }) async {
    final result = await _write.rpc(
      function: 'respond_to_ride_request',
      params: {'p_ride_id': rideId, 'p_accept': accept},
    );
    return RideRecord.fromRow(_rpcRow(result));
  }

  @override
  Future<RideRecord> cancelRide({required String rideId, String? reason}) async {
    final result = await _write.rpc(
      function: 'cancel_ride_request',
      params: {'p_ride_id': rideId, 'p_reason': reason},
    );
    return RideRecord.fromRow(_rpcRow(result));
  }

  @override
  Future<RideRecord> advanceRideStatus({
    required String rideId,
    required String status,
  }) async {
    final result = await _write.rpc(
      function: 'advance_ride_status',
      params: {'p_ride_id': rideId, 'p_status': status},
    );
    return RideRecord.fromRow(_rpcRow(result));
  }

  Future<List<RideRecord>> _read({
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    int? limit,
  }) async {
    final rows = await _backend.rows(
      table: 'ride_requests',
      columns: _rideColumns,
      eq: eq,
      whereIn: whereIn,
      orderBy: 'requested_at',
      limit: limit,
    );
    return [for (final row in rows) RideRecord.fromRow(row)];
  }

  Map<String, dynamic> _rpcRow(dynamic result) {
    if (result is Map) return Map<String, dynamic>.from(result);
    throw RepositoryFailure.invalidData(
      'The ride service returned an unexpected shape.',
    );
  }
}

/// Reads the seeded `rides.json` slice: open requests plus the completed
/// history the activity and earnings screens list.
class MockRideRepository implements RideRepository {
  MockRideRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  }) async {
    final isDemoPassenger = passengerId == _db.passenger.id;
    final records = [
      for (final request in _db.rideRequests)
        if (request.passengerId == passengerId || isDemoPassenger)
          _fromRequest(request),
      if (isDemoPassenger)
        for (final history in _db.rideHistory) _fromHistory(history),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<RideRecord>> fetchRideHistory(
    String passengerId, {
    int? limit,
  }) async {
    if (passengerId != _db.passenger.id) return const [];
    final records = [
      for (final history in _db.rideHistory) _fromHistory(history),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<RideRecord>> fetchRidesForRider(
    String riderId, {
    int? limit,
  }) async {
    final isDemoEarner = riderId == _db.earner.id;
    final records = [
      for (final request in _db.rideRequests)
        if (request.riderId == riderId || isDemoEarner) _fromRequest(request),
      if (isDemoEarner)
        for (final trip in _db.riderTrips) _fromTrip(trip),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<RideRecord>> fetchOpenPool(
    String serviceAreaId, {
    int? limit,
  }) async {
    final records = [
      for (final request in _db.rideRequests)
        if (request.status == RideStatus.searching ||
            request.status == RideStatus.awaitingAcceptance)
          _fromRequest(request),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<RideRecord?> fetchRide(String rideId) async {
    for (final request in _db.rideRequests) {
      if (request.id == rideId) return _fromRequest(request);
    }
    return null;
  }

  @override
  Future<List<RideStatusEventRecord>> fetchStatusEvents(String rideId) async {
    // The seed keeps only the current status, not the transition log, so an
    // empty list is the honest answer rather than a reconstructed timeline.
    return const [];
  }

  @override
  Future<List<RideRatingRecord>> fetchRatingsForRide(String rideId) async {
    return const [];
  }

  @override
  Future<List<RiderCandidateRecord>> findAvailableRiders({
    String? serviceAreaId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? excludeProfileId,
    int limit = 20,
  }) async {
    final candidates = [
      for (final rider in _db.mapRiders)
        if (rider.available && rider.id != excludeProfileId)
          RiderCandidateRecord(
            profileId: rider.id,
            fullName: rider.name,
            rating: rider.rating,
            totalTrips: rider.totalTrips,
            vehicleType: rider.vehicleType,
            vehicleLabel: rider.vehicleModel,
            vehiclePlate: rider.vehiclePlate,
            barangayName: rider.barangay,
            latitude: rider.position.latitude,
            longitude: rider.position.longitude,
            distanceKm: pickupLatitude == null || pickupLongitude == null
                ? null
                : _distanceKm(
                    pickupLatitude,
                    pickupLongitude,
                    rider.position.latitude,
                    rider.position.longitude,
                  ),
            updatedAt: DateTime.now(),
          ),
    ]..sort((a, b) {
        final ad = a.distanceKm ?? double.infinity;
        final bd = b.distanceKm ?? double.infinity;
        return ad.compareTo(bd);
      });
    return candidates.take(limit).toList();
  }

  @override
  Future<RiderPresenceRecord?> fetchPresence(String profileId) async {
    if (profileId != _db.earner.id) return null;
    final rider = _db.mapRiders.isEmpty ? null : _db.mapRiders.first;
    return RiderPresenceRecord(
      profileId: profileId,
      isOnline: true,
      isAvailable: true,
      latitude: rider?.position.latitude,
      longitude: rider?.position.longitude,
      barangayId: rider?.barangay,
      vehicleType: rider?.vehicleType,
      vehicleLabel: rider?.vehicleModel,
      vehiclePlate: rider?.vehiclePlate,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<RiderPresenceRecord> setPresence({
    required bool online,
    double? latitude,
    double? longitude,
    double? headingDegrees,
    String? barangayId,
  }) async {
    throw RepositoryFailure.unsupported(
      'The seeded build keeps rider presence in local state.',
    );
  }

  @override
  Future<RideRecord> createRideRequest({
    required String pickupAddress,
    String? pickupBarangay,
    String? pickupPurok,
    double? pickupLatitude,
    double? pickupLongitude,
    required String dropoffAddress,
    String? dropoffBarangay,
    String? dropoffPurok,
    double? dropoffLatitude,
    double? dropoffLongitude,
    required double distanceKm,
    required int etaMinutes,
    required int fareCentavos,
    required int platformFeeCentavos,
    String? note,
    String? serviceAreaId,
  }) async {
    throw RepositoryFailure.unsupported(
      'The seeded build creates requests through local state.',
    );
  }

  @override
  Future<RideRecord> assignRider({
    required String rideId,
    required String riderId,
  }) async {
    throw RepositoryFailure.unsupported(
      'The seeded build assigns riders through local state.',
    );
  }

  @override
  Future<RideRecord> respondToRide({
    required String rideId,
    required bool accept,
  }) async {
    throw RepositoryFailure.unsupported(
      'The seeded build answers requests through local state.',
    );
  }

  @override
  Future<RideRecord> cancelRide({required String rideId, String? reason}) async {
    throw RepositoryFailure.unsupported(
      'The seeded build cancels rides through local state.',
    );
  }

  @override
  Future<RideRecord> advanceRideStatus({
    required String rideId,
    required String status,
  }) async {
    throw RepositoryFailure.unsupported(
      'The seeded build advances trips through local state.',
    );
  }

  RideRecord _fromRequest(RideRequestItem request) => RideRecord(
        id: request.id,
        passengerId: request.passengerId ?? _db.passenger.id,
        riderId: request.riderId,
        serviceAreaId: mockServiceAreaId,
        status: request.status,
        pickupAddress: request.pickup,
        pickupBarangayName: request.pickupBarangay,
        pickupLatitude: request.pickupLatitude,
        pickupLongitude: request.pickupLongitude,
        dropoffAddress: request.dropoff,
        dropoffBarangayName: request.dropoffBarangay,
        dropoffLatitude: request.dropoffLatitude,
        dropoffLongitude: request.dropoffLongitude,
        distanceKm: request.distanceKm,
        etaMinutes: request.etaMinutes,
        fareCentavos: request.fare,
        paymentMethod: request.paymentMethod,
        note: request.note.isEmpty ? null : request.note,
        requestedAt: request.requestedAtIso,
        passengerName: request.passengerName,
      );

  RideRecord _fromHistory(RideHistoryItem history) {
    // The seed writes one display route ("A → B"); the record keeps the two
    // addresses apart so the presentation mapper can join them once, the same
    // way it joins a hosted row's pickup and dropoff.
    final separator = history.route.indexOf(' → ');
    return RideRecord(
      id: history.id,
      serviceAreaId: mockServiceAreaId,
      status: RideStatus.fromJson(history.status),
      pickupAddress:
          separator < 0 ? history.route : history.route.substring(0, separator),
      dropoffAddress: separator < 0
          ? ''
          : history.route.substring(separator + ' → '.length),
      fareCentavos: history.fare,
      completedAt: history.completedAt,
      riderName: history.driverName,
    );
  }

  RideRecord _fromTrip(RiderTripItem trip) => RideRecord(
        id: trip.id,
        riderId: _db.earner.id,
        serviceAreaId: mockServiceAreaId,
        status: RideStatus.fromJson(trip.status),
        pickupAddress: trip.route,
        dropoffAddress: trip.route,
        distanceKm: trip.distanceKm,
        fareCentavos: trip.fare,
        completedAt: trip.completedAt,
        passengerName: trip.passengerName,
      );
}

double _distanceKm(
  double fromLatitude,
  double fromLongitude,
  double toLatitude,
  double toLongitude,
) {
  const earthKm = 6371.0;
  double radians(double degrees) => degrees * math.pi / 180;
  final dLat = radians(toLatitude - fromLatitude);
  final dLng = radians(toLongitude - fromLongitude);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(radians(fromLatitude)) *
          math.cos(radians(toLatitude)) *
          math.pow(math.sin(dLng / 2), 2);
  return earthKm * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
}
