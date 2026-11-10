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

  testWidgets('matching names the rider instead of the internal id',
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
    expect(find.text('Confirm rider'), findsOneWidget);

    await tester.tap(find.text('Confirm rider'));
    await tester.pump();

    expect(find.textContaining(proposal!.riderName), findsOneWidget);
    expect(find.textContaining(request.riderId!), findsNothing,
        reason: 'the waiting state must not show the raw rider id');

    // The simulated rider accepts after two seconds and the trip opens.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));

    expect(request.status, RideStatus.accepted);
    expect(find.text('live trip route'), findsOneWidget);

    await _drainSnackBars(tester);
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
