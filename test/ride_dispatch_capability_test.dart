import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/booking_screen.dart';
import 'package:surgo/screens/live_trip_screen.dart';
import 'package:surgo/services/geoapify_service.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';
import 'package:surgo/widgets/common.dart';
import 'package:surgo/widgets/surgo_map.dart';

/// A host-backed auth provider with no network. It reports `isMock = false`,
/// which is what puts [AppState] on the hosted-identity path without needing a
/// real Supabase session.
class _HostedAuth implements AuthRepository {
  @override
  bool get isMock => false;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<AuthUser?> restoreSession() async => null;

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
  }) async => throw UnimplementedError();

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async => throw UnimplementedError();

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {}

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async =>
      throw UnimplementedError();

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {}

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

/// A write-capable backend whose only job is to record the RPC name and return
/// a row the ride mapper accepts.
class _RideBackend implements SurgoBackend, SurgoWriteBackend {
  final List<String> rpcCalls = [];
  final List<Map<String, dynamic>> rpcParams = [];
  bool echoRequest = false;

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
  }) async => const [];

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async => null;

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) async {
    rpcCalls.add(function);
    rpcParams.add(Map.of(params));
    return <String, dynamic>{
      'id': 'ride-hosted-1',
      'passenger_id': 'p1',
      'rider_id': null,
      'service_area_id': 'sa1',
      'status': 'searching',
      'pickup_address': 'Purok 3, Barangay Poblacion',
      'dropoff_address': 'SM Terminal, Downtown',
      'distance_km': 3.2,
      'eta_minutes': 8,
      'fare_centavos': 18000,
      'platform_fee_centavos': 1800,
      'payment_method': 'cash',
      if (echoRequest) ...{
        'pickup_address': params['p_pickup_address'],
        'pickup_latitude': params['p_pickup_latitude'],
        'pickup_longitude': params['p_pickup_longitude'],
        'dropoff_address': params['p_dropoff_address'],
        'dropoff_latitude': params['p_dropoff_latitude'],
        'dropoff_longitude': params['p_dropoff_longitude'],
        'distance_km': params['p_distance_km'],
        'eta_minutes': params['p_eta_minutes'],
        'fare_centavos': params['p_fare_centavos'],
        'platform_fee_centavos': params['p_platform_fee_centavos'],
      },
    };
  }

  @override
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  late List<RideRequestItem> savedRequests;

  setUpAll(() async {
    await state.init();
  });

  setUp(() {
    savedRequests = List.of(db.rideRequests);
    state.myRideRequest = null;
    state.rideProposal = null;
  });

  tearDown(() {
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    state.bookingRouting.sync(start: null, end: null, enabled: false);
    state.rideRouting.sync(start: null, end: null, enabled: false);
    state.activeRide = null;
    state.myRideRequest = null;
    state.rideProposal = null;
    db.rideRequests
      ..clear()
      ..addAll(savedRequests);
  });

  test(
    'a hosted session on the seeded repositories keeps the local ride flow',
    () async {
      state.configureAuth(_HostedAuth());
      state.configureRepositories(RepositoryRegistry.mock());

      expect(
        state.usesHostedIdentity,
        isTrue,
        reason: 'the auth provider still says a real account is signed in',
      );
      expect(state.repositories.isSupabaseBacked, isFalse);
      expect(
        state.usesHostedRideDispatch,
        isFalse,
        reason: 'seeded repositories cannot perform hosted dispatch',
      );

      final before = db.rideRequests.length;
      final request = state.createRideRequest();

      expect(db.rideRequests.length, before + 1);
      expect(state.myRideRequest, same(request));

      // The hosted path would have refused: this is the failure the screen must
      // not route into while the build is still reading the seed.
      await expectLater(
        state.createHostedRideRequest(),
        throwsA(isA<RepositoryFailure>()),
      );
    },
  );

  test(
    'a hosted session on the Supabase repositories uses hosted dispatch',
    () async {
      final backend = _RideBackend();
      state.configureAuth(_HostedAuth());
      state.configureRepositories(RepositoryRegistry.supabase(backend));

      expect(state.usesHostedIdentity, isTrue);
      expect(state.repositories.isSupabaseBacked, isTrue);
      expect(state.usesHostedRideDispatch, isTrue);

      final request = await state.createHostedRideRequest();

      expect(backend.rpcCalls, contains('create_ride_request'));
      expect(state.myRideRequest, same(request));
      expect(request.id, 'ride-hosted-1');
    },
  );

  test(
    'hosted request carries road stats and keeps its route snapshot',
    () async {
      final pickupLabel = state.pickupLabel;
      final destinationLabel = state.destinationLabel;
      final pickupPoint = state.bookingPickup;
      final destinationPoint = state.bookingDestination;
      addTearDown(() {
        state.configureAuth(MockAuthRepository());
        state.configureRepositories(RepositoryRegistry.mock());
        state.setPickup(pickupLabel, coordinates: pickupPoint);
        state.setDestination(destinationLabel, coordinates: destinationPoint);
      });
      state.configureAuth(MockAuthRepository());
      state.configureRepositories(RepositoryRegistry.mock());
      const start = MapPoint(9.075, 126.175);
      const end = MapPoint(9.085, 126.185);
      state.setPickup('Test pickup', coordinates: start);
      state.setDestination('Test destination', coordinates: end);
      final backend = _RideBackend()..echoRequest = true;
      state.configureAuth(_HostedAuth());
      state.configureRepositories(RepositoryRegistry.supabase(backend));
      const route = GeoRoute(
        points: [start, MapPoint(9.077, 126.181), end],
        distanceMeters: 4250,
        durationSeconds: 601,
      );
      state.bookingRouting.sync(
        start: start,
        end: end,
        enabled: true,
        seed: route,
        retry: true,
      );
      final providerFare = state.bookingPrice.providerFare;

      final request = await state.createHostedRideRequest();

      final params = backend.rpcParams.single;
      expect(params['p_distance_km'], 4.25);
      expect(params['p_eta_minutes'], 11);
      expect(params['p_fare_centavos'], providerFare);
      expect(params['p_platform_fee_centavos'], 850);
      expect(params['p_pickup_latitude'], start.latitude);
      expect(params['p_dropoff_longitude'], end.longitude);
      expect(request.distanceKm, 4.25);
      expect(request.etaMinutes, 11);
      expect(state.rideRouting.route, same(route));

      const nextEnd = MapPoint(9.09, 126.19);
      state.bookingRouting.sync(
        start: start,
        end: nextEnd,
        enabled: true,
        seed: const GeoRoute(
          points: [start, nextEnd],
          distanceMeters: 5000,
          durationSeconds: 900,
        ),
      );
      state.setDestination('Next draft destination', coordinates: nextEnd);
      state.syncRideRoute(request);

      expect(state.rideRouting.route, same(route));
      expect(request.distanceKm, 4.25);
      expect(request.etaMinutes, 11);
    },
  );

  testWidgets(
    'hosted live trip without a session never claims active polling',
    (tester) async {
      state.configureAuth(_HostedAuth());
      state.configureRepositories(RepositoryRegistry.supabase(_RideBackend()));
      expect(state.identity, isNull);
      final request = await state.createHostedRideRequest();
      request.riderId = 'rider-1';
      request.status = RideStatus.accepted;
      state.activeRide = request;

      await tester.pumpWidget(const MaterialApp(home: LiveTripScreen()));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Hosted tracking unavailable'), findsOneWidget);
      expect(find.textContaining('checking every 15 seconds'), findsNothing);
      final map = tester.widget<SurgoMap>(find.byType(SurgoMap));
      expect(map.markers.where((marker) => marker.id == 'driver'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Find a Ride on a hosted session with seeded data creates a local request',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      state.configureAuth(_HostedAuth());
      state.configureRepositories(RepositoryRegistry.mock());

      await tester.pumpWidget(
        MaterialApp(
          home: const BookingScreen(),
          routes: {'/matching': (_) => const Scaffold(body: Text('matching'))},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.widgetWithText(SbPrimaryButton, 'Find a Ride'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        state.myRideRequest,
        isNotNull,
        reason: 'the tap must create the request, not report it as unsent',
      );
      expect(
        find.text('matching'),
        findsOneWidget,
        reason: 'the flow continues to the matching screen',
      );
    },
  );
}
