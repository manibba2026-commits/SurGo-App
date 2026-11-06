import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/services/ride_pricing.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';

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
  late List<RideHistoryItem> savedRideHistory;
  late List<RentalHistoryItem> savedRentalHistory;
  late List<PayoutItem> savedPayouts;
  late List<WalletTransaction> savedEarnerTransactions;
  late List<WalletTransaction> savedOwnerTransactions;
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
    savedRideHistory = List.of(db.rideHistory);
    savedRentalHistory = List.of(db.rentalHistory);
    savedPayouts = List.of(db.payoutHistory);
    savedEarnerTransactions = List.of(db.earnerTransactions);
    savedOwnerTransactions = List.of(db.ownerTransactions);
    riderWallet = db.earnerWalletBalance;
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
    db.rideHistory
      ..clear()
      ..addAll(savedRideHistory);
    db.rentalHistory
      ..clear()
      ..addAll(savedRentalHistory);
    db.payoutHistory
      ..clear()
      ..addAll(savedPayouts);
    db.earnerTransactions
      ..clear()
      ..addAll(savedEarnerTransactions);
    db.ownerTransactions
      ..clear()
      ..addAll(savedOwnerTransactions);
    db.earnerWalletBalance = riderWallet;
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

  /// The ride price the request settles at: the agreed fare plus the
  /// distance-based platform fee, all in centavos.
  RidePrice ridePrice(RideRequestItem request) => RidePricing.price(
        providerFare: request.fare,
        distance: TripDistance.seeded(request.distanceKm),
      );

  void acceptRide(RideRequestItem request) {
    // Walk the trip through its states rather than jumping to the payout. A
    // request starts `searching`, so it has to be matched first: nobody can
    // accept a ride that was never assigned to them. Completing straight from
    // `searching` is correctly refused, so skipping the steps would pay for a
    // trip that never ran.
    expect(request.status, RideStatus.searching);
    state.respondToRequest(request, accepted: true);
    expect(request.status, RideStatus.accepted);

    state.advanceRide(); // heading to pickup
    expect(request.status, RideStatus.headingToPickup);
    state.advanceRide(); // arrived
    expect(request.status, RideStatus.arrived);
    state.advanceRide(); // in progress
    expect(request.status, RideStatus.inProgress);

    state.completeActiveRide();
    expect(request.status, RideStatus.completed);
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
    test('credits the wallet and every roll-up by the full fare', () {
      final request = rideRequest();
      final price = ridePrice(request);

      acceptRide(request);

      expect(price.providerFare, Money.pesos(180));
      expect(db.earnerWalletBalance, riderWallet + price.providerFare);
      expect(db.earningsToday, today + price.providerFare,
          reason: 'the rider home tile reads this roll-up');
      expect(db.earningsWeek, week + price.providerFare);
      expect(db.earningsMonth, month + price.providerFare);
    });

    test('pays the rider the whole fare and takes no commission', () {
      final request = rideRequest();

      acceptRide(request);

      expect(db.earnerWalletBalance - riderWallet, request.fare,
          reason: 'the provider keeps 100% of the agreed fare');
      expect(ledger.platformFeeRevenue, greaterThan(0),
          reason: 'sanity: the customer paid a platform fee');
      expect(ledger.commissionRevenue, 0,
          reason: 'rides must never return to percentage commission');
    });

    test('records the platform fee separately on the ledger', () {
      final request = rideRequest();
      final price = ridePrice(request);

      acceptRide(request);

      final entry = ledger.entries.single;
      expect(entry.service, ServiceType.ride);
      expect(entry.basis, FeeBasis.distancePlatformFee);
      expect(entry.providerGets, price.providerFare);
      expect(entry.surgoKeeps, price.platformFee);
      expect(entry.gross, price.customerTotal);
      expect(entry.isRemitted, isFalse,
          reason: 'cash prototype: the driver still holds the fee');
      expect(ledger.platformFeeRevenue, price.platformFee);
      expect(ledger.remittedPlatformFees, 0);
      expect(ledger.outstandingPlatformFees, price.platformFee);
    });

    test('stores the provider fare on history and keeps the receipt itemised',
        () {
      final request = rideRequest();
      final price = ridePrice(request);

      acceptRide(request);

      final trip = db.riderTrips.first;
      expect(trip.fare, price.providerFare,
          reason: 'history keeps the provider fare, not the customer total');
      expect(trip.status, 'Completed');
      expect(trip.route, contains(request.pickup));
      expect(trip.route, contains(request.dropoff));
      final receipt = state.lastRideBreakdown!;
      expect(receipt.providerGets, price.providerFare);
      expect(receipt.surgoKeeps, price.platformFee);
      expect(receipt.customerPays, price.customerTotal);
    });

    test('adds the payout to today in the 7-day chart when a bucket exists', () {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final label = weekdays[DateTime.now().weekday - 1];
      final bucket =
          db.dailyEarnings.where((d) => d.day == label).toList();
      if (bucket.isEmpty) return; // Seed is older than the current week.
      final before = bucket.first.amount;
      final request = rideRequest();
      final price = ridePrice(request);

      acceptRide(request);

      expect(bucket.first.amount, before + price.providerFare);
    });

    test('pays nothing when there is no active ride', () {
      state.cancelActiveRide();

      state.completeActiveRide();

      expect(db.earnerWalletBalance, riderWallet);
      expect(db.earningsToday, today);
      expect(ledger.entries, isEmpty);
    });

    test('settles exactly once across repeated calls and rating', () {
      final walletBefore = db.earnerWalletBalance;
      final tripsBefore = db.riderTrips.length;
      final historyBefore = db.rideHistory.length;
      final request = rideRequest();
      final price = ridePrice(request);

      acceptRide(request);

      final walletAfterSettlement = db.earnerWalletBalance;
      expect(walletAfterSettlement, walletBefore + price.providerFare);
      expect(db.riderTrips, hasLength(tripsBefore + 1));
      expect(db.rideHistory, hasLength(historyBefore + 1),
          reason: 'one settlement writes one passenger history row');
      expect(ledger.entries, hasLength(1));

      final item = db.rideHistory.first;
      expect(item.fare, request.fare);
      expect(item.route, '${request.pickup} → ${request.dropoff}');
      expect(item.status, 'Completed');
      expect(state.lastCompletedRide, same(item));
      expect(state.lastCompletedRideDriver, isNotNull);

      // A second press is refused: the trip is terminal and activeRide is null.
      expect(state.completeActiveRide(), isFalse);
      expect(db.earnerWalletBalance, walletAfterSettlement);
      expect(db.riderTrips, hasLength(tripsBefore + 1));
      expect(db.rideHistory, hasLength(historyBefore + 1));
      expect(ledger.entries, hasLength(1));

      // Rating updates the one existing row and never settles again.
      state.rateCompletedRide(5);
      expect(db.earnerWalletBalance, walletAfterSettlement);
      expect(db.riderTrips, hasLength(tripsBefore + 1));
      expect(db.rideHistory, hasLength(historyBefore + 1));
      expect(ledger.entries, hasLength(1));
      expect(db.rideHistory.first.rating, 5);
      expect(state.lastCompletedRide, same(db.rideHistory.first));
    });

    test('refuses to settle a ride that has not reached in-progress', () {
      final walletBefore = db.earnerWalletBalance;
      final tripsBefore = db.riderTrips.length;
      final historyBefore = db.rideHistory.length;
      final request = rideRequest();

      state.respondToRequest(request, accepted: true);
      expect(request.status, RideStatus.accepted);

      expect(state.completeActiveRide(), isFalse);

      expect(db.earnerWalletBalance, walletBefore);
      expect(db.riderTrips, hasLength(tripsBefore));
      expect(db.rideHistory, hasLength(historyBefore));
      expect(ledger.entries, isEmpty);
      expect(request.status, RideStatus.accepted,
          reason: 'a refused settlement must not complete the trip');
    });

    test('keeps the receipt snapshot when the signed-in profile changes', () {
      final request = rideRequest();
      acceptRide(request);

      final snapshotName = state.lastCompletedRideDriver!.name;
      final historyName = db.rideHistory.first.driverName;
      final original = db.earner;
      final replacement =
          db.earners.values.firstWhere((e) => e.id != original.id);
      db.earner = replacement;
      addTearDown(() => db.earner = original);

      expect(state.lastCompletedRideDriver!.name, snapshotName);
      expect(db.rideHistory.first.driverName, historyName);
      expect(snapshotName, historyName);
    });
  });

  group('rider payouts', () {
    test('refuses non-positive, below-minimum and over-balance amounts', () {
      final balance = db.earnerWalletBalance;
      final payouts = db.payoutHistory.length;
      final transactions = db.earnerTransactions.length;
      final minimum = state.minimumWithdrawal;

      expect(minimum, Money.pesos(300),
          reason: 'the configured minimum reaches AppState');
      expect(state.requestPayout(0, 'GCash'), isFalse);
      expect(state.requestPayout(-1, 'GCash'), isFalse);
      expect(state.requestPayout(minimum - 1, 'GCash'), isFalse);
      expect(state.requestPayout(balance + 1, 'GCash'), isFalse);

      expect(db.earnerWalletBalance, balance);
      expect(db.payoutHistory, hasLength(payouts));
      expect(db.earnerTransactions, hasLength(transactions));
    });

    test('pays the exact minimum', () {
      final balance = db.earnerWalletBalance;
      final amount = state.minimumWithdrawal;
      final payouts = db.payoutHistory.length;
      expect(balance, greaterThanOrEqualTo(amount),
          reason: 'the seed must be able to make a valid payout');

      expect(state.requestPayout(amount, 'GCash'), isTrue);

      expect(db.earnerWalletBalance, balance - amount);
      expect(db.payoutHistory, hasLength(payouts + 1));
      expect(db.payoutHistory.first.amount, amount);
    });

    test('pays the exact balance once, then refuses the repeat', () {
      final balance = db.earnerWalletBalance;
      final payouts = db.payoutHistory.length;
      expect(balance, greaterThanOrEqualTo(state.minimumWithdrawal));

      expect(state.requestPayout(balance, 'GCash'), isTrue);
      expect(db.earnerWalletBalance, 0);
      expect(db.payoutHistory, hasLength(payouts + 1));

      expect(state.requestPayout(balance, 'GCash'), isFalse);
      expect(db.earnerWalletBalance, 0);
      expect(db.payoutHistory, hasLength(payouts + 1));
    });
  });

  group('owner payouts', () {
    test('refuses non-positive, below-minimum and over-balance amounts', () {
      final balance = db.ownerWalletBalance;
      final transactions = db.ownerTransactions.length;
      final minimum = state.minimumWithdrawal;

      expect(balance, greaterThanOrEqualTo(minimum));
      expect(state.requestOwnerPayout(0, 'GCash'), isFalse);
      expect(state.requestOwnerPayout(-1, 'GCash'), isFalse);
      expect(state.requestOwnerPayout(minimum - 1, 'GCash'), isFalse);
      expect(state.requestOwnerPayout(balance + 1, 'GCash'), isFalse);

      expect(db.ownerWalletBalance, balance);
      expect(db.ownerTransactions, hasLength(transactions));
    });

    test('pays the exact minimum and the exact balance once', () {
      final balance = db.ownerWalletBalance;
      final minimum = state.minimumWithdrawal;
      final transactions = db.ownerTransactions.length;

      expect(state.requestOwnerPayout(minimum, 'GCash'), isTrue);
      expect(db.ownerWalletBalance, balance - minimum);
      expect(db.ownerTransactions, hasLength(transactions + 1));

      final remaining = db.ownerWalletBalance;
      expect(state.requestOwnerPayout(remaining, 'GCash'), isTrue);
      expect(db.ownerWalletBalance, 0);
      expect(db.ownerTransactions, hasLength(transactions + 2));

      expect(state.requestOwnerPayout(minimum, 'GCash'), isFalse);
      expect(db.ownerWalletBalance, 0);
      expect(db.ownerTransactions, hasLength(transactions + 2));
    });
  });

  group('payout config', () {
    test('reads a positive minimum in centavos', () {
      expect(
          DbService.minWithdrawalFromConfig({
            'payouts': {'minWithdrawal': 25000},
          }),
          25000);
    });

    test('falls back when missing, malformed or non-positive', () {
      const fallback = DbService.defaultPayoutMinWithdrawal;
      expect(DbService.minWithdrawalFromConfig({}), fallback);
      expect(DbService.minWithdrawalFromConfig({'payouts': 'bad'}), fallback);
      expect(
          DbService.minWithdrawalFromConfig({
            'payouts': <String, dynamic>{},
          }),
          fallback);
      expect(
          DbService.minWithdrawalFromConfig({
            'payouts': {'minWithdrawal': '25000'},
          }),
          fallback);
      expect(
          DbService.minWithdrawalFromConfig({
            'payouts': {'minWithdrawal': 0},
          }),
          fallback);
      expect(
          DbService.minWithdrawalFromConfig({
            'payouts': {'minWithdrawal': -25000},
          }),
          fallback);
    });

    test('accepts a custom fallback', () {
      expect(DbService.minWithdrawalFromConfig({}, fallback: 12345), 12345);
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

      expect(db.earnerWalletBalance, riderWallet);
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
    test('ride fees and rental commissions are accounted separately', () {
      final rentalFare = Money.pesos(2500);
      final ride = ridePrice(rideRequest());
      final rental = FeeCalculator.breakdownFor(ServiceType.rental, rentalFare);

      acceptRide(rideRequest());
      completeRental(totalFare: rentalFare);

      // Each provider was credited their own line, and nothing else.
      expect(db.earnerWalletBalance - riderWallet, ride.providerFare);
      expect(db.ownerWalletBalance - ownerWallet, rental.providerGets);

      // The ledger accounts for every centavo of the two transactions.
      expect(ledger.totalPayouts, ride.providerFare + rental.providerGets);
      expect(ledger.totalRevenue, ride.platformFee + rental.surgoKeeps);
      expect(ledger.platformFeeRevenue, ride.platformFee);
      expect(ledger.commissionRevenue, rental.surgoKeeps);
      expect(ledger.totalPayouts + ledger.totalRevenue, ledger.totalVolume,
          reason: 'payout plus platform earnings must re-add to the gross');
      expect(ledger.totalVolume, ride.customerTotal + rentalFare);
      expect(ledger.transactionCount, 2);
    });
  });
}
