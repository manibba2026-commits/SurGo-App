import 'dart:typed_data';

import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;
import 'repository_failure.dart';

/// The editable fields of a vehicle listing.
///
/// Kept separate from [VehicleRecord] because a draft is what the form holds
/// before the database has assigned an id, status, rating or rental count.
class VehicleDraft {
  const VehicleDraft({
    required this.name,
    required this.vehicleType,
    required this.category,
    required this.plateNumber,
    required this.pricePerDayCentavos,
    this.make,
    this.model,
    this.modelYear,
    this.color,
    this.serviceAreaId,
    this.listed = true,
  });

  final String name;
  final String vehicleType;
  final String category;
  final String plateNumber;
  final int pricePerDayCentavos;
  final String? make;
  final String? model;
  final int? modelYear;
  final String? color;
  final String? serviceAreaId;

  /// Whether the vehicle should appear in the rental catalogue.
  final bool listed;
}

/// One photo the owner picked, before it is uploaded.
class VehiclePhotoUpload {
  const VehiclePhotoUpload({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;

  String get extension {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// The MIME type the private bucket accepts. Anything else is refused before
  /// a byte leaves the device, so the error names the file rather than a 400
  /// from Storage.
  String get contentType => switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => throw RepositoryFailure.invalidData(
      'Choose a JPG, PNG or WebP photo.',
    ),
  };
}

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

  /// Creates a listing for [ownerProfileId] and uploads any new photos first.
  Future<VehicleRecord> createVehicle({
    required String ownerProfileId,
    required VehicleDraft draft,
    List<VehiclePhotoUpload> photos = const [],
  });

  /// Updates the editable fields and replaces the photo list.
  ///
  /// [removePhotoPaths] names existing photos to drop; the returned record is
  /// read back from the same source as the fleet screen, not assembled locally.
  Future<VehicleRecord> updateVehicle({
    required String ownerProfileId,
    required String vehicleId,
    required VehicleDraft draft,
    List<VehiclePhotoUpload> photos = const [],
    List<String> removePhotoPaths = const [],
  });

  /// Lists or unlists a vehicle without deleting it or its rental history.
  Future<VehicleRecord> setListingStatus({
    required String vehicleId,
    required bool listed,
  });

  /// A short-lived URL for one private vehicle photo.
  Future<String> signedPhotoUrl(String storagePath);
}

const String _vehicleColumns =
    'id, owner_profile_id, service_area_id, name, vehicle_type, category, '
    'make, model, model_year, color, plate_number, price_per_day_centavos, '
    'status, rating, total_rentals, photo_paths';

const String _vehicleSelectColumns =
    '$_vehicleColumns, owner:profiles(full_name), '
    'service_area:service_areas(name)';

const String _photoBucket = 'vehicle-photos';

class SupabaseVehicleRepository implements VehicleRepository {
  SupabaseVehicleRepository(SurgoBackend backend, {this._writer, this._storage})
    : _backend = backend;

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;
  final SurgoStorageBackend? _storage;

  @override
  Future<List<VehicleRecord>> fetchVehiclesOwnedBy(
    String ownerProfileId,
  ) async {
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
    List<String> vehicleIds,
  ) async {
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
    List<String> vehicleIds,
  ) async {
    if (vehicleIds.isEmpty) return const [];
    final rows = await _backend.rows(
      table: 'vehicle_documents',
      columns:
          'id, vehicle_id, document_type, document_number, storage_path, '
          'issued_at, expires_at, status, rejection_reason',
      whereIn: {'vehicle_id': vehicleIds},
      orderBy: 'created_at',
    );
    return [for (final row in rows) VehicleDocumentRecord.fromRow(row)];
  }

  @override
  Future<VehicleRecord> createVehicle({
    required String ownerProfileId,
    required VehicleDraft draft,
    List<VehiclePhotoUpload> photos = const [],
  }) async {
    final writer = _requireWriter();
    final storage = _requireStorage();
    final uploaded = <String>[];
    try {
      final paths = <String>[];
      for (var i = 0; i < photos.length; i++) {
        final path = _photoStoragePath(ownerProfileId, photos[i], i);
        await writer.uploadObject(
          bucket: _photoBucket,
          path: path,
          bytes: photos[i].bytes,
          contentType: photos[i].contentType,
        );
        uploaded.add(path);
        paths.add(path);
      }

      final result = await writer.rpc(
        function: 'create_vehicle',
        params: {
          'p_name': draft.name.trim(),
          'p_vehicle_type': draft.vehicleType,
          'p_category': draft.category,
          'p_plate_number': draft.plateNumber.trim(),
          'p_price_per_day_centavos': draft.pricePerDayCentavos,
          'p_service_area_id': draft.serviceAreaId,
          'p_make': _clean(draft.make),
          'p_model': _clean(draft.model),
          'p_model_year': draft.modelYear,
          'p_color': _clean(draft.color),
          'p_photo_paths': paths,
        },
      );
      final id = result is String ? result : result?.toString();
      if (id == null || id.isEmpty) {
        throw RepositoryFailure.invalidData(
          'The vehicle was created but its id was not returned.',
        );
      }

      final record = await fetchVehicle(id);
      if (record == null) {
        throw RepositoryFailure.invalidData(
          'The vehicle was created but could not be read back.',
        );
      }
      return record;
    } catch (_) {
      // The RPC never ran (or did not commit), so every uploaded object is an
      // orphan. Removing them here keeps the bucket from accumulating files the
      // owner cannot see.
      await _removeQuietly(storage, uploaded);
      rethrow;
    }
  }

  @override
  Future<VehicleRecord> updateVehicle({
    required String ownerProfileId,
    required String vehicleId,
    required VehicleDraft draft,
    List<VehiclePhotoUpload> photos = const [],
    List<String> removePhotoPaths = const [],
  }) async {
    final writer = _requireWriter();
    final storage = _requireStorage();
    final existing = await fetchVehicle(vehicleId);
    if (existing == null) throw RepositoryFailure.notFound();

    final uploaded = <String>[];
    try {
      final newPaths = <String>[];
      for (var i = 0; i < photos.length; i++) {
        final path = _photoStoragePath(ownerProfileId, photos[i], i);
        await writer.uploadObject(
          bucket: _photoBucket,
          path: path,
          bytes: photos[i].bytes,
          contentType: photos[i].contentType,
        );
        uploaded.add(path);
        newPaths.add(path);
      }

      final remaining = [
        for (final path in existing.photoPaths)
          if (!removePhotoPaths.contains(path)) path,
        ...newPaths,
      ];
      // Null means "leave the stored list alone"; an explicit list replaces it.
      final photoPaths = (photos.isEmpty && removePhotoPaths.isEmpty)
          ? null
          : remaining;

      await writer.rpc(
        function: 'update_vehicle',
        params: {
          'p_vehicle_id': vehicleId,
          'p_name': draft.name.trim(),
          'p_vehicle_type': draft.vehicleType,
          'p_category': draft.category,
          'p_plate_number': draft.plateNumber.trim(),
          'p_price_per_day_centavos': draft.pricePerDayCentavos,
          'p_service_area_id': draft.serviceAreaId,
          'p_make': _clean(draft.make),
          'p_model': _clean(draft.model),
          'p_model_year': draft.modelYear,
          'p_color': _clean(draft.color),
          'p_listed': draft.listed,
          'p_photo_paths': photoPaths,
        },
      );

      final record = await fetchVehicle(vehicleId);
      if (record == null) {
        throw RepositoryFailure.invalidData(
          'The vehicle was saved but could not be read back.',
        );
      }
      await _removeQuietly(storage, removePhotoPaths);
      return record;
    } catch (_) {
      await _removeQuietly(storage, uploaded);
      rethrow;
    }
  }

  @override
  Future<VehicleRecord> setListingStatus({
    required String vehicleId,
    required bool listed,
  }) async {
    final writer = _requireWriter();
    await writer.rpc(
      function: 'set_vehicle_listing',
      params: {'p_vehicle_id': vehicleId, 'p_listed': listed},
    );
    final record = await fetchVehicle(vehicleId);
    if (record == null) throw RepositoryFailure.notFound();
    return record;
  }

  @override
  Future<String> signedPhotoUrl(String storagePath) {
    return _requireStorage().signedObjectUrl(
      bucket: _photoBucket,
      path: storagePath,
    );
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

  SurgoWriteBackend _requireWriter() {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot write vehicle listings.',
      );
    }
    return writer;
  }

  SurgoStorageBackend _requireStorage() {
    final storage = _storage;
    if (storage == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot load vehicle photos.',
      );
    }
    return storage;
  }

  String _photoStoragePath(
    String ownerProfileId,
    VehiclePhotoUpload photo,
    int index,
  ) {
    final extension = photo.contentType == 'image/png'
        ? 'png'
        : photo.contentType == 'image/webp'
        ? 'webp'
        : 'jpg';
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '$ownerProfileId/vehicles/$stamp-$index.$extension';
  }

  Future<void> _removeQuietly(
    SurgoStorageBackend storage,
    List<String> paths,
  ) async {
    for (final path in paths) {
      try {
        await storage.removeObject(bucket: _photoBucket, path: path);
      } catch (_) {
        // Cleanup is best effort: the row already points at the new list.
      }
    }
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// Reads the seeded `vehicles.json` slice.
///
/// The seed states availability in the status column (`Listed`, `Rented`,
/// `Maintenance`); the database keeps only listing state there and derives
/// occupancy from bookings. `rented` and `maintenance` are therefore mock-only
/// tokens that [VehicleRecord] still labels correctly, so the owner fleet screen
/// can move onto the repository without flattening three chips into one.
class MockVehicleRepository implements VehicleRepository {
  MockVehicleRepository([DbService? database])
    : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<VehicleRecord>> fetchVehiclesOwnedBy(
    String ownerProfileId,
  ) async {
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
    List<String> vehicleIds,
  ) async {
    return [
      for (final vehicle in _db.ownerVehicles)
        if (vehicleIds.contains(vehicle.id)) _toRecord(vehicle),
    ];
  }

  @override
  Future<List<VehicleRecord>> fetchListedVehicles({
    String? serviceAreaId,
  }) async {
    // Same row set as before the vocabulary split: a listed vehicle that is
    // currently out on rental is still a listing, only not free right now.
    final fleet = [for (final vehicle in _db.ownerVehicles) _toRecord(vehicle)];
    return [
      for (final record in fleet)
        if (record.isListed) record,
    ];
  }

  @override
  Future<List<VehicleDocumentRecord>> fetchDocuments(
    List<String> vehicleIds,
  ) async {
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
          expiresAt: document.expiresAt,
        ),
    ];
  }

  @override
  Future<VehicleRecord> createVehicle({
    required String ownerProfileId,
    required VehicleDraft draft,
    List<VehiclePhotoUpload> photos = const [],
  }) async {
    final vehicle = OwnedVehicle(
      id: 'ov${DateTime.now().microsecondsSinceEpoch}',
      name: draft.name.trim(),
      type: draft.vehicleType,
      category: draft.category,
      plate: draft.plateNumber.trim(),
      pricePerDay: draft.pricePerDayCentavos,
      status: draft.listed ? 'Listed' : 'Unlisted',
      rating: 5,
      totalRentals: 0,
      make: draft.make,
      model: draft.model,
      modelYear: draft.modelYear,
      color: draft.color,
    );
    _db.ownerVehicles.add(vehicle);
    return _toRecord(vehicle);
  }

  @override
  Future<VehicleRecord> updateVehicle({
    required String ownerProfileId,
    required String vehicleId,
    required VehicleDraft draft,
    List<VehiclePhotoUpload> photos = const [],
    List<String> removePhotoPaths = const [],
  }) async {
    final index = _db.ownerVehicles.indexWhere((v) => v.id == vehicleId);
    if (index < 0) throw RepositoryFailure.notFound();
    final existing = _db.ownerVehicles[index];
    final next = OwnedVehicle(
      id: existing.id,
      name: draft.name.trim(),
      type: draft.vehicleType,
      category: draft.category,
      plate: draft.plateNumber.trim(),
      pricePerDay: draft.pricePerDayCentavos,
      status: _nextMockStatus(existing.status, draft.listed),
      rating: existing.rating,
      totalRentals: existing.totalRentals,
      make: draft.make,
      model: draft.model,
      modelYear: draft.modelYear,
      color: draft.color,
      photoPaths: existing.photoPaths,
    );
    _db.ownerVehicles[index] = next;
    return _toRecord(next);
  }

  @override
  Future<VehicleRecord> setListingStatus({
    required String vehicleId,
    required bool listed,
  }) async {
    final index = _db.ownerVehicles.indexWhere((v) => v.id == vehicleId);
    if (index < 0) throw RepositoryFailure.notFound();
    final existing = _db.ownerVehicles[index];
    existing.status = _nextMockStatus(existing.status, listed);
    return _toRecord(existing);
  }

  @override
  Future<String> signedPhotoUrl(String storagePath) async {
    throw RepositoryFailure.unsupported(
      'The seeded build keeps vehicle photos in memory only.',
    );
  }

  VehicleRecord _toRecord(OwnedVehicle vehicle) => VehicleRecord(
    id: vehicle.id,
    ownerProfileId: _db.vehicleOwner.id,
    serviceAreaId: mockServiceAreaId,
    name: vehicle.name,
    vehicleType: vehicle.type,
    category: vehicle.category,
    plateNumber: vehicle.plate,
    make: vehicle.make,
    model: vehicle.model,
    modelYear: vehicle.modelYear,
    color: vehicle.color,
    pricePerDayCentavos: vehicle.pricePerDay,
    status: _statusToken(vehicle.status),
    rating: vehicle.rating,
    totalRentals: vehicle.totalRentals,
    photoPaths: vehicle.photoPaths,
    ownerName: _db.vehicleOwner.name,
  );

  static String _nextMockStatus(String current, bool listed) {
    // A rented or maintenance vehicle keeps that operational state; the toggle
    // only decides whether a free vehicle appears in the catalogue.
    if (current == 'Rented' || current == 'Maintenance') return current;
    return listed ? 'Listed' : 'Unlisted';
  }

  static String _statusToken(String label) => switch (label) {
    'Listed' => 'active',
    'Rented' => 'rented',
    'Maintenance' => 'maintenance',
    'Unlisted' => 'inactive',
    _ => 'pending_verification',
  };

  static String _documentStatus(String label) => switch (label.toLowerCase()) {
    'verified' || 'approved' => 'approved',
    'rejected' => 'rejected',
    'expired' => 'expired',
    _ => 'pending',
  };
}
