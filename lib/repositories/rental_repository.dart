import '../data/db_models.dart';
import '../data/db_service.dart';
import '../state/rental_status.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;

/// Vehicle rental bookings, from the renter's request to the owner's decision.
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
}

const String _rentalColumns =
    'id, renter_id, owner_id, vehicle_id, service_area_id, status, start_at, '
    'end_at, duration_hours, pickup_location, pickup_barangay_id, '
    'pickup_purok_id, pickup_latitude, pickup_longitude, current_location, '
    'vehicle_latitude, vehicle_longitude, total_fare_centavos, '
    'platform_fee_centavos, payment_method, accepted_at, started_at, '
    'returned_at, completed_at, declined_at, cancelled_at, '
    'cancellation_reason, vehicle:vehicles(name, plate_number)';

class SupabaseRentalRepository implements RentalRepository {
  SupabaseRentalRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

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
