import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';

/// The service area the seed stands in for Tandag City.
const String mockServiceAreaId = 'sa-tandag-city';

/// Service geography and pricing configuration.
abstract interface class CatalogRepository {
  Future<List<ServiceAreaRecord>> fetchServiceAreas();

  /// Barangays in [serviceAreaId], each with its puroks.
  Future<List<BarangayRecord>> fetchBarangays(String serviceAreaId);

  Future<PurokRecord?> fetchPurok(String purokId);

  /// The active policy per service type. No policy is seeded or approved, so an
  /// empty list is the expected production answer today.
  Future<List<PricingPolicyRecord>> fetchActivePricingPolicies();

  /// Landmarks for the pickup/dropoff picker.
  Future<List<PlaceRecord>> fetchPlaces();
}

/// A named landmark. The deployed schema has no table for these yet, so the
/// Supabase implementation refuses instead of serving seed coordinates.
class PlaceRecord {
  const PlaceRecord({
    required this.id,
    required this.label,
    required this.address,
    required this.barangay,
    required this.purok,
    required this.latitude,
    required this.longitude,
    required this.category,
  });

  final String id;
  final String label;
  final String address;
  final String barangay;
  final String purok;
  final double latitude;
  final double longitude;
  final String category;
}

class SupabaseCatalogRepository implements CatalogRepository {
  SupabaseCatalogRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

  @override
  Future<List<ServiceAreaRecord>> fetchServiceAreas() async {
    final rows = await _backend.rows(
      table: 'service_areas',
      columns: 'id, name, city, province, country_code, timezone, '
          'center_latitude, center_longitude, is_active',
      eq: {'is_active': true},
      orderBy: 'name',
      ascending: true,
    );
    return [for (final row in rows) ServiceAreaRecord.fromRow(row)];
  }

  @override
  Future<List<BarangayRecord>> fetchBarangays(String serviceAreaId) async {
    final rows = await _backend.rows(
      table: 'barangays',
      columns: 'id, name, service_area_id, puroks(id, name, barangay_id)',
      eq: {'service_area_id': serviceAreaId},
      orderBy: 'name',
      ascending: true,
    );
    return [for (final row in rows) BarangayRecord.fromRow(row)];
  }

  @override
  Future<PurokRecord?> fetchPurok(String purokId) async {
    final row = await _backend.row(
      table: 'puroks',
      columns: 'id, name, barangay_id',
      eq: {'id': purokId},
    );
    return row == null ? null : PurokRecord.fromRow(row);
  }

  @override
  Future<List<PricingPolicyRecord>> fetchActivePricingPolicies() async {
    final rows = await _backend.rows(
      table: 'pricing_policies',
      columns: 'id, name, description, service_type, currency, '
          'base_fare_centavos, per_km_centavos, per_minute_centavos, '
          'minimum_fare_centavos, platform_fee_fixed_centavos, '
          'platform_fee_bps, effective_from, effective_to, is_active',
      eq: {'is_active': true},
      orderBy: 'effective_from',
    );
    return [for (final row in rows) PricingPolicyRecord.fromRow(row)];
  }

  @override
  Future<List<PlaceRecord>> fetchPlaces() async {
    throw RepositoryFailure.unsupported(
      'Landmarks have no Supabase table yet, so this build cannot read them '
      'from the database.',
    );
  }
}

class MockCatalogRepository implements CatalogRepository {
  MockCatalogRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<ServiceAreaRecord>> fetchServiceAreas() async {
    return [
      const ServiceAreaRecord(
        id: mockServiceAreaId,
        name: 'Tandag City',
        city: 'Tandag City',
        province: 'Surigao del Sur',
      ),
    ];
  }

  @override
  Future<List<BarangayRecord>> fetchBarangays(String serviceAreaId) async {
    var index = 0;
    return [
      for (final barangay in _db.barangays)
        () {
          final barangayId = '$_mockIdPrefix-barangay-${index++}';
          return BarangayRecord(
            id: barangayId,
            name: barangay.name,
            serviceAreaId: serviceAreaId,
            puroks: [
              for (var p = 0; p < barangay.puroks.length; p++)
                PurokRecord(
                  id: '$barangayId-purok-$p',
                  name: barangay.puroks[p],
                  barangayId: barangayId,
                ),
            ],
          );
        }(),
    ];
  }

  @override
  Future<PurokRecord?> fetchPurok(String purokId) async {
    for (final barangay in await fetchBarangays(mockServiceAreaId)) {
      for (final purok in barangay.puroks) {
        if (purok.id == purokId) return purok;
      }
    }
    return null;
  }

  @override
  Future<List<PricingPolicyRecord>> fetchActivePricingPolicies() async {
    // The seed carries commission as basis points on the fee calculator rather
    // than as a policy row, and no policy is approved in production either.
    return const [];
  }

  @override
  Future<List<PlaceRecord>> fetchPlaces() async {
    return [
      for (final place in _db.places)
        PlaceRecord(
          id: place.id,
          label: place.label,
          address: place.address,
          barangay: place.barangay,
          purok: place.purok,
          latitude: place.latitude,
          longitude: place.longitude,
          category: place.category,
        ),
    ];
  }
}

const String _mockIdPrefix = 'mock';
