import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';
import 'repository_mappers.dart';

/// The three personal lists every account owns: its pinned places and the
/// riders and rental listings it starred.
///
/// Reads are plain row reads the database scopes to the signed-in account
/// (`profile_id = auth.uid()`); every write goes through a server-side
/// function that derives the owner from the session, so no client input ever
/// decides whose row is created or removed. Display data (a rider's name and
/// rating, a vehicle's price and owner) is not stored with the star — it is
/// re-derived from the live profile, presence and listing rows on every read,
/// with the same generic wording (`Rider`, `Vehicle Owner`) the rest of the
/// app uses when that row is not visible to this reader under RLS.
abstract interface class PersonalListRepository {
  /// This account's pinned locations, oldest first.
  Future<List<SavedPlace>> fetchSavedPlaces();

  /// Saves a pin. Re-saving a label rewrites that pin instead of duplicating
  /// it. Returns the place id the row now answers to.
  Future<String> addSavedPlace({
    required String label,
    required String address,
    String icon = 'place',
  });

  /// Removes one pinned place. Returns the removed row count; 0 means the id
  /// was never this account's place and nothing changed.
  Future<int> removeSavedPlace(String placeId);

  /// The riders this account starred, oldest first.
  Future<List<FavoriteRider>> fetchFavoriteRiders();

  /// Stars a rider. Idempotent: an existing star stays one row.
  Future<void> addFavoriteRider(String riderProfileId);

  /// Unstars a rider. Returns the removed row count; 0 means it was not
  /// starred, which is the state the caller asked for.
  Future<int> removeFavoriteRider(String riderProfileId);

  /// The rental listings this account starred, oldest first.
  Future<List<FavoriteVehicle>> fetchFavoriteVehicles();

  /// Stars a rental listing. Idempotent. An unknown vehicle id is refused by
  /// the database's foreign key.
  Future<void> addFavoriteVehicle(String vehicleId);

  /// Unstars a rental listing. Returns the removed row count.
  Future<int> removeFavoriteVehicle(String vehicleId);

  /// The rider profile whose display name matches, or null when none or more
  /// than one readable profile does. Names are not unique, so this is a
  /// fallback for a star made from a trip whose rider id was not carried
  /// through — the ride counterparty lookup in [AppState] is the primary path.
  Future<String?> findRiderProfileIdByName(String fullName);

  /// The listed vehicle whose name matches, or null when none or more than
  /// one readable listing does.
  Future<String?> findVehicleIdByName(String name);
}

class SupabasePersonalListRepository implements PersonalListRepository {
  SupabasePersonalListRepository(this._backend, {this._writer});

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;

  @override
  Future<List<SavedPlace>> fetchSavedPlaces() async {
    final rows = await _backend.rows(
      table: 'saved_places',
      columns: 'id, label, address, icon',
      orderBy: 'created_at',
      ascending: true,
    );
    return [
      for (final row in rows)
        SavedPlace(
          id: requireText(row, 'id'),
          label: requireText(row, 'label'),
          address: requireText(row, 'address'),
          icon: optionalText(row, 'icon') ?? 'place',
        ),
    ];
  }

  @override
  Future<String> addSavedPlace({
    required String label,
    required String address,
    String icon = 'place',
  }) async {
    final result = await _requireWriter().rpc(
      function: 'add_saved_place',
      params: {'p_label': label, 'p_address': address, 'p_icon': icon},
    );
    final id = _rpcId(result);
    if (id == null) {
      throw RepositoryFailure.unavailable(
        'The server did not return the saved place.',
      );
    }
    return id;
  }

  @override
  Future<int> removeSavedPlace(String placeId) async {
    final result = await _requireWriter().rpc(
      function: 'delete_saved_place',
      params: {'p_place_id': placeId},
    );
    return _rpcCount(result);
  }

  @override
  Future<List<FavoriteRider>> fetchFavoriteRiders() async {
    final stars = await _backend.rows(
      table: 'favorite_riders',
      columns: 'id, rider_profile_id',
      orderBy: 'created_at',
      ascending: true,
    );
    if (stars.isEmpty) return const [];
    final riderIds = [
      for (final star in stars) requireText(star, 'rider_profile_id'),
    ];
    // The starred rider's own row is only readable while this account shares a
    // ride with them and their presence is online, so both reads may come back
    // without the row. The star still resolves: un-starring keys on the stored
    // rider profile id, never on the rendered name.
    final profiles = <String, Map<String, dynamic>>{};
    final presence = <String, Map<String, dynamic>>{};
    for (final row in await _backend.rows(
      table: 'profiles',
      columns: 'id, full_name, rating, total_rides',
      whereIn: {'id': riderIds},
    )) {
      profiles[requireText(row, 'id')] = row;
    }
    for (final row in await _backend.rows(
      table: 'rider_presence',
      columns: 'profile_id, vehicle_type, vehicle_plate',
      whereIn: {'profile_id': riderIds},
    )) {
      presence[requireText(row, 'profile_id')] = row;
    }
    return [
      for (final star in stars) _favoriteRiderFromRow(star, profiles, presence),
    ];
  }

  @override
  Future<void> addFavoriteRider(String riderProfileId) async {
    await _requireWriter().rpc(
      function: 'add_favorite_rider',
      params: {'p_rider_profile_id': riderProfileId},
    );
  }

  @override
  Future<int> removeFavoriteRider(String riderProfileId) async {
    final result = await _requireWriter().rpc(
      function: 'remove_favorite_rider',
      params: {'p_rider_profile_id': riderProfileId},
    );
    return _rpcCount(result);
  }

  @override
  Future<List<FavoriteVehicle>> fetchFavoriteVehicles() async {
    final stars = await _backend.rows(
      table: 'favorite_vehicles',
      columns: 'id, vehicle_id',
      orderBy: 'created_at',
      ascending: true,
    );
    if (stars.isEmpty) return const [];
    final vehicleIds = [
      for (final star in stars) requireText(star, 'vehicle_id'),
    ];
    // A listing the owner has since unlisted stops being readable
    // (`vehicles_read_listed_or_own`); the star renders with the listing
    // fallbacks and still resolves, because the unstar keys on the vehicle id.
    final vehicles = <String, VehicleRecord>{};
    for (final row in await _backend.rows(
      table: 'vehicles',
      columns: _vehicleColumns,
      whereIn: {'id': vehicleIds},
    )) {
      final record = VehicleRecord.fromRow(row);
      vehicles[record.id] = record;
    }
    return [
      for (final star in stars)
        _favoriteVehicleFromRow(
          vehicleId: requireText(star, 'vehicle_id'),
          vehicles: vehicles,
        ),
    ];
  }

  @override
  Future<void> addFavoriteVehicle(String vehicleId) async {
    await _requireWriter().rpc(
      function: 'add_favorite_vehicle',
      params: {'p_vehicle_id': vehicleId},
    );
  }

  @override
  Future<int> removeFavoriteVehicle(String vehicleId) async {
    final result = await _requireWriter().rpc(
      function: 'remove_favorite_vehicle',
      params: {'p_vehicle_id': vehicleId},
    );
    return _rpcCount(result);
  }

  @override
  Future<String?> findRiderProfileIdByName(String fullName) async {
    // RLS already limits this read to self, admins and ride counterparties, so
    // an unreadable rider returns no row rather than someone else's.
    final rows = await _backend.rows(
      table: 'profiles',
      columns: 'id',
      eq: {'full_name': fullName},
    );
    if (rows.length != 1) return null;
    return requireText(rows.first, 'id');
  }

  @override
  Future<String?> findVehicleIdByName(String name) async {
    final rows = await _backend.rows(
      table: 'vehicles',
      columns: 'id, status',
      eq: {'name': name},
    );
    final listed = [
      for (final row in rows)
        if (optionalText(row, 'status') == 'active') requireText(row, 'id'),
    ];
    // A name is not an identity: two owners can both list a "Suzuki Multicab",
    // so an ambiguous match resolves to nothing instead of a guess.
    return listed.length == 1 ? listed.first : null;
  }

  FavoriteRider _favoriteRiderFromRow(
    Map<String, dynamic> star,
    Map<String, Map<String, dynamic>> profiles,
    Map<String, Map<String, dynamic>> presence,
  ) {
    final riderId = requireText(star, 'rider_profile_id');
    final profile = profiles[riderId];
    final snapshot = presence[riderId];
    final name = (profile == null
        ? null
        : optionalText(profile, 'full_name')) ??
        'Rider';
    return FavoriteRider(
      id: riderId,
      name: name,
      initials: initialsFor(name),
      rating: profile == null ? 0 : optionalDouble(profile, 'rating') ?? 0,
      trips: profile == null ? 0 : optionalInt(profile, 'total_rides'),
      vehicleType: snapshot == null
          ? '—'
          : optionalText(snapshot, 'vehicle_type') ?? '—',
      plate: snapshot == null ? '—' : optionalText(snapshot, 'vehicle_plate') ?? '—',
    );
  }

  FavoriteVehicle _favoriteVehicleFromRow({
    required String vehicleId,
    required Map<String, VehicleRecord> vehicles,
  }) {
    final record = vehicles[vehicleId];
    return FavoriteVehicle(
      id: vehicleId,
      name: record?.name ?? 'Saved listing',
      type: record?.vehicleType ?? '—',
      pricePerDay: record?.pricePerDayCentavos ?? 0,
      ownerName: record?.ownerName ?? 'Vehicle Owner',
    );
  }

  SurgoWriteBackend _requireWriter() {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot change saved places or favorites.',
      );
    }
    return writer;
  }

  static String? _rpcId(Object? result) {
    if (result is String && result.isNotEmpty) return result;
    if (result is List && result.isNotEmpty) return _rpcId(result.first);
    return null;
  }

  static int _rpcCount(Object? result) {
    if (result is int) return result;
    if (result is num) return result.toInt();
    if (result is String) return int.tryParse(result) ?? 0;
    if (result is List && result.isNotEmpty) return _rpcCount(result.first);
    return 0;
  }
}

const String _vehicleColumns =
    'id, owner_profile_id, name, vehicle_type, category, plate_number, '
    'price_per_day_centavos, rating, owner:profiles(full_name)';

/// Reads and mutates the seeded lists, the way the presentation build's
/// [AppState] writes always have. The seed's personal lists stay display
/// fixtures: a mock "star" only appends a stub row, because an offline demo
/// has no real rider or vehicle behind it to look up.
class MockPersonalListRepository implements PersonalListRepository {
  MockPersonalListRepository([DbService? database])
    : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<SavedPlace>> fetchSavedPlaces() async =>
      List.of(_db.savedPlaces);

  @override
  Future<String> addSavedPlace({
    required String label,
    required String address,
    String icon = 'place',
  }) async {
    final id = 'sp${DateTime.now().microsecondsSinceEpoch}';
    _db.savedPlaces.add(
      SavedPlace(id: id, label: label, address: address, icon: icon),
    );
    return id;
  }

  @override
  Future<int> removeSavedPlace(String placeId) async {
    final before = _db.savedPlaces.length;
    _db.savedPlaces.removeWhere((place) => place.id == placeId);
    return before - _db.savedPlaces.length;
  }

  @override
  Future<List<FavoriteRider>> fetchFavoriteRiders() async =>
      List.of(_db.favoriteRiders);

  @override
  Future<void> addFavoriteRider(String riderProfileId) async {
    if (_db.favoriteRiders.any((rider) => rider.id == riderProfileId)) return;
    _db.favoriteRiders.add(
      FavoriteRider(
        id: riderProfileId,
        name: 'Rider',
        initials: '?',
        rating: 0,
        trips: 0,
        vehicleType: '—',
        plate: '—',
      ),
    );
  }

  @override
  Future<int> removeFavoriteRider(String riderProfileId) async {
    final before = _db.favoriteRiders.length;
    _db.favoriteRiders.removeWhere((rider) => rider.id == riderProfileId);
    return before - _db.favoriteRiders.length;
  }

  @override
  Future<List<FavoriteVehicle>> fetchFavoriteVehicles() async =>
      List.of(_db.favoriteVehicles);

  @override
  Future<void> addFavoriteVehicle(String vehicleId) async {
    if (_db.favoriteVehicles.any((vehicle) => vehicle.id == vehicleId)) return;
    _db.favoriteVehicles.add(
      FavoriteVehicle(
        id: vehicleId,
        name: 'Saved listing',
        type: '—',
        pricePerDay: 0,
        ownerName: 'Vehicle Owner',
      ),
    );
  }

  @override
  Future<int> removeFavoriteVehicle(String vehicleId) async {
    final before = _db.favoriteVehicles.length;
    _db.favoriteVehicles.removeWhere((vehicle) => vehicle.id == vehicleId);
    return before - _db.favoriteVehicles.length;
  }

  @override
  Future<String?> findRiderProfileIdByName(String fullName) async => null;

  @override
  Future<String?> findVehicleIdByName(String name) async => null;
}
