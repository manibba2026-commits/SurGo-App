import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/state/app_state.dart';

void main() {
  late AppState state;

  // DbService loads the seed assets through rootBundle, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    state = AppState.instance;
    await state.init();
  });

  test('signed-in passenger id matches the seeded Pasuyo customers', () {
    final customerIds = state.db.pasuyoTasks
        .map((t) => t.customerId)
        .toSet();
    expect(
      customerIds,
      contains(state.passenger.id),
      reason: 'the signed-in passenger must own at least one seeded task, '
          'otherwise myPasuyoOrders is always empty',
    );
  });

  test('myPasuyoOrders is not empty and only returns own tasks', () {
    expect(state.myPasuyoOrders, isNotEmpty);
    for (final task in state.myPasuyoOrders) {
      expect(task.customerId, state.passenger.id);
    }
  });

  test('signed-in rider id matches the seeded Pasuyo helpers', () {
    final helperIds = state.db.pasuyoTasks
        .map((t) => t.helperId)
        .whereType<String>()
        .toSet();
    expect(
      helperIds,
      contains(state.earner.id),
      reason: 'the signed-in rider must be a seeded helper, otherwise '
          'myPasuyoTasks / completedPasuyoTasks and netPasuyoEarnings are empty',
    );
  });

  test('every seeded helper resolves to a rider on the map', () {
    final mapRiderIds = state.db.mapRiders.map((r) => r.id).toSet();
    for (final task in state.db.pasuyoTasks) {
      final helperId = task.helperId;
      if (helperId == null) continue;
      expect(
        mapRiderIds,
        contains(helperId),
        reason: 'task ${task.id} has helper $helperId, which is not in '
            'mapRiders, so the helper card cannot resolve on the task screen',
      );
    }
  });

  test('every seeded customer resolves to a passenger on the map', () {
    final mapPassengerIds = state.db.mapPassengers.map((p) => p.id).toSet();
    for (final task in state.db.pasuyoTasks) {
      expect(
        mapPassengerIds,
        contains(task.customerId),
        reason: 'task ${task.id} has customer ${task.customerId}, which is '
            'not in mapPassengers',
      );
    }
  });

  test('signed-in owner id matches the seeded rental vehicles', () {
    final owners = state.db.mapRentalVehicles.map((v) => v.ownerId).toSet();
    expect(owners, contains(state.db.vehicleOwner.id));
  });
}
