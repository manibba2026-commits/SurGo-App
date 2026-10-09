import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/data/models.dart';
import 'package:surgo/screens/active_rental_screen.dart';
import 'package:surgo/screens/assisted_booking_screen.dart';
import 'package:surgo/screens/pasuyo_task_screen.dart';
import 'package:surgo/screens/rider_profile_screen.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/pasuyo_status.dart';
import 'package:surgo/state/rental_status.dart';
import 'package:surgo/state/ride_status.dart';
import 'package:surgo/widgets/common.dart';
import 'package:surgo/widgets/ride_request_card.dart';

/// Pins the button wiring on the live job screens: each press must call the
/// one state method that legal move belongs to, and the money must land once.
///
/// These paths are already covered at the state level (`payout_rollup_test`,
/// `pasuyo_flow_test`), which is exactly why a screen can quietly wire a button
/// to the wrong method without any test going red — the model stays correct
/// while the tap does nothing. So these tests drive the real widgets and assert
/// on the same state the screens read.
///
/// [AppState] and [DbService] are singletons, so every test snapshots the state
/// it can touch and restores it; otherwise one test's payout would pay the next
/// test's assertions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  late List<RideRequestItem> savedRequests;
  late List<RiderTripItem> savedTrips;
  late List<_TaskState> savedTasks;
  late Map<EarnerCapability, bool> savedCapabilities;
  late int earnerWallet;
  late int ownerWallet;
  late int today;
  late int week;
  late int month;
  late int ownerToday;
  late int ownerWeek;
  late int ownerMonth;
  late List<int> daily;
  late int txCount;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    savedRequests = List.of(db.rideRequests);
    savedTrips = List.of(db.riderTrips);
    savedTasks = db.pasuyoTasks.map(_TaskState.of).toList();
    savedCapabilities = {
      for (final c in EarnerCapability.values) c: db.earner.accepts(c),
    };
    earnerWallet = db.earnerWalletBalance;
    ownerWallet = db.ownerWalletBalance;
    today = db.earningsToday;
    week = db.earningsWeek;
    month = db.earningsMonth;
    ownerToday = db.ownerEarningsToday;
    ownerWeek = db.ownerEarningsWeek;
    ownerMonth = db.ownerEarningsMonth;
    daily = db.dailyEarnings.map((d) => d.amount).toList();
    txCount = db.earnerTransactions.length;

    // Start every test from a clean slate so a leftover active job from an
    // earlier test cannot silently refuse the claim this test makes.
    state.activeRide = null;
    state.activeRideBreakdown = null;
    state.activeRentalBooking = null;
    state.activePasuyoTask = null;
    state.activePasuyoBreakdown = null;
    state.lastRideBreakdown = null;
    state.lastRentalBreakdown = null;
    state.myRideRequest = null;
    state.rideProposal = null;
    PlatformLedger.instance.reset();
  });

  tearDown(() {
    // Cancels any simulated owner-approval timer a test may have started.
    state.cancelRentalBooking();
    state.cancelActiveRide();
    state.activeRentalBooking = null;
    state.activePasuyoTask = null;
    state.activePasuyoBreakdown = null;
    state.lastRideBreakdown = null;
    state.lastRentalBreakdown = null;

    db.rideRequests
      ..clear()
      ..addAll(savedRequests);
    db.riderTrips
      ..clear()
      ..addAll(savedTrips);
    for (var i = 0; i < savedTasks.length; i++) {
      savedTasks[i].applyTo(db.pasuyoTasks[i]);
    }
    for (final entry in savedCapabilities.entries) {
      db.earner.capabilities[entry.key] =
          db.earner.capabilities[entry.key]!.copyWith(enabled: entry.value);
    }
    db.earnerWalletBalance = earnerWallet;
    db.ownerWalletBalance = ownerWallet;
    db.earningsToday = today;
    db.earningsWeek = week;
    db.earningsMonth = month;
    db.ownerEarningsToday = ownerToday;
    db.ownerEarningsWeek = ownerWeek;
    db.ownerEarningsMonth = ownerMonth;
    for (var i = 0; i < db.dailyEarnings.length; i++) {
      db.dailyEarnings[i].amount = daily[i];
    }
    db.earnerTransactions.removeRange(txCount, db.earnerTransactions.length);
    PlatformLedger.instance.reset();
  });

  testWidgets('the live-ride banner advances the trip and pays out once',
      (tester) async {
    final request = _rideRequest();
    state.respondToRequest(request, accepted: true);
    expect(request.status, RideStatus.accepted);
    expect(state.activeRide, same(request));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // The banner is stateless; in the app its parent rebuilds on each
        // notification, so mirror that here.
        body: ListenableBuilder(
          listenable: state,
          builder: (_, __) => SbActiveRideBanner(ride: request),
        ),
      ),
      // The card also pushes /livetrip on a card tap; give it a route so a
      // stray tap cannot throw, while the button comparison below still proves
      // which target the press reached.
      routes: {'/livetrip': (_) => const Scaffold(body: Text('live trip'))},
    ));

    await tester.tap(find.text('Start heading to pickup'));
    await tester.pump();
    expect(request.status, RideStatus.headingToPickup);

    await tester.tap(find.text("I've arrived at pickup"));
    await tester.pump();
    expect(request.status, RideStatus.arrived);

    await tester.tap(find.text('Start the trip'));
    await tester.pump();
    expect(request.status, RideStatus.inProgress);

    final walletBefore = db.earnerWalletBalance;
    await tester.tap(find.text('Complete trip'));
    await tester.pump();

    expect(request.status, RideStatus.completed);
    expect(state.activeRide, isNull);
    expect(db.earnerWalletBalance, greaterThan(walletBefore),
        reason: 'completing from in-progress is the one step that pays');
    expect(db.riderTrips.first.status, 'Completed');

    // A second press must not be possible: the banner drops the button once the
    // trip is terminal.
    expect(find.text('Complete trip'), findsNothing);

    await _drainSnackBars(tester);
  });

  testWidgets('the helper screen claims an errand and walks it to delivered',
      (tester) async {
    await _useTallSurface(tester);
    final task = db.pasuyoTasks.firstWhere((t) => t.isOpen);
    final walletBefore = db.earnerWalletBalance;

    await tester.pumpWidget(MaterialApp(
      home: PasuyoTaskScreen(taskId: task.id, helperMode: true),
    ));

    await _tapPrimary(tester, 'Accept task');
    expect(task.helperId, db.earner.id);
    expect(task.status, PasuyoStatus.accepted);
    expect(state.activePasuyoTask, same(task));

    // Walk the rest by asking the status what its next action is, so the test
    // follows the machine instead of a hand-written copy of it.
    var guard = 0;
    while (task.status.advanceActionLabel != null && guard++ < 12) {
      await _tapPrimary(tester, task.status.advanceActionLabel!);
    }

    expect(task.status, PasuyoStatus.delivered);
    expect(db.earnerWalletBalance, greaterThan(walletBefore),
        reason: 'the delivered state is the one that releases payment');

    // A stray press after delivery must not pay again.
    final paid = db.earnerWalletBalance;
    state.advancePasuyoTask(task);
    expect(db.earnerWalletBalance, paid);

    await _drainSnackBars(tester);
  });

  testWidgets(
      'the rental screen moves the booking forward and settles the owner',
      (tester) async {
    await _useTallSurface(tester);
    final start = DateTime(2026, 10, 10);
    state.activeRentalBooking = RentalBooking(
      id: 'rb-wiring',
      vehicleName: 'Local Tricycle Rental',
      vehicleType: 'Tricycle',
      icon: Icons.electric_rickshaw,
      ownerName: 'Test Owner',
      ownerInitials: 'TO',
      pickupLabel: 'Oct 10',
      returnLabel: 'Oct 11',
      pickupDate: start,
      returnDate: start.add(const Duration(days: 1)),
      days: 1,
      totalFare: Money.pesos(700),
      // Start at approved so the test drives the renter's steps rather than the
      // 10s simulated owner approval.
      status: RentalStatus.accepted,
      requestedAt: DateTime(2026, 10, 9),
    );
    final ownerBefore = db.ownerWalletBalance;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                ctx,
                MaterialPageRoute(builder: (_) => const ActiveRentalScreen()),
              ),
              child: const Text('open rental'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open rental'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _tapPrimary(tester, 'Pick up the vehicle');
    expect(state.activeRentalBooking!.status, RentalStatus.active,
        reason: 'pick-up is accepted -> active, no money yet');
    expect(db.ownerWalletBalance, ownerBefore);

    await _tapPrimary(tester, 'Return the vehicle');
    expect(state.activeRentalBooking!.status, RentalStatus.returned);

    await _tapPrimary(tester, 'Complete rental');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(state.activeRentalBooking, isNull);
    expect(db.ownerWalletBalance, greaterThan(ownerBefore),
        reason: 'settling a returned vehicle is the one step that pays');

    await _drainSnackBars(tester);
  });

  testWidgets(
      'the assisted-booking screen creates a request for the other person',
      (tester) async {
    await _useTallSurface(tester);

    await tester.pumpWidget(MaterialApp(
      home: const AssistedBookingScreen(),
      routes: {'/matching': (_) => const Scaffold(body: Text('matching'))},
    ));

    // The first two fields are the passenger name and contact number.
    await tester.enterText(find.byType(TextField).at(0), 'Lola Iska');
    await tester.enterText(find.byType(TextField).at(1), '0917 000 0000');
    await tester.tap(find.text('Find a Rider for Them'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Booking for someone else must create the request, not merely navigate:
    // an unwired screen dead-ends on the matching screen's "No active request".
    final request = state.myRideRequest;
    expect(request, isNotNull);
    expect(request!.passengerName, 'Lola Iska',
        reason: 'the rider should see the person actually travelling');
    expect(request.passengerInitials, 'LI');
    expect(find.text('matching'), findsOneWidget,
        reason: 'the flow continues to the matching screen');

    await _drainSnackBars(tester);
  });

  testWidgets('the profile capability switch drives the feed gate',
      (tester) async {
    await _useTallSurface(tester);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EarnerProfileScreen()),
    ));
    await tester.pump();

    // Turn errands and deliveries off while rides stays on: that is what
    // empties the Pasuyo feed, and it leaves rides as the last capability.
    await tester.tap(find.byType(Switch).at(1));
    await tester.pump();
    expect(state.acceptsCapability(EarnerCapability.errands), isFalse);

    await tester.tap(find.byType(Switch).at(2));
    await tester.pump();
    expect(state.acceptsCapability(EarnerCapability.deliveries), isFalse);
    expect(state.nearbyPasuyoTasks, isEmpty,
        reason: 'with errands and deliveries off the feed must be empty');

    await tester.tap(find.byType(Switch).at(0));
    await tester.pump();
    expect(state.acceptsCapability(EarnerCapability.rides), isTrue,
        reason: 'the last capability cannot be switched off');
    expect(find.textContaining('Keep at least one on'), findsOneWidget,
        reason: 'the refusal is explained, not silently ignored');

    await _drainSnackBars(tester);
  });
}

/// A ₱180 request, built rather than taken from the seed so the expected split
/// is exact instead of depending on the demo history.
RideRequestItem _rideRequest() => RideRequestItem(
      id: 'rq-wiring',
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

/// Gives a screen enough height that its action button is laid out, not left
/// unbuilt below a lazy list's viewport.
Future<void> _useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1200, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// Scrolls [label]'s [SbPrimaryButton] into view, taps it and pumps one frame.
Future<void> _tapPrimary(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(SbPrimaryButton, label);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// Empties the snackbar queue so its auto-dismiss timer does not outlive the
/// test. Bounded pumps are used instead of `pumpAndSettle` because the rental
/// screen embeds a live map that keeps the scheduler busy.
Future<void> _drainSnackBars(WidgetTester tester) async {
  final messenger =
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
  messenger.clearSnackBars();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// The mutable fields of a [PasuyoTask] a test can change, snapshotted so the
/// shared seed is restored afterwards.
class _TaskState {
  _TaskState({
    required this.status,
    required this.helperId,
    required this.rating,
    required this.rated,
  });

  factory _TaskState.of(PasuyoTask t) => _TaskState(
        status: t.status,
        helperId: t.helperId,
        rating: t.rating,
        rated: t.rated,
      );

  final PasuyoStatus status;
  final String? helperId;
  final int rating;
  final bool rated;

  void applyTo(PasuyoTask t) {
    t.status = status;
    t.helperId = helperId;
    t.rating = rating;
    t.rated = rated;
  }
}
