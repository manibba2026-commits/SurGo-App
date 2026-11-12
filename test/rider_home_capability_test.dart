import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/rider_home_screen.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/domain_cache.dart';
import 'package:surgo/widgets/surfaces.dart';

/// Proof that the rider home routes by the data layer, not by the auth
/// provider alone.
///
/// The default presentation build has a hosted identity and the seeded
/// repositories. Its rider home must keep using the in-memory presence, stats,
/// incoming requests and Pasuyo feed. A build with the Supabase repositories
/// must keep reading the rider workspace from those repositories.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;
  const hostedUserId = '9c4a1f2e-0000-4000-8000-0000000000dd';

  Future<void> settle() async {
    for (var turn = 0; turn < 12; turn++) {
      await Future<void>.value();
    }
  }

  Future<void> use(RepositoryRegistry registry) async {
    state.configureRepositories(registry);
    state.cache.restart();
    await settle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: RiderHomeScreen(embedded: false)),
    );
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  setUpAll(() async => db.load());

  tearDown(() async {
    await state.logout();
    state.configureAuth(MockAuthRepository());
    await use(RepositoryRegistry.mock(db));
  });

  // This test must stay first: it checks that the local branches leave the
  // repository-backed rider slots unread, and the shared cache only has that
  // clean slate before another rider-home test has populated it.
  testWidgets(
      'a hosted identity on the seeded repositories keeps the local rider home',
      (tester) async {
    state.configureAuth(_HostedAuth(userId: hostedUserId));
    state.configureRepositories(RepositoryRegistry.mock(db));
    state.currentAccount =
        db.accounts.firstWhere((account) => account.id == 'ACC001');
    state.identity = SurgoIdentity(
      userId: hostedUserId,
      capabilities: const {CapabilityType.rider},
      eligibleCapabilities: const {},
      roles: const {'rider'},
      providers: const {'phone'},
    );
    state.riderOnline = true;
    state.activeRide = null;
    state.activePasuyoTask = null;

    expect(state.usesHostedIdentity, isTrue,
        reason: 'the auth provider is still hosted');
    expect(state.repositories.isSupabaseBacked, isFalse,
        reason: 'the data layer is still the seeded registry');
    expect(state.usesHostedRideDispatch, isFalse,
        reason: 'seeded repositories cannot perform hosted dispatch');

    await open(tester);

    expect(find.text(Money.format(db.earningsToday)), findsOneWidget,
        reason: 'the earnings card reads the seed, not a hosted ledger');
    expect(find.text(Money.format(db.earningsWeek)), findsOneWidget,
        reason: 'the week card reads the seed too');
    final completedTrips =
        db.riderTrips.where((trip) => trip.status == 'Completed').length;
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Trips'),
          matching: find.byType(SbTintedCard),
        ),
        matching: find.text('$completedTrips'),
      ),
      findsOneWidget,
      reason: 'the trips card counts the seeded trip list',
    );

    expect(find.text("You're Online"), findsOneWidget);
    expect(find.text('Visible for new ride requests'), findsOneWidget);
    expect(find.text('${state.pendingRequests.length} NEW'), findsOneWidget);
    expect(
      find.text('${state.pendingRequests.first.passengerName} wants a ride'),
      findsOneWidget,
      reason: 'the incoming list is the seeded request inbox',
    );
    expect(find.text('${state.nearbyPasuyoTasks.length} OPEN'), findsOneWidget);
    expect(find.text('Buy 2 Chickenjoy, 1 Coca-Cola'), findsOneWidget,
        reason: 'the Pasuyo feed is the seeded open-errand list');

    for (final slot in const [
      DomainSlot.riderPresence,
      DomainSlot.riderIncomingRides,
      DomainSlot.earnerWalletEntries,
      DomainSlot.providerErrands,
      DomainSlot.openErrands,
    ]) {
      expect(state.cache.stateOf<Object?>(slot).isIdle, isTrue,
          reason: '$slot must not be read when the local branch owns the '
              'rider workspace');
    }

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(find.text("You're Offline"), findsOneWidget,
        reason: 'the seeded presence toggle stays local');
    expect(find.text('Online status not changed'), findsNothing,
        reason: 'a local toggle must not call the unsupported hosted write');
  });

  testWidgets(
      'a hosted identity on the Supabase repositories keeps the hosted '
      'rider home', (tester) async {
    state.configureAuth(_HostedAuth(userId: hostedUserId));
    final failure = await state.signInWithGoogle();
    expect(failure, isNull, reason: 'the stub provider always signs in');
    expect(state.isSignedIn, isTrue);
    expect(state.usesHostedIdentity, isTrue);

    final now = DateTime.now();
    final stamp = now.toUtc().toIso8601String();

    await use(RepositoryRegistry.supabase(_RowsBackend({
      'profiles': [
        {
          'id': hostedUserId,
          'full_name': 'Asha Bell',
          'account_status': 'active',
          'rating': 4.8,
          'created_at': '2024-03-11T01:02:03.000Z',
        },
      ],
      'rider_presence': [
        {
          'profile_id': hostedUserId,
          'is_online': true,
          'is_available': true,
          'is_simulated': false,
          'source': 'app',
          'updated_at': stamp,
        },
      ],
      'ride_requests': [
        {
          'id': 'ride-pending',
          'passenger_id': 'passenger-other',
          'rider_id': hostedUserId,
          'service_area_id': 'sa-tandag-city',
          'status': 'awaiting_acceptance',
          'pickup_address': 'Mabua',
          'dropoff_address': 'Public Market',
          'distance_km': 3.1,
          'eta_minutes': 9,
          'fare_centavos': 5500,
          'payment_method': 'cash',
          'requested_at': '2026-11-09T01:00:00.000Z',
          'passenger': {'full_name': 'Hosted Passenger'},
        },
        {
          'id': 'ride-done',
          'passenger_id': 'passenger-other',
          'rider_id': hostedUserId,
          'service_area_id': 'sa-tandag-city',
          'status': 'completed',
          'pickup_address': 'Awasian',
          'dropoff_address': 'City Hall',
          'distance_km': 4.2,
          'fare_centavos': 6000,
          'payment_method': 'cash',
          'requested_at': '2026-11-09T02:00:00.000Z',
          'completed_at': '2026-11-09T02:30:00.000Z',
        },
      ],
      'wallet_accounts': [
        {
          'id': 'wallet-earner',
          'profile_id': hostedUserId,
          'account_type': 'earner',
          'currency': 'PHP',
          'balance_centavos': 100000,
          'is_active': true,
        },
      ],
      'wallet_transactions': [
        {
          'id': 'tx-today',
          'wallet_account_id': 'wallet-earner',
          'transaction_type': 'earning',
          'direction': 'credit',
          'amount_centavos': 12345,
          'created_at': stamp,
        },
      ],
      'service_areas': [
        {
          'id': 'sa-tandag-city',
          'name': 'Tandag City',
          'city': 'Tandag City',
          'province': 'Surigao del Sur',
          'is_active': true,
        },
      ],
      'service_requests': [
        {
          'id': 'errand-open',
          'customer_id': 'customer-other',
          'provider_id': null,
          'service_area_id': 'sa-tandag-city',
          'category': 'groceries',
          'status': 'available',
          'title': 'Hosted errand',
          'pickup_address': 'Jollibee, Telaje',
          'dropoff_address': 'Centrio Dorm, Mabua',
          'budget_centavos': 18000,
          'payment_method': 'cash',
          'requested_at': stamp,
        },
      ],
    })));

    expect(state.repositories.isSupabaseBacked, isTrue);
    expect(state.usesHostedRideDispatch, isTrue);

    await open(tester);

    expect(find.text('Asha Bell'), findsOneWidget);
    expect(find.text("You're Online"), findsOneWidget);
    expect(find.text('Visible for new ride requests'), findsOneWidget);
    expect(find.text(Money.format(12345)), findsNWidgets(2),
        reason: 'both earnings cards read the hosted ledger');
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Trips'),
          matching: find.byType(SbTintedCard),
        ),
        matching: find.text('1'),
      ),
      findsOneWidget,
      reason: 'the hosted trips card counts the completed hosted ride',
    );
    expect(find.text('1 NEW'), findsOneWidget);
    expect(find.text('Hosted Passenger wants a ride'), findsOneWidget);
    expect(find.text('1 OPEN'), findsOneWidget);
    expect(find.text('Hosted errand'), findsOneWidget);

    expect(
        state.cache.stateOf<Object?>(DomainSlot.riderPresence).hasData, isTrue);
    expect(state.cache.stateOf<Object?>(DomainSlot.riderIncomingRides).hasData,
        isTrue);
    expect(state.cache.stateOf<Object?>(DomainSlot.earnerWalletEntries).hasData,
        isTrue);
    expect(
        state.cache.stateOf<Object?>(DomainSlot.openErrands).hasData, isTrue);
  });
}

/// A host-backed auth provider with no network. `isMock = false` is what puts
/// [AppState] on the hosted-identity path without a real Supabase session.
class _HostedAuth implements AuthRepository {
  _HostedAuth({required this.userId});

  final String userId;
  AuthUser? _user;

  AuthUser _currentUser() => AuthUser(
        id: userId,
        phone: '+639175000001',
        fullName: 'Hosted Tester',
        providers: const {'phone'},
      );

  @override
  bool get isMock => false;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<AuthUser?> restoreSession() async => _user;

  @override
  Future<bool> signInWithGoogle() async {
    _user = _currentUser();
    return true;
  }

  @override
  Future<bool> signInWithFacebook() async => false;

  @override
  Future<AuthUser> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      throw UnimplementedError();

  @override
  Future<AuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async =>
      throw UnimplementedError();

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async =>
      _user = _currentUser();

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async => SurgoIdentity(
        userId: user.id,
        phone: user.phone,
        fullName: user.fullName,
        capabilities: const {CapabilityType.rider},
        eligibleCapabilities: const {},
        roles: const {'rider'},
        providers: user.providers,
        profileExists: true,
      );

  @override
  Future<void> signOut() async {
    _user = null;
  }

  @override
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) async {}

  @override
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async =>
      _user = _currentUser();

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {
    _user = _currentUser();
  }

  @override
  Future<bool> linkGoogleIdentity() async => false;

  @override
  Future<void> requestPhoneLink(String phone) async {}

  @override
  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  }) async {}
}

/// Answers each table with fixed rows, applying the filters a repository asks
/// for so a provider read cannot see another role's rows.
class _RowsBackend implements SurgoBackend {
  _RowsBackend(this.rowsByTable);

  final Map<String, List<Map<String, dynamic>>> rowsByTable;

  @override
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async {
    var found = rowsByTable[table] ?? const <Map<String, dynamic>>[];
    found = [
      for (final row in found)
        if (eq.entries.every((where) => row[where.key] == where.value) &&
            whereIn.entries
                .every((where) => (where.value).contains(row[where.key])) &&
            whereNull.every((column) => row[column] == null))
          row,
    ];
    return limit == null ? found : found.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    for (final row in rowsByTable[table] ?? const []) {
      if (eq.entries.every((where) => row[where.key] == where.value)) {
        return row;
      }
    }
    return null;
  }
}
