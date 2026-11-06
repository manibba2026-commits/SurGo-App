import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/state/app_state.dart';

/// Pins the rule the Earner role exists to express: an earner only sees the
/// work they have switched on, and cannot switch everything off.
///
/// The earner profile is a singleton with a mutable capability map, so each
/// test snapshots the enabled flags and restores them; otherwise the first
/// test's rides-only earner would empty the next test's feed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  setUpAll(() async {
    await db.load();
  });

  late Map<EarnerCapability, bool> saved;

  setUp(() {
    saved = {
      for (final c in EarnerCapability.values) c: db.earner.accepts(c),
    };
  });

  tearDown(() {
    for (final entry in saved.entries) {
      db.earner.capabilities[entry.key] =
          db.earner.capabilities[entry.key]!.copyWith(enabled: entry.value);
    }
  });

  test('the seeded earner accepts every capability', () {
    for (final c in EarnerCapability.values) {
      expect(state.acceptsCapability(c), isTrue, reason: '$c should be on');
    }
  });

  test('switching one capability off leaves the rest alone', () {
    expect(state.setEarnerCapability(EarnerCapability.errands, false), isTrue);
    expect(state.acceptsCapability(EarnerCapability.errands), isFalse);
    expect(state.acceptsCapability(EarnerCapability.rides), isTrue);
    expect(state.acceptsCapability(EarnerCapability.deliveries), isTrue);
  });

  test('refuses to switch off the last active capability', () {
    state.setEarnerCapability(EarnerCapability.rides, false);
    state.setEarnerCapability(EarnerCapability.deliveries, false);
    // Errands is now the only one left, so turning it off must be refused.
    expect(state.setEarnerCapability(EarnerCapability.errands, false), isFalse);
    expect(state.acceptsCapability(EarnerCapability.errands), isTrue);
  });

  test('the feed hides every errand once errands and deliveries are off', () {
    state.setEarnerCapability(EarnerCapability.errands, false);
    state.setEarnerCapability(EarnerCapability.deliveries, false);

    // Still a valid earner - rides keep them on the road.
    expect(state.acceptsCapability(EarnerCapability.rides), isTrue);
    expect(state.nearbyPasuyoTasks, isEmpty);
  });

  test('the feed returns open errands while errands are on', () {
    state.setEarnerCapability(EarnerCapability.rides, false);

    // Deliveries remains on, which is enough to be offered Pasuyo work.
    expect(state.acceptsCapability(EarnerCapability.deliveries), isTrue);
    expect(state.nearbyPasuyoTasks, isNotEmpty);
  });
}
