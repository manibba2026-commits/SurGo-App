import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/screens/live_trip_screen.dart';
import 'package:surgo/screens/matching_screen.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';
import 'package:surgo/widgets/common.dart';

/// Pins the passenger-side trip screens to the ride state machine: Live Trip
/// must advance one legal step at a time and settle only from `inProgress`,
/// and the matching wait state must name the rider rather than an internal id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  late List<RideHistoryItem> savedHistory;
  late List<RiderTripItem> savedTrips;
  late int wallet;
  late int today;
  late int week;
  late int month;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    savedHistory = List.of(db.rideHistory);
    savedTrips = List.of(db.riderTrips);
    wallet = db.earnerWalletBalance;
    today = db.earningsToday;
    week = db.earningsWeek;
    month = db.earningsMonth;

    state.activeRide = null;
    state.activeRideBreakdown = null;
    state.myRideRequest = null;
    state.rideProposal = null;
    state.lastCompletedRide = null;
    state.lastCompletedRideDriver = null;
    state.lastRideBreakdown = null;
    PlatformLedger.instance.reset();
  });

  tearDown(() {
    state.activeRide = null;
    state.activeRideBreakdown = null;
    state.myRideRequest = null;
    state.rideProposal = null;
    state.lastCompletedRide = null;
    state.lastCompletedRideDriver = null;
    state.lastRideBreakdown = null;

    db.rideHistory
      ..clear()
      ..addAll(savedHistory);
    db.riderTrips
      ..clear()
      ..addAll(savedTrips);
    db.earnerWalletBalance = wallet;
    db.earningsToday = today;
    db.earningsWeek = week;
    db.earningsMonth = month;
    PlatformLedger.instance.reset();
  });

  testWidgets('live trip with nothing assigned shows the empty state',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LiveTripScreen()));

    expect(find.text('No active trip'), findsOneWidget);
  });

  testWidgets('live trip advances through the machine and settles once',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final request = _request()..status = RideStatus.accepted;
    state.activeRide = request;

    await tester.pumpWidget(MaterialApp(
      home: const LiveTripScreen(),
      routes: {'/rate': (_) => const Scaffold(body: Text('rate screen'))},
    ));

    await _tapPrimary(tester, 'Start heading to pickup');
    expect(request.status, RideStatus.headingToPickup);
    expect(db.earnerWalletBalance, wallet,
        reason: 'advancing before in-progress does not pay');

    await _tapPrimary(tester, "I've arrived at pickup");
    expect(request.status, RideStatus.arrived);

    await _tapPrimary(tester, 'Start the trip');
    expect(request.status, RideStatus.inProgress);
    expect(db.earnerWalletBalance, wallet,
        reason: 'starting the trip does not settle it');

    await _tapPrimary(tester, 'Complete trip');
    await tester.pump(const Duration(milliseconds: 400));

    expect(request.status, RideStatus.completed);
    expect(state.activeRide, isNull);
    expect(db.earnerWalletBalance, greaterThan(wallet));
    expect(db.riderTrips.first.status, 'Completed');
    expect(state.lastCompletedRide, isNotNull,
        reason: 'the rating screen reads the settled trip from state');
    expect(find.text('rate screen'), findsOneWidget);

    await _drainSnackBars(tester);
  });

  testWidgets('selecting a rider stays on matching until an explicit action',
      (tester) async {
    final request = _request();
    state.myRideRequest = request;

    await tester.pumpWidget(MaterialApp(
      home: const MatchingScreen(),
      routes: {
        '/livetrip': (_) => const Scaffold(body: Text('live trip route')),
        '/home': (_) => const Scaffold(body: Text('home route')),
      },
    ));

    // The simulated search proposes a rider after its short delay.
    await tester.pump(const Duration(seconds: 1));
    final proposal = state.rideProposal;
    expect(proposal, isNotNull);
    expect(find.text('Select Rider'), findsOneWidget);
    expect(find.text('Find Another'), findsOneWidget);
    expect(find.text(proposal!.riderName), findsOneWidget);
    expect(find.textContaining(proposal.rider.id), findsNothing,
        reason: 'the card must show the rider, not the raw id');

    await tester.tap(find.text('Select Rider'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(request.status, RideStatus.awaitingAcceptance);
    expect(request.riderId, proposal.rider.id);
    expect(state.activeRide, isNull,
        reason: 'selecting a rider is a request, not an accepted trip');
    expect(find.byType(MatchingScreen), findsOneWidget,
        reason: 'assignment keeps the passenger on their request details');
    expect(find.text('home route'), findsNothing);
    expect(find.text('live trip route'), findsNothing);
    expect(find.textContaining(proposal.riderName), findsWidgets);
    expect(find.text(RideStatus.awaitingAcceptance.label), findsOneWidget);

    await _drainSnackBars(tester);
  });

  testWidgets('Find Another offers a different rider', (tester) async {
    state.myRideRequest = _request();

    await tester.pumpWidget(MaterialApp(
      home: const MatchingScreen(),
      routes: {'/home': (_) => const Scaffold(body: Text('home route'))},
    ));

    await tester.pump(const Duration(seconds: 1));
    final first = state.rideProposal!.rider.id;

    await tester.tap(find.text('Find Another'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(state.rideProposal!.rider.id, isNot(first));
    expect(find.text('Select Rider'), findsOneWidget);
  });

  testWidgets('a proposal alone never starts the trip', (tester) async {
    final request = _request();
    state.myRideRequest = request;

    await tester.pumpWidget(MaterialApp(
      home: const MatchingScreen(),
      routes: {
        '/livetrip': (_) => const Scaffold(body: Text('live trip route')),
        '/home': (_) => const Scaffold(body: Text('home route')),
      },
    ));

    await tester.pump(const Duration(seconds: 1));
    expect(state.rideProposal, isNotNull);

    // Waiting longer must not accept on the rider's behalf or open a trip.
    await tester.pump(const Duration(seconds: 5));

    expect(request.status, RideStatus.searching);
    expect(state.activeRide, isNull);
    expect(find.text('live trip route'), findsNothing);
    expect(find.text('Select Rider'), findsOneWidget);
  });
}

RideRequestItem _request() => RideRequestItem(
      id: 'rq-live-trip',
      passengerId: DbService.instance.passenger.id,
      passengerName: 'Test Passenger',
      passengerInitials: 'TP',
      passengerRating: 4.5,
      pickupBarangay: 'Tandag',
      pickupPurok: 'Purok 1',
      pickup: 'SM Terminal',
      dropoffBarangay: 'Tandag',
      dropoffPurok: 'Purok 2',
      dropoff: 'City Hall',
      distanceKm: 3.2,
      etaMinutes: 8,
      fare: Money.pesos(180),
      paymentMethod: 'Cash',
      note: '',
      requestedAt: 'Just now',
    );

Future<void> _tapPrimary(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(SbPrimaryButton, label);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _drainSnackBars(WidgetTester tester) async {
  final messenger =
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
  messenger.clearSnackBars();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
