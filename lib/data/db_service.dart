import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../services/fee_calculator.dart';
import '../services/ride_pricing.dart';
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

  /// The three "signed-in" slices the screens read. They always point at the
  /// profiles of the [activeAccount] (or the primary account before anyone has
  /// signed in), and [activateAccount] swaps them without the screens knowing.
  late PassengerProfile passenger;
  late EarnerProfile earner;
  late VehicleOwnerProfile vehicleOwner;

  /// Every profile in the seed, keyed by id, so an account can be activated by
  /// the ids it links to rather than by whichever profile loaded first.
  final Map<String, PassengerProfile> passengers = {};
  final Map<String, EarnerProfile> earners = {};
  final Map<String, VehicleOwnerProfile> owners = {};

  /// The account currently signed in, or null for the pre-login primary.
  Account? activeAccount;

  /// Seed accounts from `accounts.json`. Empty until [load] runs.
  List<Account> accounts = const [];

  /// Verification applications from `applications.json`, plus any created
  /// during this run.
  List<VerificationApplication> verificationApplications = const [];

  // Per-profile data, keyed by profile id, so activating an account also swaps
  // the wallet, notifications and settings the screens read from.
  final Map<String, int> walletBalanceByUser = {};
  final Map<String, List<WalletTransaction>> walletTransactionsByUser = {};
  final Map<String, List<NotificationItem>> notificationsByUser = {};
  final Map<String, AccountSettingsData> settingsByUser = {};

  /// The profile ids the app shows before anyone signs in, and the ones the
  /// seed tests pin. Keep these in sync with `accounts.json`.
  static const String primaryPassengerId = 'P001';
  static const String primaryEarnerId = 'R001';
  static const String primaryOwnerId = 'VOW-77213';

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

  /// Fallback minimum payout, in centavos, when the seed omits or breaks the
  /// `payouts.minWithdrawal` rule.
  static const int defaultPayoutMinWithdrawal = 30000;

  // ---- hosted-session isolation ----

  /// The Supabase account whose empty, session-owned slices are installed, or
  /// null while the seed is visible. The seed's history and request models do
  /// not carry an owner id yet, so the only safe value for an authenticated
  /// account is its own (empty) slice - never another person's seed rows.
  String? _isolatedAccountId;
  bool _seedSlicesSaved = false;

  List<RideRequestItem>? _seedRideRequests;
  List<RideHistoryItem>? _seedRideHistory;
  List<RentalHistoryItem>? _seedRentalHistory;
  List<RiderTripItem>? _seedRiderTrips;
  List<OwnedVehicle>? _seedOwnerVehicles;
  List<VehicleDocumentItem>? _seedVehicleDocuments;
  List<OwnerBookingRequest>? _seedOwnerBookingRequests;
  List<PasuyoTask>? _seedPasuyoTasks;
  List<PaymentMethodItem>? _seedPaymentMethods;
  List<SavedPlace>? _seedSavedPlaces;
  List<FavoriteRider>? _seedFavoriteRiders;
  List<FavoriteVehicle>? _seedFavoriteVehicles;
  List<EmergencyContactItem>? _seedEmergencyContacts;
  List<DailyEarning>? _seedDailyEarnings;
  List<PayoutItem>? _seedPayoutHistory;
  List<MapPassenger>? _seedMapPassengers;
  List<MapRideRequest>? _seedMapRideRequests;
  int? _seedEarningsToday;
  int? _seedEarningsWeek;
  int? _seedEarningsMonth;
  int? _seedOwnerEarningsToday;
  int? _seedOwnerEarningsWeek;
  int? _seedOwnerEarningsMonth;

  bool get hasIsolatedSession => _isolatedAccountId != null;

  /// Replaces every shared business collection with one owned by the hosted
  /// account. Repositories (Supabase-backed in a `SURGO_DATA_SOURCE=supabase`
  /// build) remain the source of truth; this keeps screens that still read
  /// [AppState] from falling back to demo records.
  void beginIsolatedSession(String accountId) {
    if (_isolatedAccountId == accountId) return;
    if (!_seedSlicesSaved) {
      _seedRideRequests = rideRequests;
      _seedRideHistory = rideHistory;
      _seedRentalHistory = rentalHistory;
      _seedRiderTrips = riderTrips;
      _seedOwnerVehicles = ownerVehicles;
      _seedVehicleDocuments = vehicleDocuments;
      _seedOwnerBookingRequests = ownerBookingRequests;
      _seedPasuyoTasks = pasuyoTasks;
      _seedPaymentMethods = paymentMethods;
      _seedSavedPlaces = savedPlaces;
      _seedFavoriteRiders = favoriteRiders;
      _seedFavoriteVehicles = favoriteVehicles;
      _seedEmergencyContacts = emergencyContacts;
      _seedDailyEarnings = dailyEarnings;
      _seedPayoutHistory = payoutHistory;
      _seedMapPassengers = mapPassengers;
      _seedMapRideRequests = mapRideRequests;
      _seedEarningsToday = earningsToday;
      _seedEarningsWeek = earningsWeek;
      _seedEarningsMonth = earningsMonth;
      _seedOwnerEarningsToday = ownerEarningsToday;
      _seedOwnerEarningsWeek = ownerEarningsWeek;
      _seedOwnerEarningsMonth = ownerEarningsMonth;
      _seedSlicesSaved = true;
    }

    _isolatedAccountId = accountId;
    rideRequests = <RideRequestItem>[];
    rideHistory = <RideHistoryItem>[];
    rentalHistory = <RentalHistoryItem>[];
    riderTrips = <RiderTripItem>[];
    ownerVehicles = <OwnedVehicle>[];
    vehicleDocuments = <VehicleDocumentItem>[];
    ownerBookingRequests = <OwnerBookingRequest>[];
    pasuyoTasks = <PasuyoTask>[];
    paymentMethods = <PaymentMethodItem>[];
    savedPlaces = <SavedPlace>[];
    favoriteRiders = <FavoriteRider>[];
    favoriteVehicles = <FavoriteVehicle>[];
    emergencyContacts = <EmergencyContactItem>[];
    dailyEarnings = <DailyEarning>[];
    payoutHistory = <PayoutItem>[];
    mapPassengers = <MapPassenger>[];
    mapRideRequests = <MapRideRequest>[];
    earningsToday = 0;
    earningsWeek = 0;
    earningsMonth = 0;
    ownerEarningsToday = 0;
    ownerEarningsWeek = 0;
    ownerEarningsMonth = 0;
  }

  /// Puts the seed collections back when the hosted session ends.
  void endIsolatedSession() {
    if (_isolatedAccountId == null) return;
    _isolatedAccountId = null;
    if (!_seedSlicesSaved) return;

    rideRequests = _seedRideRequests!;
    rideHistory = _seedRideHistory!;
    rentalHistory = _seedRentalHistory!;
    riderTrips = _seedRiderTrips!;
    ownerVehicles = _seedOwnerVehicles!;
    vehicleDocuments = _seedVehicleDocuments!;
    ownerBookingRequests = _seedOwnerBookingRequests!;
    pasuyoTasks = _seedPasuyoTasks!;
    paymentMethods = _seedPaymentMethods!;
    savedPlaces = _seedSavedPlaces!;
    favoriteRiders = _seedFavoriteRiders!;
    favoriteVehicles = _seedFavoriteVehicles!;
    emergencyContacts = _seedEmergencyContacts!;
    dailyEarnings = _seedDailyEarnings!;
    payoutHistory = _seedPayoutHistory!;
    mapPassengers = _seedMapPassengers!;
    mapRideRequests = _seedMapRideRequests!;
    earningsToday = _seedEarningsToday!;
    earningsWeek = _seedEarningsWeek!;
    earningsMonth = _seedEarningsMonth!;
    ownerEarningsToday = _seedOwnerEarningsToday!;
    ownerEarningsWeek = _seedOwnerEarningsWeek!;
    ownerEarningsMonth = _seedOwnerEarningsMonth!;
    _seedSlicesSaved = false;
  }

  /// Smallest payout `config.json` allows, in centavos. Enforced by
  /// [AppState.requestPayout] and [AppState.requestOwnerPayout] rather than
  /// only by the screens, so a payout cannot slip below the rule from another
  /// entry point.
  int payoutMinWithdrawal = defaultPayoutMinWithdrawal;

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
    _readUsers(users);

    accounts = _parseList(
        _expect(files, 'accounts.json'), 'accounts', Account.fromJson);

    verificationApplications = _parseList(_expect(files, 'applications.json'),
        'applications', VerificationApplication.fromJson);

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

    // Everyone starts signed out, so the app boots showing the primary account
    // exactly as it did before accounts existed.
    activatePrimary();

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
      pasuyo: (bps['pasuyo'] as num?)?.toInt() ?? 0,
      rental: (bps['rental'] as num?)?.toInt() ?? 0,
    );

    final fee = _map(config, 'platformFee');
    RidePricing.configure(
      perKm: (fee['perKmCentavos'] as num?)?.toInt() ?? 0,
      minimum: (fee['minCentavos'] as num?)?.toInt() ?? 0,
      maximum: (fee['maxCentavos'] as num?)?.toInt() ?? 0,
    );

    payoutMinWithdrawal = minWithdrawalFromConfig(
      config,
      fallback: payoutMinWithdrawal,
    );
  }

  /// Reads `payouts.minWithdrawal` from a parsed config file.
  ///
  /// A missing, malformed or non-positive value falls back to [fallback] so a
  /// broken seed cannot disable the payout floor and let a zero-value payout
  /// through. Exposed as a pure function so the fallback rules are testable
  /// without editing the seed.
  static int minWithdrawalFromConfig(
    Map<String, dynamic> config, {
    int fallback = defaultPayoutMinWithdrawal,
  }) {
    final payouts = config['payouts'];
    if (payouts is! Map<String, dynamic>) return fallback;
    final raw = payouts['minWithdrawal'];
    if (raw is! num) return fallback;
    final value = raw.toInt();
    return value > 0 ? value : fallback;
  }

  /// Reads `users.json`: the three profile collections, the collections still
  /// scoped to the primary account, and the per-profile notifications and
  /// settings. The three signed-in slices are pointed at the primary account by
  /// [activatePrimary] once wallets have loaded too.
  void _readUsers(Map<String, dynamic> users) {
    for (final p
        in _parseList(users, 'passengers', PassengerProfile.fromJson)) {
      passengers[p.id] = p;
    }
    for (final e in _parseList(users, 'earners', EarnerProfile.fromJson)) {
      earners[e.id] = e;
    }
    for (final o in _parseList(users, 'owners', VehicleOwnerProfile.fromJson)) {
      owners[o.id] = o;
    }

    paymentMethods =
        _parseList(users, 'paymentMethods', PaymentMethodItem.fromJson);
    emergencyContacts =
        _parseList(users, 'emergencyContacts', EmergencyContactItem.fromJson);
    final fav = _map(users, 'favorites');
    favoriteRiders = _parseList(fav, 'riders', FavoriteRider.fromJson);
    favoriteVehicles = _parseList(fav, 'vehicles', FavoriteVehicle.fromJson);

    // Notifications and settings are keyed by the profile id they belong to.
    _map(users, 'notifications').forEach((userId, raw) {
      if (raw is List) {
        notificationsByUser[userId] = [
          for (final e in raw)
            if (e is Map<String, dynamic>) NotificationItem.fromJson(e),
        ];
      }
    });
    _map(users, 'accountSettings').forEach((userId, raw) {
      if (raw is Map<String, dynamic>) {
        settingsByUser[userId] = AccountSettingsData.fromJson(raw);
      }
    });
  }

  /// `wallets.json` holds one wallet per profile id, each a balance plus its
  /// own transaction log. A missing wallet falls back to an empty one so an
  /// incomplete file still boots.
  void _readWallets(Map<String, dynamic> file) {
    for (final entry in _list(file, 'wallets')) {
      final userId = entry['userId'];
      if (userId is! String) continue;
      walletBalanceByUser[userId] = (entry['balance'] as num?)?.toInt() ?? 0;
      walletTransactionsByUser[userId] =
          _parseList(entry, 'transactions', WalletTransaction.fromJson);
    }
  }

  /// Points the three signed-in slices back at the primary seed account. Runs
  /// at boot (before anyone signs in) and on sign-out. An account that lacks a
  /// role gets a lightweight guest profile so shared screens still show the
  /// signed-in name instead of a stale one.
  void activatePrimary() {
    activeAccount = null;
    passenger = passengers[primaryPassengerId] ??
        (passengers.isEmpty ? _guestPassenger() : passengers.values.first);
    earner = earners[primaryEarnerId] ??
        (earners.isEmpty ? _guestEarner() : earners.values.first);
    vehicleOwner = owners[primaryOwnerId] ??
        (owners.isEmpty ? _guestOwner() : owners.values.first);

    passengerWalletBalance = walletBalanceByUser[primaryPassengerId] ?? 0;
    passengerTransactions =
        walletTransactionsByUser[primaryPassengerId] ?? <WalletTransaction>[];
    earnerWalletBalance = walletBalanceByUser[primaryEarnerId] ?? 0;
    earnerTransactions =
        walletTransactionsByUser[primaryEarnerId] ?? <WalletTransaction>[];
    ownerWalletBalance = walletBalanceByUser[primaryOwnerId] ?? 0;
    ownerTransactions =
        walletTransactionsByUser[primaryOwnerId] ?? <WalletTransaction>[];

    passengerNotifications =
        notificationsByUser[primaryPassengerId] ?? <NotificationItem>[];
    earnerNotifications =
        notificationsByUser[primaryEarnerId] ?? <NotificationItem>[];

    passengerSettings =
        settingsByUser[primaryPassengerId] ?? _defaultSettings();
    earnerSettings = settingsByUser[primaryEarnerId] ?? _defaultSettings();
  }

  /// Swaps the signed-in slices to [account]'s linked profiles, along with the
  /// wallet, notifications and settings those screens read.
  void activateAccount(Account account) {
    activeAccount = account;

    final passengerProfile =
        account.passengerId == null ? null : passengers[account.passengerId];
    if (passengerProfile != null) {
      passenger = passengerProfile;
      passengerWalletBalance = walletBalanceByUser[passengerProfile.id] ?? 0;
      passengerTransactions = walletTransactionsByUser[passengerProfile.id] ??
          <WalletTransaction>[];
      passengerNotifications =
          notificationsByUser[passengerProfile.id] ?? <NotificationItem>[];
      passengerSettings =
          settingsByUser[passengerProfile.id] ?? _defaultSettings();
    } else {
      passenger = _guestPassenger(
          id: account.id,
          name: account.name,
          phone: account.phone,
          email: account.email);
      passengerWalletBalance = 0;
      passengerTransactions = <WalletTransaction>[];
      passengerNotifications = <NotificationItem>[];
      passengerSettings = _defaultSettings();
    }

    final earnerProfile =
        account.riderId == null ? null : earners[account.riderId];
    if (earnerProfile != null) {
      earner = earnerProfile;
      earnerWalletBalance = walletBalanceByUser[earnerProfile.id] ?? 0;
      earnerTransactions =
          walletTransactionsByUser[earnerProfile.id] ?? <WalletTransaction>[];
      earnerNotifications =
          notificationsByUser[earnerProfile.id] ?? <NotificationItem>[];
      earnerSettings = settingsByUser[earnerProfile.id] ?? _defaultSettings();
    } else {
      earner = _guestEarner(
          id: account.id,
          name: account.name,
          phone: account.phone,
          email: account.email);
      earnerWalletBalance = 0;
      earnerTransactions = <WalletTransaction>[];
      earnerNotifications = <NotificationItem>[];
      earnerSettings = _defaultSettings();
    }

    final ownerProfile =
        account.ownerId == null ? null : owners[account.ownerId];
    if (ownerProfile != null) {
      vehicleOwner = ownerProfile;
      ownerWalletBalance = walletBalanceByUser[ownerProfile.id] ?? 0;
      ownerTransactions =
          walletTransactionsByUser[ownerProfile.id] ?? <WalletTransaction>[];
    } else {
      vehicleOwner = _guestOwner(
          id: account.id,
          name: account.name,
          phone: account.phone,
          email: account.email);
      ownerWalletBalance = 0;
      ownerTransactions = <WalletTransaction>[];
    }
  }

  /// The demo account belonging to [authUserId], or one whose phone or email
  /// matches. Used to bridge a demo session onto the seeded business data.
  ///
  /// A hosted Supabase session must pass [allowContactMatch] = false: matching
  /// a Google user to a seeded row by phone or email is how one person's
  /// dashboard could open under another person's identity.
  Account? findAccountForIdentity({
    required String authUserId,
    String? phone,
    String? email,
    bool allowContactMatch = true,
  }) {
    for (final account in accounts) {
      if (account.authUserId == authUserId) return account;
    }
    if (!allowContactMatch) return null;

    final phoneDigits = phone == null ? '' : _phoneDigits(phone);
    if (phoneDigits.isNotEmpty) {
      for (final account in accounts) {
        if (_phoneDigits(account.phone) == phoneDigits) return account;
      }
    }

    final needle = email?.trim().toLowerCase();
    if (needle != null && needle.isNotEmpty) {
      for (final account in accounts) {
        if (account.email.trim().toLowerCase() == needle) return account;
      }
    }
    return null;
  }

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'\D'), '');

  /// Adds a brand-new signed-in account with a fresh passenger profile and an
  /// empty wallet. Returns null when the phone or email is already taken.
  Account? registerAccount({
    required String name,
    required String phone,
    String email = '',
    String? authUserId,
  }) {
    final phoneNeedle = phone.trim().toLowerCase();
    final emailNeedle = email.trim().toLowerCase();
    final taken = accounts.any((a) =>
        (phoneNeedle.isNotEmpty && a.phone.trim().toLowerCase() == phoneNeedle) ||
        (emailNeedle.isNotEmpty && a.email.trim().toLowerCase() == emailNeedle));
    if (taken) return null;

    final passengerId = _nextId('P', passengers.keys);
    passengers[passengerId] = PassengerProfile(
      id: passengerId,
      name: name,
      firstName: _firstName(name),
      initials: _initials(name),
      phone: phone,
      email: email,
      rating: 0,
      totalRides: 0,
      memberSince: DateTime.now().year,
      verified: false,
    );
    walletBalanceByUser[passengerId] = 0;
    walletTransactionsByUser[passengerId] = <WalletTransaction>[];
    notificationsByUser[passengerId] = [
      NotificationItem(
        id: 'welcome-$passengerId',
        type: 'system',
        title: 'Welcome to SurGo',
        body:
            'Your account is ready. Book a ride, rent a vehicle, or post an errand.',
        time: 'Just now',
        read: false,
      ),
    ];

    final account = Account(
      id: _nextId('ACC', accounts.map((a) => a.id)),
      name: name,
      phone: phone,
      email: email,
      authUserId: authUserId,
      passengerId: passengerId,
      approvedCapabilities: const {CapabilityType.passenger},
      eligibleCapabilities: const {
        CapabilityType.earner,
        CapabilityType.rider,
        CapabilityType.vehicleOwner,
      },
    );
    accounts = [...accounts, account];
    return account;
  }

  AccountSettingsData _defaultSettings() => AccountSettingsData(
        pushNotifications: true,
        lowDataMode: false,
        language: 'English',
      );

  PassengerProfile _guestPassenger(
          {String id = '',
          String name = '',
          String phone = '',
          String email = ''}) =>
      PassengerProfile(
        id: id,
        name: name,
        firstName: _firstName(name),
        initials: _initials(name),
        phone: phone,
        email: email,
        rating: 0,
        totalRides: 0,
        memberSince: DateTime.now().year,
        verified: false,
      );

  EarnerProfile _guestEarner(
          {String id = '',
          String name = '',
          String phone = '',
          String email = ''}) =>
      EarnerProfile(
        id: id,
        name: name,
        initials: _initials(name),
        phone: phone,
        email: email,
        rating: 0,
        totalTrips: 0,
        memberSince: DateTime.now().year,
        verified: false,
        vehicleType: '',
        vehicleModel: '',
        vehiclePlate: '',
        documentsStatus: 'Pending',
        capabilities: const {},
      );

  VehicleOwnerProfile _guestOwner(
          {String id = '',
          String name = '',
          String phone = '',
          String email = ''}) =>
      VehicleOwnerProfile(
        id: id,
        name: name,
        initials: _initials(name),
        phone: phone,
        email: email,
        rating: 0,
        totalVehicles: 0,
        totalRentals: 0,
        memberSince: DateTime.now().year,
        verified: false,
      );

  String _firstName(String name) {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    return parts.isEmpty ? name : parts.first;
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  /// Next id in a `PREFIXnnn` family, one past the highest number in use.
  String _nextId(String prefix, Iterable<String> ids) {
    var max = 0;
    for (final id in ids) {
      final n = int.tryParse(id.replaceAll(RegExp(r'\D'), '')) ?? 0;
      if (n > max) max = n;
    }
    return '$prefix${(max + 1).toString().padLeft(3, '0')}';
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
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) e
    ];
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
