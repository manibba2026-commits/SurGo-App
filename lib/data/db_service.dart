import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../services/fee_calculator.dart';
import 'db_models.dart';

/// Loads the seed assets listed in `assets/db/manifest.json` and exposes them as
/// typed in-memory lists/objects. This is the app's "temporary database" — every
/// screen reads its mock data through here and edits/mutations only ever happen
/// in memory (nothing is written back to disk, so a refresh restores the seed).
///
/// The seed is split by domain (config, users, locations, vehicles, rides,
/// rentals, pasuyo, wallets, earnings) so each file can grow on its own. The
/// manifest is the single place that says which files exist and what order they
/// load in; DbService still exposes flat typed accessors so screens never touch
/// raw JSON.
///
/// Every amount in every file is an integer number of centavos — see `Money`.
class DbService {
  DbService._internal();
  static final DbService instance = DbService._internal();

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Bumped whenever a seed file changes shape, so migrations can branch.
  int schemaVersion = 1;
  String cityName = 'Tandag City';

  /// The manifest decides which domain files exist and in what order; both
  /// paths must stay in sync with the assets list in pubspec.yaml.
  static const String manifestPath = 'assets/db/manifest.json';
  static const String mapPath = 'assets/data/surgo_map_v1_mock_data.json';

  late PassengerProfile passenger;
  late EarnerProfile earner;
  late VehicleOwnerProfile vehicleOwner;

  late List<Barangay> barangays;
  late List<PlaceItem> places;
  late List<RideRequestItem> rideRequests;
  late List<VehicleDocumentItem> vehicleDocuments;
  late List<OwnedVehicle> ownerVehicles;
  late List<OwnerBookingRequest> ownerBookingRequests;
  late int ownerEarningsToday;
  late int ownerEarningsWeek;
  late int ownerEarningsMonth;

  late List<NotificationItem> passengerNotifications;
  late List<NotificationItem> earnerNotifications;

  late int passengerWalletBalance;
  late List<WalletTransaction> passengerTransactions;
  late int earnerWalletBalance;
  late List<WalletTransaction> earnerTransactions;
  late int ownerWalletBalance;
  late List<WalletTransaction> ownerTransactions;

  late List<PaymentMethodItem> paymentMethods;
  late List<SavedPlace> savedPlaces;
  late List<FavoriteRider> favoriteRiders;
  late List<FavoriteVehicle> favoriteVehicles;
  late List<EmergencyContactItem> emergencyContacts;
  late List<RideHistoryItem> rideHistory;
  late List<RentalHistoryItem> rentalHistory;
  late List<RiderTripItem> riderTrips;

  late int earningsToday;
  late int earningsWeek;
  late int earningsMonth;
  late List<DailyEarning> dailyEarnings;
  late List<PayoutItem> payoutHistory;

  late List<PasuyoTask> pasuyoTasks;

  late AccountSettingsData passengerSettings;
  late AccountSettingsData earnerSettings;

  // ---- Map V1 (assets/data/surgo_map_v1_mock_data.json) ----
  late MapConfigData mapConfig;
  late List<MapRider> mapRiders;
  late List<MapRentalVehicle> mapRentalVehicles;
  late List<MapPassenger> mapPassengers;
  late List<MapRideRequest> mapRideRequests;

  Future<void> load() async {
    if (_loaded) return;
    final files = await _loadManifestFiles();

    _readConfig(_expect(files, 'config.json'));

    final users = _expect(files, 'users.json');
    passenger = PassengerProfile.fromJson(_map(users, 'passenger'));
    earner = EarnerProfile.fromJson(_map(users, 'earner'));
    vehicleOwner = VehicleOwnerProfile.fromJson(_map(users, 'vehicleOwner'));
    paymentMethods =
        _parseList(users, 'paymentMethods', PaymentMethodItem.fromJson);
    emergencyContacts = _parseList(
        users, 'emergencyContacts', EmergencyContactItem.fromJson);
    final fav = _map(users, 'favorites');
    favoriteRiders = _parseList(fav, 'riders', FavoriteRider.fromJson);
    favoriteVehicles = _parseList(fav, 'vehicles', FavoriteVehicle.fromJson);
    final notif = _map(users, 'notifications');
    passengerNotifications =
        _parseList(notif, 'passenger', NotificationItem.fromJson);
    earnerNotifications = _parseList(notif, 'earner', NotificationItem.fromJson);
    final settings = _map(users, 'accountSettings');
    passengerSettings = AccountSettingsData.fromJson(_map(settings, 'passenger'));
    earnerSettings = AccountSettingsData.fromJson(_map(settings, 'earner'));

    final locations = _expect(files, 'locations.json');
    barangays = _parseList(locations, 'barangays', Barangay.fromJson);
    places = _parseList(locations, 'places', PlaceItem.fromJson);
    savedPlaces = _parseList(locations, 'savedPlaces', SavedPlace.fromJson);

    final vehicles = _expect(files, 'vehicles.json');
    ownerVehicles = _parseList(vehicles, 'owned', OwnedVehicle.fromJson);
    vehicleDocuments =
        _parseList(vehicles, 'documents', VehicleDocumentItem.fromJson);
    ownerBookingRequests =
        _parseList(vehicles, 'bookingRequests', OwnerBookingRequest.fromJson);

    final rides = _expect(files, 'rides.json');
    rideRequests = _parseList(rides, 'requests', RideRequestItem.fromJson);
    rideHistory = _parseList(rides, 'history', RideHistoryItem.fromJson);

    final rentals = _expect(files, 'rentals.json');
    rentalHistory = _parseList(rentals, 'history', RentalHistoryItem.fromJson);

    _readWallets(_expect(files, 'wallets.json'));
    _readEarnings(_expect(files, 'earnings.json'));

    pasuyoTasks =
        _parseList(_expect(files, 'pasuyo.json'), 'tasks', PasuyoTask.fromJson);

    // Map V1 — separate asset file per the SurGo map data architecture;
    // parsed into the same DbService rather than a standalone data system.
    final mj = await _loadJson(mapPath);
    mapConfig = MapConfigData.fromJson(_map(mj, 'map_config'));
    mapRiders = _parseList(mj, 'riders', MapRider.fromJson);
    mapRentalVehicles =
        _parseList(mj, 'rental_vehicles', MapRentalVehicle.fromJson);
    mapPassengers = _parseList(mj, 'passengers', MapPassenger.fromJson);
    mapRideRequests = _parseList(mj, 'ride_requests', MapRideRequest.fromJson);

    _loaded = true;
  }

  /// Reads the manifest, then loads each declared file into a map keyed by the
  /// name used in the manifest. A name in the manifest that is missing from the
  /// bundle throws, because that is a build/pubspec bug rather than bad data.
  Future<Map<String, Map<String, dynamic>>> _loadManifestFiles() async {
    final manifest = await _loadJson(manifestPath);
    schemaVersion = (manifest['schemaVersion'] as num?)?.toInt() ?? 1;
    cityName = manifest['city'] as String? ?? cityName;

    final loaded = <String, Map<String, dynamic>>{};
    final names = (manifest['files'] as List? ?? const []).whereType<String>();
    for (final name in names) {
      loaded[name] = await _loadJson('assets/db/$name');
    }
    return loaded;
  }

  void _readConfig(Map<String, dynamic> config) {
    final bps = _map(config, 'commissionBps');
    FeeRates.configure(
      ride: (bps['ride'] as num?)?.toInt() ?? 0,
      pasuyo: (bps['pasuyo'] as num?)?.toInt() ?? 0,
      rental: (bps['rental'] as num?)?.toInt() ?? 0,
    );
  }

  /// `wallets.json` holds one entry per role, each a balance plus its own
  /// transaction log. A missing role falls back to an empty wallet so an
  /// incomplete file still boots.
  void _readWallets(Map<String, dynamic> file) {
    final roles = {
      for (final entry in _list(file, 'roles'))
        if (entry['role'] is String) entry['role'] as String: entry,
    };
    final pw = roles['passenger'] ?? const {};
    passengerWalletBalance = (pw['balance'] as num?)?.toInt() ?? 0;
    passengerTransactions =
        _parseList(pw, 'transactions', WalletTransaction.fromJson);

    final ew = roles['earner'] ?? const {};
    earnerWalletBalance = (ew['balance'] as num?)?.toInt() ?? 0;
    earnerTransactions =
        _parseList(ew, 'transactions', WalletTransaction.fromJson);

    final ow = roles['owner'] ?? const {};
    ownerWalletBalance = (ow['balance'] as num?)?.toInt() ?? 0;
    ownerTransactions = _parseList(ow, 'transactions', WalletTransaction.fromJson);
  }

  void _readEarnings(Map<String, dynamic> file) {
    final earnerData = _map(file, 'earner');
    earningsToday = (earnerData['today'] as num?)?.toInt() ?? 0;
    earningsWeek = (earnerData['week'] as num?)?.toInt() ?? 0;
    earningsMonth = (earnerData['month'] as num?)?.toInt() ?? 0;
    dailyEarnings = _parseList(earnerData, 'daily', DailyEarning.fromJson);
    payoutHistory =
        _parseList(earnerData, 'payoutHistory', PayoutItem.fromJson);
    riderTrips = _parseList(earnerData, 'trips', RiderTripItem.fromJson);

    final owner = _map(file, 'owner');
    ownerEarningsToday = (owner['today'] as num?)?.toInt() ?? 0;
    ownerEarningsWeek = (owner['week'] as num?)?.toInt() ?? 0;
    ownerEarningsMonth = (owner['month'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> _loadJson(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return json.decode(raw) as Map<String, dynamic>;
  }

  /// A file the manifest promised but that did not load. Throwing here beats
  /// letting a screen read a half-initialised field.
  Map<String, dynamic> _expect(
      Map<String, Map<String, dynamic>> files, String name) {
    final file = files[name];
    if (file == null) {
      throw StateError('manifest.json lists $name but it did not load');
    }
    return file;
  }

  Map<String, dynamic> _map(Map<String, dynamic> file, String key) {
    final raw = file[key];
    return raw is Map<String, dynamic> ? raw : const {};
  }

  List<Map<String, dynamic>> _list(Map<String, dynamic> file, String key) {
    final raw = file[key];
    if (raw is! List) return const [];
    return [for (final e in raw) if (e is Map<String, dynamic>) e];
  }

  /// Parses a list section, ignoring entries that are not objects. An absent
  /// section yields an empty list rather than throwing, so one incomplete file
  /// cannot stop the app booting — an empty screen is easier to diagnose than a
  /// crash on launch.
  List<T> _parseList<T>(
    Map<String, dynamic> file,
    String key,
    T Function(Map<String, dynamic>) parse,
  ) =>
      [for (final e in _list(file, key)) parse(e)];
}