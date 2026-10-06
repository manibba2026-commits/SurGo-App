import 'package:flutter/foundation.dart';
import 'money.dart';

/// The service lines SurGo takes a commission on. Every transaction in the
/// app must be priced through [FeeCalculator] so the "Customer pays / Provider
/// gets / SurGo keeps" split is consistent across receipts, rider earnings
/// and the platform revenue screen.
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

/// The money movement for one completed transaction. [customerPays] is the
/// gross amount charged, [providerGets] is what the rider/helper/owner earns,
/// and [platformKeeps] is SurGo's commission. They always sum to
/// [customerPays] — [surgoShare] is asserted in the constructor so a bad rate
/// or a rounding path can never silently create or destroy money.
///
/// All three amounts are integer centavos; see [Money].
@immutable
class FeeBreakdown {
  final ServiceType service;
  final int customerPays;
  final int providerGets;
  final int surgoKeeps;

  const FeeBreakdown._({
    required this.service,
    required this.customerPays,
    required this.providerGets,
    required this.surgoKeeps,
  });

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

  static int rideBps = 1000; // 10%
  static int pasuyoBps = 1500; // 15%
  static int rentalBps = 1000; // 10%

  static int bpsFor(ServiceType service) {
    switch (service) {
      case ServiceType.ride:
        return rideBps;
      case ServiceType.pasuyo:
        return pasuyoBps;
      case ServiceType.rental:
        return rentalBps;
    }
  }

  /// Applies the rates from the seed, ignoring non-positive values so a
  /// missing or malformed field falls back to the default above.
  static void configure({
    required int ride,
    required int pasuyo,
    required int rental,
  }) {
    if (ride > 0) rideBps = ride;
    if (pasuyo > 0) pasuyoBps = pasuyo;
    if (rental > 0) rentalBps = rental;
  }
}

class FeeCalculator {
  FeeCalculator._();

  static int get rideCommissionBps => FeeRates.rideBps;
  static int get pasuyoCommissionBps => FeeRates.pasuyoBps;
  static int get rentalCommissionBps => FeeRates.rentalBps;

  static double get rideCommissionPercent => FeeRates.rideBps / 100;
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
  final DateTime timestamp;

  const LedgerEntry({
    required this.id,
    required this.service,
    required this.gross,
    required this.providerGets,
    required this.surgoKeeps,
    required this.timestamp,
  });

  factory LedgerEntry.fromBreakdown(
    String id,
    FeeBreakdown b, {
    DateTime? timestamp,
  }) =>
      LedgerEntry(
        id: id,
        service: b.service,
        gross: b.customerPays,
        providerGets: b.providerGets,
        surgoKeeps: b.surgoKeeps,
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

  /// SurGo's commission for one service type.
  int revenueFor(ServiceType service) => _entries
      .where((e) => e.service == service)
      .fold(0, (sum, e) => sum + e.surgoKeeps);

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
    _entries.insert(
      0,
      LedgerEntry.fromBreakdown(
        id ?? 'led${timestamp?.microsecondsSinceEpoch ?? DateTime.now().microsecondsSinceEpoch}',
        breakdown,
        timestamp: timestamp,
      ),
    );
    notifyListeners();
    return breakdown;
  }

  /// Seeds the ledger from already-completed history so the revenue screen has
  /// something to show before the demo's first transaction. Idempotent.
  ///
  /// Every service that earns SurGo a cut has to be passed in here, otherwise
  /// the revenue screen silently under-reports: a seeded Pasuyo history with no
  /// matching argument shows P0 Pasuyo revenue while the rider was paid.
  void seedFromHistory({
    required List<int> completedRideFares,
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

    for (var i = 0; i < completedRideFares.length; i++) {
      addDays(i % 7, ServiceType.ride, completedRideFares[i]);
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