import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';

/// Pins the "live session activity" contract the dashboards and Activity tab
/// read: [AppState.liveRideRequest] and [AppState.livePasuyoOrders] must surface
/// only what the account is actually doing right now, not a finished request or
/// a cancelled errand left behind in the session.
void main() {
  late AppState state;
  final posted = <PasuyoTask>[];
  final created = <RideRequestItem>[];

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    state = AppState.instance;
    await state.init();
  });

  setUp(() {
    state.myRideRequest = null;
    state.rideProposal = null;
    state.activeRide = null;
    state.activeRideBreakdown = null;
  });

  tearDown(() {
    for (final r in created) {
      state.db.rideRequests.remove(r);
    }
    created.clear();
    for (final t in posted) {
      state.db.pasuyoTasks.remove(t);
    }
    posted.clear();
    state.myRideRequest = null;
    state.rideProposal = null;
    state.activeRide = null;
    state.activeRideBreakdown = null;
  });

  PasuyoTask postErrand() {
    final task = state.postPasuyoTask(
      category: PasuyoCategory.values.first,
      title: 'Live errand',
      items: const ['Item'],
      pickupBarangay: 'Poblacion',
      pickupPurok: 'Purok 1',
      pickup: 'Poblacion, Purok 1',
      dropoffBarangay: 'Downtown',
      dropoffPurok: 'Purok 2',
      dropoff: 'Downtown, Purok 2',
      budget: 5000,
    );
    posted.add(task);
    return task;
  }

  test('no live ride before one is created', () {
    expect(state.liveRideRequest, isNull);
  });

  test('a just-created request is live while it is still being matched', () {
    final request = state.createRideRequest();
    created.add(request);

    expect(request.status, RideStatus.searching);
    expect(state.liveRideRequest, same(request));
  });

  test('a finished request drops off the live list but stays the session ride',
      () {
    final request = state.createRideRequest();
    created.add(request);

    while (request.status.next != null) {
      request.advanceTo(request.status.next!);
    }

    expect(request.status, RideStatus.completed);
    expect(state.myRideRequest, same(request));
    expect(state.liveRideRequest, isNull);
  });

  test('cancelling clears the live ride request', () {
    state.createRideRequest();
    expect(state.liveRideRequest, isNotNull);

    state.cancelRideRequest();
    expect(state.myRideRequest, isNull);
    expect(state.liveRideRequest, isNull);
  });

  test('a posted errand is live until it finishes', () {
    final task = postErrand();

    expect(task.status.isTerminal, isFalse);
    expect(state.livePasuyoOrders, contains(task));
  });

  test('a cancelled errand is no longer live', () {
    final task = postErrand();
    expect(state.livePasuyoOrders, contains(task));

    state.cancelPasuyoTask(task);
    expect(task.status.isTerminal, isTrue);
    expect(state.livePasuyoOrders, isNot(contains(task)));
  });
}
