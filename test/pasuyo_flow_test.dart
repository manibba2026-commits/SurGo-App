import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/pasuyo_status.dart';

/// Exercises the errand lifecycle end to end: claim → advance → paid, plus the
/// three ways a claim can be refused and the cancelled/rated terminal states.
///
/// The state is a singleton, so every test snapshots the fields it touches and
/// restores them; without that, the first test's completed errand would pay the
/// next test's assertions. Only [status], [helperId], [rating] and [rated] are
/// mutable on a task, so those are all that need saving.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  late List<_TaskState> saved;
  late int originalCount;
  late int wallet;
  late int today;
  late int week;
  late int month;
  late List<int> daily;
  late int txCount;
  late PasuyoTask? active;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    saved = db.pasuyoTasks.map(_TaskState.of).toList();
    originalCount = db.pasuyoTasks.length;
    wallet = db.riderWalletBalance;
    today = db.earningsToday;
    week = db.earningsWeek;
    month = db.earningsMonth;
    daily = db.dailyEarnings.map((d) => d.amount).toList();
    txCount = db.riderTransactions.length;
    active = state.activePasuyoTask;
  });

  tearDown(() {
    // Drop anything a test posted, then restore in the original order.
    if (db.pasuyoTasks.length > originalCount) {
      db.pasuyoTasks.removeRange(originalCount, db.pasuyoTasks.length);
    }
    for (var i = 0; i < saved.length; i++) {
      saved[i].applyTo(db.pasuyoTasks[i]);
    }
    db.riderWalletBalance = wallet;
    db.earningsToday = today;
    db.earningsWeek = week;
    db.earningsMonth = month;
    for (var i = 0; i < db.dailyEarnings.length; i++) {
      db.dailyEarnings[i].amount = daily[i];
    }
    db.riderTransactions.removeRange(txCount, db.riderTransactions.length);
    state.activePasuyoTask = active;
    state.activePasuyoBreakdown = null;
  });

  PasuyoTask openTask() => db.pasuyoTasks.firstWhere((t) => t.isOpen);

  /// An errand posted by the signed-in helper, which [AppState] must refuse.
  PasuyoTask ownTask() => PasuyoTask(
        id: 'own-1',
        customerId: db.rider.id,
        category: PasuyoCategory.values.first,
        title: 'Own errand',
        items: const ['Milk'],
        pickupBarangay: 'Tandag',
        pickupPurok: 'Purok 1',
        pickup: 'SM Terminal',
        dropoffBarangay: 'Tandag',
        dropoffPurok: 'Purok 2',
        dropoff: 'Jollibee',
        budget: Money.pesos(150),
      );

  group('accepting an errand', () {
    test('claims it, makes it active and prices the payout', () {
      final task = openTask();

      final refusal = state.acceptPasuyoTask(task);

      expect(refusal, isNull);
      expect(task.helperId, db.rider.id);
      expect(task.status, PasuyoStatus.accepted);
      expect(state.activePasuyoTask, same(task));
      expect(state.hasActivePasuyoTask, isTrue);
      expect(state.activePasuyoBreakdown!.customerPays, task.budget);
      expect(state.activePasuyoBreakdown!.providerGets,
          FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget).providerGets);
    });

    test('refuses a second errand while one is still in progress', () {
      state.acceptPasuyoTask(openTask());
      final second = db.pasuyoTasks.where((t) => t.isOpen).toList().first;

      final refusal = state.acceptPasuyoTask(second);

      expect(refusal, PasuyoAcceptRefusal.alreadyHasTask);
      expect(second.helperId, isNull,
          reason: 'the second errand must stay up for grabs');
      expect(second.isOpen, isTrue);
    });

    test('refuses an errand that is no longer open', () {
      final task = openTask();
      task.status = PasuyoStatus.delivered;

      final refusal = state.acceptPasuyoTask(task);

      expect(refusal, PasuyoAcceptRefusal.notOpen);
      expect(state.hasActivePasuyoTask, isFalse);
    });

    test('refuses an errand posted by the accepting account', () {
      final task = ownTask();

      expect(state.isOwnCustomerTask(task), isTrue);
      expect(state.acceptPasuyoTask(task), PasuyoAcceptRefusal.ownCustomer);
      expect(state.hasActivePasuyoTask, isFalse);
      expect(task.helperId, isNull);
    });

    test('treats a different customer as fair game', () {
      expect(state.isOwnCustomerTask(openTask()), isFalse);
    });

    test('the helper slot frees up once the errand completes', () {
      final task = openTask();
      state.acceptPasuyoTask(task);
      expect(state.hasActivePasuyoTask, isTrue);

      while (state.activePasuyoTask != null) {
        state.advancePasuyoTask(task);
      }

      expect(state.hasActivePasuyoTask, isFalse);
      expect(state.activePasuyoBreakdown, isNull);
      expect(state.acceptPasuyoTask(task), PasuyoAcceptRefusal.notOpen);
    });
  });

  group('status ladder', () {
    test('walks every state to delivered, then stops', () {
      final task = openTask();
      expect(task.status, PasuyoStatus.available);
      expect(task.nextStatus, PasuyoStatus.accepted);

      state.acceptPasuyoTask(task);
      expect(task.status, PasuyoStatus.accepted);

      // Each advance is driven by the enum, so the ladder is asserted against
      // the flow itself rather than a hand-written copy of it.
      var expected = PasuyoStatus.accepted;
      while (expected.next != null) {
        expected = expected.next!;
        state.advancePasuyoTask(task);
        expect(task.status, expected);
      }

      expect(task.status, PasuyoStatus.delivered);
      expect(task.isComplete, isTrue);

      // Terminal: a delivered errand must not roll forward on a stray tap.
      expect(task.nextStatus, isNull);
      state.advancePasuyoTask(task);
      expect(task.status, PasuyoStatus.delivered);
    });

    test('pays out exactly once, on the final state', () {
      final task = openTask();
      state.acceptPasuyoTask(task);
      final walletBefore = db.riderWalletBalance;
      final earningsBefore = db.earningsToday;

      var guard = 0;
      while (task.nextStatus != null && guard++ < 20) {
        state.advancePasuyoTask(task);
      }

      final walletAfter = db.riderWalletBalance;
      expect(walletAfter, greaterThan(walletBefore));
      expect(db.earningsToday, greaterThan(earningsBefore));

      // A stray tap after delivery must not pay a second time.
      state.advancePasuyoTask(task);
      expect(db.riderWalletBalance, walletAfter);
    });

    test('a cancelled errand has no next step and reports step -1', () {
      final task = openTask();
      state.acceptPasuyoTask(task);
      state.cancelPasuyoTask(task);

      expect(task.status, PasuyoStatus.cancelled);
      expect(task.isCancelled, isTrue);
      expect(task.nextStatus, isNull);
      expect(task.stepIndex, -1, reason: 'must not fall back to step 1');
      expect(task.stepLabel, 'Cancelled');
      expect(state.activePasuyoTask, isNull);
      expect(state.hasActivePasuyoTask, isFalse);
    });

    test('cancelling pays nothing and leaves the errand unclaimable', () {
      final task = openTask();
      final walletBefore = db.riderWalletBalance;
      state.acceptPasuyoTask(task);
      state.cancelPasuyoTask(task);

      expect(db.riderWalletBalance, walletBefore);
      expect(db.earningsToday, today);
      expect(state.acceptPasuyoTask(task), PasuyoAcceptRefusal.notOpen);
    });
  });

  group('completion pays the helper', () {
    int payoutFor(PasuyoTask task) =>
        FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget).providerGets;

    void runToCompletion(PasuyoTask task) {
      state.acceptPasuyoTask(task);
      while (state.activePasuyoTask != null) {
        state.advancePasuyoTask(task);
      }
    }

    test('credits the wallet and the earning roll-ups in centavos', () {
      final task = openTask();
      final payout = payoutFor(task);
      final walletBefore = db.riderWalletBalance;

      runToCompletion(task);

      expect(payout, greaterThan(0));
      expect(db.riderWalletBalance, walletBefore + payout);
      expect(db.earningsToday, today + payout,
          reason: 'the home tile reads this roll-up');
      expect(db.earningsWeek, week + payout);
      expect(db.earningsMonth, month + payout);
      expect(Money.format(payout), matches(r'^₱'));
    });

    test('logs a credit row describing the errand', () {
      final task = openTask();
      runToCompletion(task);

      expect(db.riderTransactions.length, txCount + 1);
      final row = db.riderTransactions.first;
      expect(row.type, 'credit');
      expect(row.title, contains(task.title));
      expect(row.amount, payoutFor(task));
    });

    test('credits exactly once even if advance is spammed', () {
      final task = openTask();
      final walletBefore = db.riderWalletBalance;

      runToCompletion(task);
      for (var i = 0; i < 5; i++) {
        state.advancePasuyoTask(task);
      }

      expect(db.riderWalletBalance, walletBefore + payoutFor(task));
      expect(db.earningsToday, today + payoutFor(task));
    });

    test('adds the payout to today in the 7-day chart when a bucket exists', () {
      final task = openTask();
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final todayLabel = weekdays[DateTime.now().weekday - 1];
      final matches =
          db.dailyEarnings.where((d) => d.day == todayLabel).toList();
      if (matches.isEmpty) return; // Seed is older than the current week.
      final bucketBefore = matches.first.amount;

      runToCompletion(task);

      expect(matches.first.amount, bucketBefore + payoutFor(task));
    });
  });

  group('rating', () {
    test('stores the stars and marks the errand rated', () {
      final task = openTask();
      state.acceptPasuyoTask(task);
      while (state.activePasuyoTask != null) {
        state.advancePasuyoTask(task);
      }

      state.ratePasuyoTask(task, 4);

      expect(task.rating, 4);
      expect(task.rated, isTrue);
      expect(task.status, PasuyoStatus.delivered,
          reason: 'rating must not reopen the task');
    });

    test('can overwrite a rating', () {
      final task = openTask();
      state.ratePasuyoTask(task, 2);
      state.ratePasuyoTask(task, 5);
      expect(task.rating, 5);
      expect(task.rated, isTrue);
    });
  });

  group('posting an errand', () {
    test('records a peso budget as centavos and starts posted', () {
      final before = db.pasuyoTasks.length;

      final task = state.postPasuyoTask(
        category: PasuyoCategory.values.first,
        title: 'Test errand',
        items: const ['Milk'],
        pickupBarangay: 'Tandag',
        pickupPurok: 'Purok 1',
        pickup: 'SM Terminal',
        dropoffBarangay: 'Tandag',
        dropoffPurok: 'Purok 2',
        dropoff: 'Jollibee',
        budget: Money.pesos(150),
        note: 'note',
      );

      expect(db.pasuyoTasks.length, before + 1);
      expect(db.pasuyoTasks.first, same(task));
      expect(task.budget, 15000);
      expect(Money.format(task.budget), '₱150.00');
      expect(task.isOpen, isTrue);
      expect(task.helperId, isNull);
      expect(task.customerId, db.passenger.id);
    });
  });
}

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