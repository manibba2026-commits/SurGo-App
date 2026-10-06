import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';

/// Locks the ride and rental payout paths.
///
/// Completing a job moves money in three places: the provider's wallet balance,
/// the seeded `earningsToday/Week/Month` roll-ups that the home tiles read, and
/// the platform ledger. Crediting only some of them leaves the app contradicting
/// itself — the rider is paid while the earnings screen still shows the seeded
/// figure — so each test asserts all three moved by the same amount.
///
/// The shared invariant is that the provider is credited the net share and
/// SurGo's commission reaches the ledger and nowhere else. Pasuyo's version of
/// this is in `pasuyo_flow_test.dart`; the commission rates themselves are
/// pinned in `fee_calculator_test.dart`.
///
/// [AppState] and [DbService] are singletons, so every test snapshots the fields
/// it touches and restores them — otherwise one test's payout would pay the
/// next test's assertions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;
  final ledger = PlatformLedger.instance;

  late List<RideRequestItem> savedRequests;
  late List<RiderTripItem> savedTrips;
  late List<RentalHistoryItem> savedRentalHistory;
  late int riderWallet;
  late int ownerWallet;
  late int today;
  late int week;
  late int month;
  late int ownerToday;
  late int ownerWeek;
  late int ownerMonth;
  late List<int> daily;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    savedRequests = List.of(db.rideRequests);
    savedTrips = List.of(db.riderTrips);
    savedRentalHistory = List.of(db.rentalHistory);
    riderWallet = db.riderWalletBalance;
    ownerWallet = db.ownerWalletBalance;
    today = db.earningsToday;
    week = db.earningsWeek;
    month = db.earningsMonth;
    ownerToday = db.ownerEarningsToday;
    ownerWeek = db.ownerEarningsWeek;
    ownerMonth = db.ownerEarningsMonth;
    daily = db.dailyEarnings.map((d) => d.amount).toList();
    ledger.reset();
  });

  tearDown(() {
    // cancelRentalBooking also cancels the simulated 10s owner-approval timer.
    state.cancelRentalBooking();
    state.cancelActiveRide();
    state.lastRideBreakdown = null;
    state.lastRentalBreakdown = null;
    db.rideRequests
      ..clear()
      ..addAll(savedRequests);
    db.riderTrips
      ..clear()
      ..addAll(savedTrips);
    db.rentalHistory
      ..clear()
      ..addAll(savedRentalHistory);
    db.riderWalletBalance = riderWallet;
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
    ledger.reset();
  });

  /// A ₱180 request, built rather than taken from the seed so the expected
  /// split is exact instead of depending on the demo history.
  RideRequestItem rideRequest() => RideRequestItem(
        id: 'rq-rollup',
        passengerId: db.passenger.id,
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

  void acceptRide(RideRequestItem request) {
    state.respondToRequest(request, accepted: true);
    state.completeActiveRide();
  }

  /// Books a rental at [totalFare] and completes it, as the owner would after
  /// the vehicle is returned.
  void completeRental({required int totalFare}) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    state.requestRental(
      vehicleId: null,
      vehicleName: 'Test Ride',
      vehicleType: 'Tricycle',
      icon: Icons.electric_rickshaw,
      ownerName: 'Test Owner',
      ownerInitials: 'TO',
      pickupLabel: 'Today',
      returnLabel: 'Tomorrow',
      pickupDate: start,
      returnDate: start.add(const Duration(days: 2)),
      days: 2,
      totalFare: totalFare,
    );
    // Walk the whole rental lifecycle rather than jumping to the end. Return of
    // the vehicle is what releases the payout, so completing straight from
    // `requested` is correctly refused and would pay nothing. The owner-decides
    // steps use their real methods so this stays the same path the app takes.
    state.sendRentalRequest();
    // The app normally reaches this through the 10s owner-decides timer; the
    // test calls the owner's decision directly so it does not have to wait.
    state.acceptRentalRequest();
    state.advanceRentalBooking(pickup: true);
    state.advanceRentalBooking(pickup: false);
    state.completeActiveRental();
  }

  group('completing a ride', () {
    test('credits the wallet and every roll-up by the net share', () {
      final request = rideRequest();
      final payout = FeeCalculator.breakdownFor(ServiceType.ride, request.fare);

      acceptRide(request);

      expect(payout.providerGets, Money.pesos(162));
      expect(db.riderWalletBalance, riderWallet + payout.providerGets);
      expect(db.earningsToday, today + payout.providerGets,
          reason: 'the rider home tile reads this roll-up');
      expect(db.earningsWeek, week + payout.providerGets);
      expect(db.earningsMonth, month + payout.providerGets);
    });

    test('never pays SurGo commission to the rider', () {
      final request = rideRequest();
      final split = FeeCalculator.breakdownFor(ServiceType.ride, request.fare);

      acceptRide(request);

      expect(split.surgoKeeps, greaterThan(0), reason: 'sanity: 10% of ₱180');
      expect(db.riderWalletBalance - riderWallet, isNot(request.fare),
          reason: 'the gross belongs to nobody on the rider side');
      expect(db.riderWalletBalance - riderWallet, lessThan(request.fare));
    });

    test('records the commission on the platform ledger', () {
      final request = rideRequest();
      final split = FeeCalculator.breakdownFor(ServiceType.ride, request.fare);

      acceptRide(request);

      expect(ledger.entries, hasLength(1));
      expect(ledger.entries.first.service, ServiceType.ride);
      expect(ledger.entries.first.gross, request.fare);
      expect(ledger.entries.first.surgoKeeps, split.surgoKeeps);
      expect(ledger.revenueFor(ServiceType.ride), split.surgoKeeps);
    });

    test('logs the trip at the gross fare and leaves the receipt priced', () {
      final request = rideRequest();

      acceptRide(request);

      final trip = db.riderTrips.first;
      expect(trip.fare, request.fare,
          reason: 'history stores what the customer paid');
      expect(trip.status, 'Completed');
      expect(trip.route, contains(request.pickup));
      expect(trip.route, contains(request.dropoff));
      expect(state.lastRideBreakdown!.providerGets,
          FeeCalculator.breakdownFor(ServiceType.ride, request.fare).providerGets);
    });

    test('adds the payout to today in the 7-day chart when a bucket exists', () {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final label = weekdays[DateTime.now().weekday - 1];
      final bucket =
          db.dailyEarnings.where((d) => d.day == label).toList();
      if (bucket.isEmpty) return; // Seed is older than the current week.
      final before = bucket.first.amount;
      final request = rideRequest();
      final payout = FeeCalculator.breakdownFor(ServiceType.ride, request.fare);

      acceptRide(request);

      expect(bucket.first.amount, before + payout.providerGets);
    });

    test('pays nothing when there is no active ride', () {
      state.cancelActiveRide();

      state.completeActiveRide();

      expect(db.riderWalletBalance, riderWallet);
      expect(db.earningsToday, today);
      expect(ledger.entries, isEmpty);
    });
  });

  group('completing a rental', () {
    test('credits the owner wallet and every roll-up by the net share', () {
      final gross = Money.pesos(2500);
      final payout = FeeCalculator.breakdownFor(ServiceType.rental, gross);

      completeRental(totalFare: gross);

      expect(payout.providerGets, Money.pesos(2250));
      expect(db.ownerWalletBalance, ownerWallet + payout.providerGets);
      expect(db.ownerEarningsToday, ownerToday + payout.providerGets);
      expect(db.ownerEarningsWeek, ownerWeek + payout.providerGets);
      expect(db.ownerEarningsMonth, ownerMonth + payout.providerGets);
    });

    test('does not touch the rider balances', () {
      final gross = Money.pesos(2500);

      completeRental(totalFare: gross);

      expect(db.riderWalletBalance, riderWallet);
      expect(db.earningsToday, today);
    });

    test('records the commission and marks the rental completed', () {
      final gross = Money.pesos(2500);
      final split = FeeCalculator.breakdownFor(ServiceType.rental, gross);

      completeRental(totalFare: gross);

      expect(ledger.entries, hasLength(1));
      expect(ledger.entries.first.service, ServiceType.rental);
      expect(ledger.entries.first.surgoKeeps, split.surgoKeeps);
      expect(db.rentalHistory.first.status, 'Completed');
      expect(db.rentalHistory.first.totalFare, gross);
      expect(state.lastRentalBreakdown!.providerGets, split.providerGets);
    });

    test('pays nothing when no rental is active', () {
      state.cancelRentalBooking();

      state.completeActiveRental();

      expect(db.ownerWalletBalance, ownerWallet);
      expect(db.ownerEarningsToday, ownerToday);
      expect(ledger.entries, isEmpty);
    });
  });

  group('across services', () {
    test('the providers keep the net share and SurGo keeps the commission', () {
      final rideFare = Money.pesos(180);
      final rentalFare = Money.pesos(2500);
      final ride = FeeCalculator.breakdownFor(ServiceType.ride, rideFare);
      final rental = FeeCalculator.breakdownFor(ServiceType.rental, rentalFare);

      acceptRide(rideRequest());
      completeRental(totalFare: rentalFare);

      // Each provider was credited their own line, and nothing else.
      expect(db.riderWalletBalance - riderWallet, ride.providerGets);
      expect(db.ownerWalletBalance - ownerWallet, rental.providerGets);

      // The ledger accounts for every centavo of the two transactions.
      expect(ledger.totalPayouts, ride.providerGets + rental.providerGets);
      expect(ledger.totalRevenue, ride.surgoKeeps + rental.surgoKeeps);
      expect(ledger.totalPayouts + ledger.totalRevenue, ledger.totalVolume,
          reason: 'payout plus commission must re-add to the gross');
      expect(ledger.totalVolume, rideFare + rentalFare);
      expect(ledger.transactionCount, 2);
    });
  });
}
