import '../data/db_models.dart';
import '../data/db_service.dart';
import '../state/ride_status.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;

/// Ride requests and their append-only history.
///
/// Reads are scoped the way RLS scopes them: a passenger sees their own
/// requests, a rider sees the ones they took plus the open pool, and the open
/// pool is only visible to an approved rider in the first place.
abstract interface class RideRepository {
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  });

  Future<List<RideRecord>> fetchRidesForRider(String riderId, {int? limit});

  /// Requests still waiting for a rider. Empty for anyone RLS will not show
  /// them to, which is indistinguishable from "no open rides" at the client.
  Future<List<RideRecord>> fetchOpenPool(String serviceAreaId, {int? limit});

  Future<RideRecord?> fetchRide(String rideId);

  Future<List<RideStatusEventRecord>> fetchStatusEvents(String rideId);

  Future<List<RideRatingRecord>> fetchRatingsForRide(String rideId);
}

const String _rideColumns =
    'id, passenger_id, rider_id, service_area_id, status, pickup_address, '
    'pickup_barangay_id, pickup_purok_id, pickup_latitude, pickup_longitude, '
    'dropoff_address, dropoff_barangay_id, dropoff_purok_id, dropoff_latitude, '
    'dropoff_longitude, distance_km, eta_minutes, fare_centavos, '
    'platform_fee_centavos, payment_method, note, requested_at, accepted_at, '
    'started_at, completed_at, cancelled_at, cancellation_reason';

class SupabaseRideRepository implements RideRepository {
  SupabaseRideRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

  @override
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  }) =>
      _read(eq: {'passenger_id': passengerId}, limit: limit);

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
        passengerName: request.passengerName,
      );

  RideRecord _fromHistory(RideHistoryItem history) => RideRecord(
        id: history.id,
        serviceAreaId: mockServiceAreaId,
        status: RideStatus.fromJson(history.status),
        pickupAddress: history.route,
        dropoffAddress: history.route,
        fareCentavos: history.fare,
        completedAt: history.completedAt,
        riderName: history.driverName,
      );

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
