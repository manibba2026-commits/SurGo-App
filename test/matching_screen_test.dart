import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/matching_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';

// Hosted capability with an entirely in-memory backend; no session or network.
class _HostedAuth extends MockAuthRepository {
  @override
  bool get isMock => false;
}

class _Backend implements SurgoBackend, SurgoWriteBackend {
  final calls = <String>[];
  final search = Completer<dynamic>();
  final cancel = Completer<dynamic>();

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) {
    calls.add(function);
    return switch (function) {
      'find_available_riders' => search.future,
      'cancel_ride_request' => cancel.future,
      _ => throw StateError('Unexpected RPC: $function'),
    };
  }

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
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async => throw StateError('Unexpected upload');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;
  final db = DbService.instance;

  setUpAll(() async {
    state.configureAuth(MockAuthRepository());
    await state.init();
  });

  setUp(() {
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    state.myRideRequest = null;
    state.rideProposal = null;
    state.activeRide = null;
    state.activeRideBreakdown = null;
    state.passengerRideFailure = null;
    state.passengerRideLoading = false;
  });

  tearDown(() {
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    state.rideRouting.sync(start: null, end: null, enabled: false);
    state.myRideRequest = null;
    state.rideProposal = null;
    state.activeRide = null;
    state.activeRideBreakdown = null;
    state.passengerRideFailure = null;
    state.passengerRideLoading = false;
  });

  testWidgets('explicit Home preserves a pending request and its rider', (
    tester,
  ) async {
    final request = _request(RideStatus.awaitingAcceptance);
    state.myRideRequest = request;
    await _mount(tester);

    await _tap(tester, 'Back to Home');
    expect(find.text('home route'), findsOneWidget);
    expect(state.myRideRequest, same(request));
    expect(request.status, RideStatus.awaitingAcceptance);
    expect(request.riderId, 'assigned-rider');
    expect(state.activeRide, isNull);
    await _dispose(tester);
  });

  for (final status in [
    RideStatus.accepted,
    RideStatus.headingToPickup,
    RideStatus.arrived,
    RideStatus.inProgress,
  ]) {
    testWidgets('$status opens tracking only on View live trip', (
      tester,
    ) async {
      final request = _request(status, riderName: 'Observed Rider');
      state.myRideRequest = request;
      state.activeRide = request;
      await _mount(tester);

      expect(find.text(status.label), findsWidgets);
      expect(find.text('Observed Rider'), findsOneWidget);
      expect(find.text('Select Rider'), findsNothing);
      expect(state.rideProposal, isNull);
      expect(find.text('live trip route'), findsNothing);
      await _tap(tester, 'View live trip');
      expect(find.text('live trip route'), findsOneWidget);
      expect(state.activeRide, same(request));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  }

  testWidgets(
    'completed request shows receipt details and the actual /rate route',
    (tester) async {
      final request = _request(
        RideStatus.completed,
        riderName: 'Receipt Rider',
      );
      state.myRideRequest = request;
      await _mount(tester);

      final price = state.priceFor(request);
      expect(find.text('Completed'), findsWidgets);
      expect(find.text('Platform fee'), findsOneWidget);
      expect(find.text('Customer total'), findsOneWidget);
      expect(find.text(price.providerFareLabel), findsOneWidget);
      expect(find.text(price.platformFeeLabel), findsOneWidget);
      expect(find.text(price.customerTotalLabel), findsOneWidget);
      expect(find.text('Cancel request'), findsNothing);
      await _tap(tester, 'View receipt');
      expect(find.text('receipt route'), findsOneWidget);
      expect(state.myRideRequest, same(request));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );

  testWidgets(
    'cancelled request shows its status, never a search or live trip',
    (tester) async {
      state.myRideRequest = _request(RideStatus.cancelled);
      await _mount(tester);
      expect(find.text('Cancelled'), findsWidgets);
      expect(find.text('Finding you a rider…'), findsNothing);
      expect(find.text('Select Rider'), findsNothing);
      expect(find.text('View live trip'), findsNothing);
      expect(find.text('Cancel request'), findsNothing);
      await _tap(tester, 'Back to Home');
      expect(state.myRideRequest?.status, RideStatus.cancelled);
      await _dispose(tester);
    },
  );

  testWidgets('hosted restored request never names a seeded rider', (
    tester,
  ) async {
    final backend = _hosted(state);
    state.myRideRequest = _request(RideStatus.awaitingAcceptance)
      ..riderId = db.mapRiders.first.id;
    await _mount(tester);
    expect(find.text(db.mapRiders.first.name), findsNothing);
    expect(find.text('Not available'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(
      backend.calls,
      isEmpty,
      reason: 'pending restoration never dispatches',
    );
    await _tap(tester, 'Back to Home');
    expect(
      backend.calls,
      isEmpty,
      reason: 'leaving never cancels hosted requests',
    );
    expect(state.myRideRequest?.status, RideStatus.awaitingAcceptance);
    await _dispose(tester);
  });

  testWidgets(
    'hosted cancellation is latched and failure keeps the request live',
    (tester) async {
      final backend = _hosted(state);
      final request = _request(
        RideStatus.awaitingAcceptance,
        riderName: 'Live Rider',
      );
      state.myRideRequest = request;
      await _mount(tester);
      await tester.scrollUntilVisible(
        find.text('Cancel request'),
        140,
        scrollable: _scrollable(),
      );
      await tester.pump();
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Cancel request'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(backend.calls, ['cancel_ride_request']);
      expect(state.myRideRequest, same(request));
      expect(find.text('home route'), findsNothing);

      backend.cancel.completeError(RepositoryFailure.offline());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.myRideRequest, same(request));
      expect(request.status, RideStatus.awaitingAcceptance);
      expect(find.byType(MatchingScreen), findsOneWidget);
      expect(find.text('Cancellation failed'), findsWidgets);
      expect(find.text(RepositoryFailure.offline().message), findsWidgets);
      expect(find.text('home route'), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );

  testWidgets('a declined offer resumes searching without reopening', (
    tester,
  ) async {
    final backend = _hosted(state);
    state.myRideRequest = _request(RideStatus.awaitingAcceptance);
    await _mount(tester);
    expect(backend.calls, isEmpty);
    state.myRideRequest = _request(RideStatus.searching);
    state.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(backend.calls, ['find_available_riders']);
    backend.search.complete([]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('No riders nearby'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  testWidgets('dispatch rechecks status after its search animation delay', (
    tester,
  ) async {
    final backend = _hosted(state);
    final request = _request(RideStatus.searching);
    state.myRideRequest = request;
    await _mount(tester);
    request.status = RideStatus.awaitingAcceptance;
    state.riderAccepts(request);
    await tester.pump(const Duration(seconds: 1));
    expect(backend.calls, isEmpty);
    expect(find.text('Select Rider'), findsNothing);
    expect(find.text(RideStatus.accepted.label), findsWidgets);
    await _dispose(tester);
  });

  testWidgets(
    'a late hosted discovery cannot replace accepted request details',
    (tester) async {
      final backend = _hosted(state);
      final request = _request(RideStatus.searching);
      state.myRideRequest = request;
      await _mount(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(backend.calls, ['find_available_riders']);
      request.status = RideStatus.awaitingAcceptance;
      state.riderAccepts(request);
      backend.search.complete([
        {
          'profile_id': 'late-rider',
          'full_name': 'Late Rider',
          'rating': 4.8,
          'total_trips': 12,
          'latitude': 9.0785,
          'longitude': 126.2025,
          'is_simulated': true,
          'distance_km': 1.2,
        },
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.myRideRequest, same(request));
      expect(state.rideProposal, isNull);
      expect(find.text('Late Rider'), findsNothing);
      expect(find.text('Select Rider'), findsNothing);
      expect(find.text(RideStatus.accepted.label), findsWidgets);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );
}

_Backend _hosted(AppState state) {
  final backend = _Backend();
  state.configureAuth(_HostedAuth());
  state.configureRepositories(RepositoryRegistry.supabase(backend));
  return backend;
}

RideRequestItem _request(RideStatus status, {String? riderName}) =>
    RideRequestItem(
      id: 'matching-request',
      riderId: status == RideStatus.searching ? null : 'assigned-rider',
      riderName: riderName,
      passengerId: DbService.instance.passenger.id,
      passengerName: 'Test Passenger',
      passengerInitials: 'TP',
      passengerRating: 4.5,
      pickupBarangay: 'Tandag',
      pickupPurok: 'Purok 1',
      pickup: 'SM Terminal with a long pickup address',
      dropoffBarangay: 'Tandag',
      dropoffPurok: 'Purok 2',
      dropoff: 'City Hall with a long destination address',
      distanceKm: 3.2,
      etaMinutes: 8,
      fare: 18000,
      platformFeeCentavos: 640,
      paymentMethod: 'Cash',
      note: '',
      requestedAt: 'Just now',
      status: status,
    );

Future<void> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: const MatchingScreen(),
      routes: {
        '/home': (_) => const Scaffold(body: Text('home route')),
        '/livetrip': (_) => const Scaffold(body: Text('live trip route')),
        '/rate': (_) => const Scaffold(body: Text('receipt route')),
      },
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Finder _scrollable() => find
    .descendant(
      of: find.byType(MatchingScreen),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(
    find.text(label),
    140,
    scrollable: _scrollable(),
  );
  await tester.pump();
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _dispose(WidgetTester tester) async {
  final messenger = tester.state<ScaffoldMessengerState>(
    find.byType(ScaffoldMessenger),
  );
  messenger.clearSnackBars();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}
