import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;

/// Vehicles and their compliance documents.
///
/// There is no separate rental-listing table: a vehicle with status `active`
/// *is* the listing, so `fetchListedVehicles` is the rental catalogue read.
abstract interface class VehicleRepository {
  Future<List<VehicleRecord>> fetchVehiclesOwnedBy(String ownerProfileId);

  Future<VehicleRecord?> fetchVehicle(String vehicleId);

  Future<List<VehicleRecord>> fetchVehiclesByIds(List<String> vehicleIds);

  /// Vehicles bookable in [serviceAreaId], or everywhere when it is null.
  Future<List<VehicleRecord>> fetchListedVehicles({String? serviceAreaId});

  Future<List<VehicleDocumentRecord>> fetchDocuments(List<String> vehicleIds);
}

const String _vehicleColumns =
    'id, owner_profile_id, service_area_id, name, vehicle_type, category, '
    'make, model, model_year, color, plate_number, price_per_day_centavos, '
    'status, rating, total_rentals';

const String _vehicleSelectColumns =
    '$_vehicleColumns, owner:profiles(full_name)';

class SupabaseVehicleRepository implements VehicleRepository {
  SupabaseVehicleRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

  @override
  Future<List<VehicleRecord>> fetchVehiclesOwnedBy(
      String ownerProfileId) async {
    return _read(
      eq: {'owner_profile_id': ownerProfileId},
      orderBy: 'created_at',
    );
  }

  @override
  Future<VehicleRecord?> fetchVehicle(String vehicleId) async {
    final row = await _backend.row(
      table: 'vehicles',
      columns: _vehicleSelectColumns,
      eq: {'id': vehicleId},
    );
    if (row == null) return null;
    return VehicleRecord.fromRow(row);
  }

  @override
  Future<List<VehicleRecord>> fetchVehiclesByIds(
      List<String> vehicleIds) async {
    if (vehicleIds.isEmpty) return const [];
    return _read(eqIdIn: vehicleIds);
  }

  @override
  Future<List<VehicleRecord>> fetchListedVehicles({
    String? serviceAreaId,
  }) async {
    return _read(
      eq: {
        'status': 'active',
        if (serviceAreaId != null) 'service_area_id': serviceAreaId,
      },
      orderBy: 'created_at',
    );
  }

  @override
  Future<List<VehicleDocumentRecord>> fetchDocuments(
      List<String> vehicleIds) async {
    if (vehicleIds.isEmpty) return const [];
    final rows = await _backend.rows(
      table: 'vehicle_documents',
      columns: 'id, vehicle_id, document_type, document_number, storage_path, '
          'issued_at, expires_at, status, rejection_reason',
      whereIn: {'vehicle_id': vehicleIds},
      orderBy: 'created_at',
    );
    return [for (final row in rows) VehicleDocumentRecord.fromRow(row)];
  }

  Future<List<VehicleRecord>> _read({
    Map<String, Object> eq = const {},
    List<String>? eqIdIn,
    String? orderBy,
  }) async {
    final rows = await _backend.rows(
      table: 'vehicles',
      columns: _vehicleSelectColumns,
      eq: eq,
      whereIn: {if (eqIdIn != null) 'id': eqIdIn},
      orderBy: orderBy,
    );
    return [for (final row in rows) VehicleRecord.fromRow(row)];
  }
}

/// Reads the seeded `vehicles.json` slice.
///
/// The seed labels a vehicle `Listed`, `Rented` or `Maintenance`; the database
/// enum has no `Rented`, because availability is a property of the bookings, so
/// both `Listed` and `Rented` map to `active`.
class MockVehicleRepository implements VehicleRepository {
  MockVehicleRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<VehicleRecord>> fetchVehiclesOwnedBy(
      String ownerProfileId) async {
    return [for (final vehicle in _db.ownerVehicles) _toRecord(vehicle)];
  }

  @override
  Future<VehicleRecord?> fetchVehicle(String vehicleId) async {
    for (final vehicle in _db.ownerVehicles) {
      if (vehicle.id == vehicleId) return _toRecord(vehicle);
    }
    return null;
  }

  @override
  Future<List<VehicleRecord>> fetchVehiclesByIds(
      List<String> vehicleIds) async {
    return [
      for (final vehicle in _db.ownerVehicles)
        if (vehicleIds.contains(vehicle.id)) _toRecord(vehicle),
    ];
  }

  @override
  Future<List<VehicleRecord>> fetchListedVehicles({
    String? serviceAreaId,
  }) async {
    return [
      for (final vehicle in _db.ownerVehicles)
        if (_statusToken(vehicle.status) == 'active') _toRecord(vehicle),
    ];
  }

  @override
  Future<List<VehicleDocumentRecord>> fetchDocuments(
      List<String> vehicleIds) async {
    // The seed has one paperwork set for the owner's whole fleet, so the
    // requested vehicle ids cannot narrow it; every document comes back with
    // its fleet paperwork and no vehicle link.
    if (vehicleIds.isEmpty) return const [];
    return [
      for (final document in _db.vehicleDocuments)
        VehicleDocumentRecord(
          id: document.id,
          documentType: document.title,
          documentNumber: document.number,
          status: _documentStatus(document.status),
          expiresAt: null,
        ),
    ];
  }

  VehicleRecord _toRecord(OwnedVehicle vehicle) => VehicleRecord(
        id: vehicle.id,
        ownerProfileId: _db.vehicleOwner.id,
        serviceAreaId: mockServiceAreaId,
        name: vehicle.name,
        vehicleType: vehicle.type,
        category: vehicle.category,
        plateNumber: vehicle.plate,
        pricePerDayCentavos: vehicle.pricePerDay,
        status: _statusToken(vehicle.status),
        rating: vehicle.rating,
        totalRentals: vehicle.totalRentals,
        ownerName: _db.vehicleOwner.name,
      );

  static String _statusToken(String label) => switch (label) {
        'Listed' || 'Rented' => 'active',
        'Maintenance' => 'inactive',
        _ => 'pending_verification',
      };

  static String _documentStatus(String label) => switch (label.toLowerCase()) {
        'verified' || 'approved' => 'approved',
        'rejected' => 'rejected',
        'expired' => 'expired',
        _ => 'pending',
      };
}
