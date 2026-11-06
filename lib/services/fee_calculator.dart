import 'package:flutter/foundation.dart';
import 'money.dart';

/// The service lines SurGo earns on. Every transaction in the app must be
/// priced so the "Customer pays / Provider gets / SurGo keeps" split is
/// consistent across receipts, provider earnings and the platform revenue
/// screen.
///
/// The three lines do not share a pricing policy, and this build only settles
/// one of them:
///
///  * [ride] — decided. The provider keeps 100% of the agreed fare and SurGo
///    charges a separate distance platform fee. Priced by `RidePricing`, never
///    by the rates below; [FeeRates.bpsFor] refuses the question for a ride.
///  * [pasuyo] — UNRESOLVED. Still priced at the legacy 15% commission taken
///    out of the customer's budget, because no decision has been made whether
///    the helper should also keep the full amount and be charged a fee on top.
///    Do not change it here: doing so would silently re-tax every seeded and
///    live errand.
///  * [rental] — UNRESOLVED. Still priced at the legacy 10% commission on the
///    rental total. A multi-day rental has no distance to charge a per-km fee
///    against, so moving it needs its own rule (per day, per trip, or a flat
///    listing fee) rather than a copy of the ride formula.
enum ServiceType {
  ride,
  pasuyo,
  rental;

  String get label {
    switch (this) {
      case ServiceType.ride:
        return 'Ride';
      case ServiceType.pasuyo:
        return 'Pasuyo';
      case ServiceType.rental:
        return 'Rental';
    }
  }
}

/// How SurGo earned the platform amount in a breakdown.
///
/// The two are not interchangeable and must never be reported as one figure:
/// a commission is a share of the fare the provider quoted, while a platform
/// fee is a separate charge the customer pays on top of a fare the provider
/// keeps whole.
enum FeeBasis { percentageCommission, distancePlatformFee }

/// The money movement for one completed transaction. [customerPays] is the
/// gross amount charged, [providerGets] is what the rider/helper/owner earns,
/// and [surgoKeeps] is what SurGo earns. They always sum to [customerPays] —
/// asserted in the constructor so a bad rate or a rounding path can never
/// silently create or destroy money.
///
/// All three amounts are integer centavos; see [Money].
@immutable
class FeeBreakdown {
  final ServiceType service;
  final int customerPays;
  final int providerGets;
  final int surgoKeeps;
  final FeeBasis basis;

  const FeeBreakdown._({
    required this.service,
    required this.customerPays,
    required this.providerGets,
    required this.surgoKeeps,
    required this.basis,
  });

  /// A split where SurGo's cut came out of the gross at a percentage rate.
  factory FeeBreakdown({
    required ServiceType service,
    required int customerPays,
    required int providerGets,
  }) {
    assert(
      customerPays >= 0,
      'customerPays must not be negative',
    );
    assert(
      providerGets >= 0 && providerGets <= customerPays,
      'providerGets must be between 0 and customerPays',
    );
    return FeeBreakdown._(
      service: service,
      customerPays: customerPays,
      providerGets: providerGets,
      surgoKeeps: customerPays - providerGets,
      basis: FeeBasis.percentageCommission,
    );
  }

  /// A ride: the provider keeps the whole fare and the platform fee sits on
  /// top of it, paid by the customer. Neither amount is a share of the other.
  factory FeeBreakdown.distanceFee({
    required int providerFare,
    required int platformFee,
  }) {
    assert(providerFare >= 0, 'providerFare must not be negative');
    assert(platformFee >= 0, 'platformFee must not be negative');
    return FeeBreakdown._(
      service: ServiceType.ride,
      customerPays: providerFare + platformFee,
      providerGets: providerFare,
      surgoKeeps: platformFee,
      basis: FeeBasis.distancePlatformFee,
    );
  }

  /// Formats the split for a receipt row, e.g. "₱162.00".
  ///
  /// Delegates to [Money.format] so every amount in the app renders the same
  /// way. Screens should prefer [Money.format] directly rather than building a
  /// peso sign by hand.
  String money(int amount) => Money.format(amount);

  String get customerPaysLabel => money(customerPays);
  String get providerGetsLabel => money(providerGets);
  String get surgoKeepsLabel => money(surgoKeeps);

  /// Commission as a share of the gross amount, for the "10% of ₱180" row.
  double get surgoRatePercent =>
      customerPays == 0 ? 0 : (surgoKeeps / customerPays) * 100;
}

/// Single source of truth for commission rates and fee math.
///
/// Rates are in basis points so the arithmetic stays in integers and no
/// floating-point rounding creeps into a peso amount. 1000 bps = 10%.
///
/// Basis-point math is independent of the currency unit, so every [gross]
/// below is an integer number of centavos (see [Money]) and the split is
/// correct at either scale: 10% of `18000` and 10% of `180` both round the
/// same way once the unit is applied.
/// Commission rates, loaded from `assets/db/config.json` at startup.
///
/// These are mutable statics rather than constants so the seed file can be the
/// single place a rate is defined, while the defaults below keep
/// [FeeCalculator] usable in tests and before `DbService` has loaded.
class FeeRates {
  FeeRates._();

  /// Defaults used in tests and before `DbService` reads the seed.
  static int pasuyoBps = 1500;
  static int rentalBps = 1000;

  /// The percentage rate for a service still priced on commission.
  ///
  /// Rides deliberately have none. Asking this question for a ride is refused
  /// rather than answered with the retired 10% figure, because a stale rate
  /// applied quietly is worse than no rate at all: it would take a cut out of
  /// a fare the provider is owed in full.
  static int bpsFor(ServiceType service) => switch (service) {
        ServiceType.ride => throw UnsupportedError(
            'Rides are priced by distance through RidePricing, '
            'not by percentage commission.'),
        ServiceType.pasuyo => pasuyoBps,
        ServiceType.rental => rentalBps,
      };

  /// Applies the rates from the seed, ignoring non-positive values so a
  /// missing or malformed field falls back to the default above.
  static void configure({
    required int pasuyo,
    required int rental,
  }) {
    if (pasuyo > 0) pasuyoBps = pasuyo;
    if (rental > 0) rentalBps = rental;
  }
}

class FeeCalculator {
  FeeCalculator._();

  static int get pasuyoCommissionBps => FeeRates.pasuyoBps;
  static int get rentalCommissionBps => FeeRates.rentalBps;

  static double get pasuyoCommissionPercent => FeeRates.pasuyoBps / 100;
  static double get rentalCommissionPercent => FeeRates.rentalBps / 100;

  static int commissionBpsFor(ServiceType service) => FeeRates.bpsFor(service);

  static double commissionPercentFor(ServiceType service) =>
      commissionBpsFor(service) / 100;

  /// The provider's cut of [gross] for the given [service].
  static int providerShare(ServiceType service, int gross) {
    if (gross <= 0) return 0;
    final keep = _commissionOf(service, gross);
    return gross - keep;
  }

  /// SurGo's commission on [gross]. Rounds half-up on the peso, so the
  /// provider and platform amounts always re-add to the exact gross.
  static int surgoShare(ServiceType service, int gross) =>
      gross <= 0 ? 0 : _commissionOf(service, gross);

  /// Full three-way split for one transaction.
  static FeeBreakdown breakdownFor(ServiceType service, int gross) {
    if (gross <= 0) {
      return FeeBreakdown(service: service, customerPays: 0, providerGets: 0);
    }
    return FeeBreakdown(
      service: service,
      customerPays: gross,
      providerGets: providerShare(service, gross),
    );
  }

  static int _commissionOf(ServiceType service, int gross) {
    final bps = commissionBpsFor(service);
    final raw = gross * bps;
    // Half-up on the whole peso: (raw / 10000 + 0.5).floor() without floats.
    return ((raw * 2) + 10000) ~/ 20000;
  }
}

/// One recorded transaction for the platform revenue screen. Seeded from the
/// mock history at startup, then appended live whenever a trip, Pasuyo task or
/// rental completes.
@immutable
class LedgerEntry {
  final String id;
  final ServiceType service;
  final int gross;
  final int providerGets;
  final int surgoKeeps;
  final FeeBasis basis;

  /// Whether SurGo has actually received this amount.
  ///
  /// In a cash prototype the customer hands the driver the money and nothing
  /// moves to SurGo by itself, so an earned fee starts as unremitted. Counting
  /// it as collected before it is would put money on the screen that no one
  /// holds.
  final bool isRemitted;
  final DateTime timestamp;

  const LedgerEntry({
    required this.id,
    required this.service,
    required this.gross,
    required this.providerGets,
    required this.surgoKeeps,
    this.basis = FeeBasis.percentageCommission,
    this.isRemitted = false,
    required this.timestamp,
  });

  factory LedgerEntry.fromBreakdown(
    String id,
    FeeBreakdown b, {
    DateTime? timestamp,
    bool isRemitted = false,
  }) =>
      LedgerEntry(
        id: id,
        service: b.service,
        gross: b.customerPays,
        providerGets: b.providerGets,
        surgoKeeps: b.surgoKeeps,
        basis: b.basis,
        isRemitted: isRemitted,
        timestamp: timestamp ?? DateTime.now(),
      );
}

/// Accumulates SurGo's commission across every completed transaction.
///
/// Deliberately a plain [ChangeNotifier] rather than part of DbService: the
/// ledger is derived state, and keeping it separate means the seed data and the
/// live math cannot drift out of sync with each other.
class PlatformLedger extends ChangeNotifier {
  PlatformLedger._internal();
  static final PlatformLedger instance = PlatformLedger._internal();

  final List<LedgerEntry> _entries = <LedgerEntry>[];
  bool _seeded = false;

  List<LedgerEntry> get entries => List.unmodifiable(_entries);

  bool get isSeeded => _seeded;

  /// SurGo's total commission across all recorded transactions.
  int get totalRevenue =>
      _entries.fold(0, (sum, entry) => sum + entry.surgoKeeps);

  /// Total gross volume handled, across all services.
  int get totalVolume => _entries.fold(0, (sum, e) => sum + e.gross);

  /// Total paid out to riders, helpers and vehicle owners.
  int get totalPayouts => _entries.fold(0, (sum, e) => sum + e.providerGets);

  int get transactionCount => _entries.length;

  /// SurGo's earnings for one service type, optionally restricted to one
  /// pricing basis so a ride platform fee is never confused with a commission.
  int revenueFor(ServiceType service, {FeeBasis? basis}) => _entries
      .where((e) =>
          e.service == service && (basis == null || e.basis == basis))
      .fold(0, (sum, e) => sum + e.surgoKeeps);

  /// What providers earned on one service type. This is the amount actually
  /// paid to riders, helpers and owners, not a platform figure.
  int providerEarningsFor(ServiceType service) => _entries
      .where((e) => e.service == service)
      .fold(0, (sum, e) => sum + e.providerGets);

  int volumeFor(ServiceType service) => _entries
      .where((e) => e.service == service)
      .fold(0, (sum, e) => sum + e.gross);

  int countFor(ServiceType service) =>
      _entries.where((e) => e.service == service).length;

  /// Commission per service, for the revenue screen's breakdown rows.
  Map<ServiceType, int> get revenueByService => {
        for (final service in ServiceType.values)
          service: revenueFor(service),
      };

  Map<ServiceType, int> get volumeByService => {
        for (final service in ServiceType.values)
          service: volumeFor(service),
      };

  /// Commission earned today, by calendar day.
  int get revenueToday => _onDay(DateTime.now());

  int _onDay(DateTime day) {
    var sum = 0;
    for (final e in _entries) {
      final t = e.timestamp;
      if (t.year == day.year && t.month == day.month && t.day == day.day) {
        sum += e.surgoKeeps;
      }
    }
    return sum;
  }

  /// Commission for the last [days] days, oldest first — the data behind the
  /// revenue screen's daily bar chart.
  List<int> revenueLastDays(int days) {
    final now = DateTime.now();
    return List<int>.generate(days, (i) {
      final day = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: days - 1 - i));
      return _onDay(day);
    });
  }

  /// Records a completed transaction and returns the breakdown that was
  /// recorded, so callers can show the receipt without recomputing.
  FeeBreakdown record(
    ServiceType service,
    int gross, {
    String? id,
    DateTime? timestamp,
  }) {
    final breakdown = FeeCalculator.breakdownFor(service, gross);
    _insert(breakdown, id: id, timestamp: timestamp);
    return breakdown;
  }

  /// Records a ride: the provider fare paid through in full, the platform fee
  /// earned on top of it.
  ///
  /// A ride cannot go through [record], which prices by percentage. Passing
  /// the fare and the fee separately is what keeps the ledger able to say
  /// which basis each row was earned on, and stops the revenue screen turning
  /// a ₱2/km fee back into a "take rate".
  FeeBreakdown recordRide({
    required int providerFare,
    required int platformFee,
    String? id,
    DateTime? timestamp,
    bool isRemitted = false,
  }) {
    final breakdown = FeeBreakdown.distanceFee(
      providerFare: providerFare,
      platformFee: platformFee,
    );
    _insert(breakdown, id: id, timestamp: timestamp, isRemitted: isRemitted);
    return breakdown;
  }

  void _insert(
    FeeBreakdown breakdown, {
    String? id,
    DateTime? timestamp,
    bool isRemitted = false,
  }) {
    _entries.insert(
      0,
      LedgerEntry.fromBreakdown(
        id ??
            'led${timestamp?.microsecondsSinceEpoch ?? DateTime.now().microsecondsSinceEpoch}',
        breakdown,
        timestamp: timestamp,
        isRemitted: isRemitted,
      ),
    );
    notifyListeners();
  }

  /// Fees SurGo has actually been paid.
  ///
  /// This is the only figure that may be called cash on hand: an earned fee
  /// the driver still holds is a receivable, not revenue in a cash prototype.
  int get remittedRevenue =>
      _entries.where((e) => e.isRemitted).fold(0, (sum, e) => sum + e.surgoKeeps);

  /// Fees earned but not yet remitted to SurGo.
  int get outstandingRevenue => totalRevenue - remittedRevenue;

  /// What each pricing basis has earned, so a ride fee and a Pasuyo
  /// commission are never added into one percentage.
  int earnedBy(FeeBasis basis) =>
      _entries.where((e) => e.basis == basis).fold(0, (s, e) => s + e.surgoKeeps);

  /// Ride platform fees earned (₱2/km, within the ₱5–₱30 band).
  int get platformFeeRevenue => earnedBy(FeeBasis.distancePlatformFee);

  /// Commission earned on Pasuyo and rentals.
  int get commissionRevenue => earnedBy(FeeBasis.percentageCommission);

  /// Ride platform fees that have actually been remitted to SurGo.
  int get remittedPlatformFees => _entries
      .where((e) => e.isRemitted && e.basis == FeeBasis.distancePlatformFee)
      .fold(0, (sum, e) => sum + e.surgoKeeps);

  /// Ride platform fees still held by the driver after a cash trip.
  int get outstandingPlatformFees => platformFeeRevenue - remittedPlatformFees;

  /// Commission that has actually been remitted to SurGo.
  int get remittedCommission => _entries
      .where((e) => e.isRemitted && e.basis == FeeBasis.percentageCommission)
      .fold(0, (sum, e) => sum + e.surgoKeeps);

  int get outstandingCommission => commissionRevenue - remittedCommission;

  /// Total provider earnings across every service.
  int get providerEarnings => totalPayouts;

  /// Seeds the ledger from already-completed history so the revenue screen has
  /// something to show before the demo's first transaction. Idempotent.
  ///
  /// Every service that earns SurGo a cut has to be passed in here, otherwise
  /// the revenue screen silently under-reports: a seeded Pasuyo history with no
  /// matching argument shows P0 Pasuyo revenue while the rider was paid.
  ///
  /// A ride arrives as a fare and the fee already priced for it, because the
  /// fee depends on that trip's distance and only the caller has it. Letting
  /// the ledger price rides would give the app two answers to one question.
  void seedFromHistory({
    required List<({int fare, int platformFee})> completedRides,
    required List<int> completedRentalTotals,
    List<int> completedPasuyoBudgets = const [],
  }) {
    if (_seeded) return;
    _seeded = true;

    final now = DateTime.now();
    // Spread the seed over the last 7 days so the daily chart has shape.
    void addDays(int daysAgo, ServiceType service, int gross) {
      if (gross <= 0) return;
      final ts = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: daysAgo, hours: 9));
      record(service, gross, id: 'seed-${service.name}-$daysAgo', timestamp: ts);
    }

    for (var i = 0; i < completedRides.length; i++) {
      final ride = completedRides[i];
      final ts = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: i % 7, hours: 9));
      recordRide(
        providerFare: ride.fare,
        platformFee: ride.platformFee,
        id: 'seed-ride-$i',
        timestamp: ts,
      );
    }
    for (var i = 0; i < completedRentalTotals.length; i++) {
      addDays((i + 2) % 7, ServiceType.rental, completedRentalTotals[i]);
    }
    for (var i = 0; i < completedPasuyoBudgets.length; i++) {
      addDays((i + 4) % 7, ServiceType.pasuyo, completedPasuyoBudgets[i]);
    }
  }

  /// Test/demo reset so the ledger can be re-seeded.
  void reset() {
    _entries.clear();
    _seeded = false;
    notifyListeners();
  }
}