import '../data/db_models.dart';
import '../data/db_service.dart';
import '../state/rental_status.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;
import 'repository_failure.dart';

/// Vehicle rental bookings, from the renter's request to the owner's decision.
///
/// Reads are open to any build. Writes go through the database functions and
/// are only offered when a writer was installed, so a read-only test double
/// keeps the read surface and refuses submissions.
abstract interface class RentalRepository {
  Future<List<RentalRecord>> fetchRentalsByRenter(
    String renterId, {
    int? limit,
  });

  Future<List<RentalRecord>> fetchRentalsByOwner(
    String ownerId, {
    int? limit,
  });

  Future<RentalRecord?> fetchRental(String rentalId);

  /// Creates a booking request for the signed-in renter.
  Future<RentalRecord> createRequest({
    required String vehicleId,
    required DateTime startAt,
    required DateTime endAt,
    required String pickupLocation,
    required String pickupBarangayId,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
  });

  /// Answers a request as the vehicle owner.
  Future<RentalRecord> respond({
    required String rentalId,
    required bool accept,
  });

  /// Moves an accepted/active/returned booking one step along the server's
  /// transition table. The database refuses any other move.
  Future<RentalRecord> advance({
    required String rentalId,
    required RentalStatus status,
  });

  /// Cancels a booking before it completes, as either participant.
  Future<RentalRecord> cancel({required String rentalId, String? reason});
}

const String _rentalColumns =
    'id, renter_id, owner_id, vehicle_id, service_area_id, status, start_at, '
    'end_at, duration_hours, pickup_location, pickup_barangay_id, '
    'pickup_purok_id, pickup_latitude, pickup_longitude, current_location, '
    'vehicle_latitude, vehicle_longitude, total_fare_centavos, '
    'platform_fee_centavos, payment_method, accepted_at, started_at, '
    'returned_at, completed_at, declined_at, cancelled_at, '
    'cancellation_reason, '
    'vehicle:vehicles(name, plate_number, vehicle_type, category), '
    'renter:profiles(full_name), owner:profiles(full_name)';

class SupabaseRentalRepository implements RentalRepository {
  SupabaseRentalRepository(
    SurgoBackend backend, {
    this._writer,
  })  : _backend = backend;

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;

  SurgoWriteBackend get _write {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot submit rental changes.',
      );
    }
    return writer;
  }

  @override
  Future<RentalRecord> createRequest({
    required String vehicleId,
    required DateTime startAt,
    required DateTime endAt,
    required String pickupLocation,
    required String pickupBarangayId,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'create_rental_request',
      params: {
        'p_vehicle_id': vehicleId,
        'p_start_at': startAt.toUtc().toIso8601String(),
        'p_end_at': endAt.toUtc().toIso8601String(),
        'p_pickup_location': pickupLocation,
        'p_pickup_barangay_id': pickupBarangayId,
        if (pickupPurokId != null) 'p_pickup_purok_id': pickupPurokId,
        if (pickupLatitude != null) 'p_pickup_latitude': pickupLatitude,
        if (pickupLongitude != null) 'p_pickup_longitude': pickupLongitude,
      },
    ));
    return RentalRecord.fromRow(row);
  }

  @override
  Future<RentalRecord> respond({
    required String rentalId,
    required bool accept,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'respond_to_rental_request',
      params: {'p_rental_id': rentalId, 'p_accept': accept},
    ));
    return RentalRecord.fromRow(row);
  }

  @override
  Future<RentalRecord> advance({
    required String rentalId,
    required RentalStatus status,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'advance_rental_status',
      params: {
        'p_rental_id': rentalId,
        'p_status': rentalStatusToDb(status),
      },
    ));
    return RentalRecord.fromRow(row);
  }

  @override
  Future<RentalRecord> cancel({
    required String rentalId,
    String? reason,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'cancel_rental_request',
      params: {
        'p_rental_id': rentalId,
        if (reason != null) 'p_reason': reason,
      },
    ));
    return RentalRecord.fromRow(row);
  }

  Map<String, dynamic> _rpcRow(dynamic result) {
    if (result is Map) return Map<String, dynamic>.from(result);
    throw RepositoryFailure.invalidData(
      'The rental service returned an unexpected shape.',
    );
  }

  @override
  Future<List<RentalRecord>> fetchRentalsByRenter(
    String renterId, {
    int? limit,
  }) =>
      _read(eq: {'renter_id': renterId}, limit: limit);

  @override
  Future<List<RentalRecord>> fetchRentalsByOwner(
    String ownerId, {
    int? limit,
  }) =>
      _read(eq: {'owner_id': ownerId}, limit: limit);

  @override
  Future<RentalRecord?> fetchRental(String rentalId) async {
    final row = await _backend.row(
      table: 'rental_bookings',
      columns: _rentalColumns,
      eq: {'id': rentalId},
    );
    return row == null ? null : RentalRecord.fromRow(row);
  }

  Future<List<RentalRecord>> _read({
    required Map<String, Object> eq,
    int? limit,
  }) async {
    final rows = await _backend.rows(
      table: 'rental_bookings',
      columns: _rentalColumns,
      eq: eq,
      orderBy: 'start_at',
      limit: limit,
    );
    return [for (final row in rows) RentalRecord.fromRow(row)];
  }
}

/// Reads the seeded `rentals.json` and `vehicles.json` booking slices.
class MockRentalRepository implements RentalRepository {
  MockRentalRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<RentalRecord>> fetchRentalsByRenter(
    String renterId, {
    int? limit,
  }) async {
    if (renterId != _db.passenger.id) return const [];
    final records = [for (final item in _db.rentalHistory) _fromHistory(item)];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<RentalRecord>> fetchRentalsByOwner(
    String ownerId, {
    int? limit,
  }) async {
    final records = [
      for (final request in _db.ownerBookingRequests) _fromRequest(request),
      if (ownerId == _db.vehicleOwner.id)
        for (final item in _db.rentalHistory) _fromHistory(item),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<RentalRecord?> fetchRental(String rentalId) async {
    for (final request in _db.ownerBookingRequests) {
      if (request.id == rentalId) return _fromRequest(request);
    }
    for (final item in _db.rentalHistory) {
      if (item.id == rentalId) return _fromHistory(item);
    }
    return null;
  }

  @override
  Future<RentalRecord> createRequest({
    required String vehicleId,
    required DateTime startAt,
    required DateTime endAt,
    required String pickupLocation,
    required String pickupBarangayId,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded rentals are simulated by AppState.',
    );
  }

  @override
  Future<RentalRecord> respond({
    required String rentalId,
    required bool accept,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded rentals are simulated by AppState.',
    );
  }

  @override
  Future<RentalRecord> advance({
    required String rentalId,
    required RentalStatus status,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded rentals are simulated by AppState.',
    );
  }

  @override
  Future<RentalRecord> cancel({
    required String rentalId,
    String? reason,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded rentals are simulated by AppState.',
    );
  }

  RentalRecord _fromRequest(OwnerBookingRequest request) => RentalRecord(
        id: request.id,
        renterId: request.renterId,
        ownerId: request.ownerId ?? _db.vehicleOwner.id,
        vehicleId: request.vehicleId,
        serviceAreaId: mockServiceAreaId,
        status: request.status,
        startAt: request.startAt,
        endAt: request.endAt,
        durationHours: request.durationHours,
        pickupLocation: request.pickupLocation,
        pickupLatitude: request.pickupLatitude,
        pickupLongitude: request.pickupLongitude,
        currentLocation: request.currentLocation,
        vehicleLatitude: request.vehicleLatitude,
        vehicleLongitude: request.vehicleLongitude,
        totalFareCentavos: request.totalFare,
        paymentMethod: request.paymentMethod ?? 'cash',
        vehicleName: request.vehicleName,
      );

  RentalRecord _fromHistory(RentalHistoryItem item) => RentalRecord(
        id: item.id,
        renterId: _db.passenger.id,
        ownerId: _db.vehicleOwner.id,
        serviceAreaId: mockServiceAreaId,
        status: RentalStatus.fromJson(item.status),
        startAt: item.startAt,
        endAt: item.endAt,
        totalFareCentavos: item.totalFare,
        vehicleName: item.vehicleName,
      );
}
