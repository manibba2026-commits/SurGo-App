import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/rider_profile_screen.dart';
import 'package:surgo/screens/rider_trips_screen.dart';
import 'package:surgo/state/app_state.dart';

/// Proof that the earner's Trips and Profile tabs wear the signed-in account
/// rather than the seeded rider: the trips list is the rows the database
/// assigned to this rider, and the profile header plus capability list come
/// from `profiles` and `provider_profiles` instead of the seed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;
  const userId = '9c4a1f2e-0000-4000-8000-0000000000cc';

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

  /// A Supabase build is whichever provider is installed, not just an identity
  /// object, so a hosted session is established through a non-mock provider.
  Future<void> signInAs(String id) async {
    addTearDown(() async => state.logout());
    state.configureAuth(_HostedAuth(userId: id));
    final failure = await state.signInWithGoogle();
    expect(failure, isNull, reason: 'the stub provider always signs in');
    expect(state.usesHostedIdentity, isTrue);
    expect(state.isSignedIn, isTrue);
  }

  setUpAll(() async => db.load());

  /// The seed person the demo trip list belongs to. Captured before a hosted
  /// sign-in isolates the seed, because that isolation empties the list.
  late String seedTripPassenger;

  setUp(() {
    seedTripPassenger = db.riderTrips.first.passengerName;
  });

  tearDown(() async {
    await state.logout();
    state.configureAuth(MockAuthRepository());
    await use(RepositoryRegistry.mock(db));
  });

  Future<void> open(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: screen));
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  Map<String, dynamic> rideRow({
    required String id,
    required String status,
    required String pickup,
    required String dropoff,
    required int fare,
  }) =>
      {
        'id': id,
        'passenger_id': 'passenger-elsewhere',
        'rider_id': userId,
        'service_area_id': 'sa-tandag-city',
        'status': status,
        'pickup_address': pickup,
        'dropoff_address': dropoff,
        'distance_km': 4.2,
        'fare_centavos': fare,
        'requested_at': '2026-11-09T01:00:00.000Z',
        'completed_at':
            status == 'completed' ? '2026-11-09T01:30:00.000Z' : null,
      };

  group('hosted rider trips', () {
    testWidgets('lists the rides assigned to this rider and not the seed',
        (tester) async {
      await signInAs(userId);
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'ride_requests': [
          rideRow(
            id: 'ride-a',
            status: 'completed',
            pickup: 'Mabua',
            dropoff: 'Public Market',
            fare: 5500,
          ),
          rideRow(
            id: 'ride-b',
            status: 'in_progress',
            pickup: 'Awasian',
            dropoff: 'City Hall',
            fare: 6000,
          ),
        ],
      })));

      await open(tester, const RiderTripsScreen());

      expect(find.text('Mabua → Public Market'), findsOneWidget);
      expect(find.text('Awasian → City Hall'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget,
          reason: 'an assigned trip that has not finished is labelled as live');
      expect(find.text(seedTripPassenger), findsNothing,
          reason: 'the seeded trip list belongs to the demo account');
    });

    testWidgets('an account with no assigned rides says so', (tester) async {
      await signInAs(userId);
      await use(RepositoryRegistry.supabase(_FixedBackend()));

      await open(tester, const RiderTripsScreen());

      expect(find.text('No trips yet'), findsOneWidget);
      expect(find.text(seedTripPassenger), findsNothing);
    });

    testWidgets('an unreachable read fails visibly instead of the seed',
        (tester) async {
      await signInAs(userId);
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester, const RiderTripsScreen());

      expect(find.text('The data service is unavailable right now.'),
          findsOneWidget);
      expect(find.text(seedTripPassenger), findsNothing);
    });
  });

  group('hosted earner profile', () {
    testWidgets('names the signed-in account and hides the capability switches',
        (tester) async {
      await signInAs(userId);
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'profiles': [
          {
            'id': userId,
            'full_name': 'Asha Bell',
            'account_status': 'active',
            'rating': 4.8,
            'total_rides': 12,
            'created_at': '2024-03-11T01:02:03.000Z',
          },
        ],
        'provider_profiles': [
          {
            'profile_id': userId,
            'provider_type': 'earner',
            'capabilities': ['rides', 'errands'],
            'is_available': true,
            'rating': 4.8,
            'total_trips': 12,
          },
        ],
      })));

      await open(tester, const EarnerProfileScreen(embedded: false));

      expect(find.text('Asha Bell'), findsOneWidget);
      expect(find.text(db.earner.name), findsNothing,
          reason: 'a hosted header must not greet the seeded rider');
      expect(find.text('What I offer'), findsOneWidget);
      expect(find.text('2 ON'), findsOneWidget);
      expect(find.byType(Switch), findsNothing,
          reason: 'nothing in the client can write capabilities, so a switch '
              'would only move a seed value');
    });
  });
}

/// A host-backed provider with no network. `isMock = false` is what puts
/// [AppState] on the hosted path, so the screens take their signed-in branches.
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

/// Answers each table with fixed rows.
class _FixedBackend implements SurgoBackend {
  _FixedBackend({this.rowsByTable = const {}});

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
    final found = rowsByTable[table] ?? const [];
    return limit == null ? found : found.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    final found = rowsByTable[table] ?? const [];
    if (found.isEmpty) return null;
    for (final row in found) {
      if (eq.entries.every((where) => row[where.key] == where.value)) {
        return row;
      }
    }
    return found.first;
  }
}
