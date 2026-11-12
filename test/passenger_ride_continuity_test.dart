import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/services/geoapify_service.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';

// Auth is only a capability flag here; these tests never contact a provider.
class _HostedAuth extends MockAuthRepository {
  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<void> signOut() async {}
}

RideRecord _ride({
  String id = 'ride-1',
  String passenger = 'passenger-1',
  RideStatus status = RideStatus.searching,
  int fee = 731,
}) => RideRecord(
  id: id,
  passengerId: passenger,
  riderId: status == RideStatus.searching ? null : 'rider-1',
  serviceAreaId: 'area-1',
  status: status,
  // Deliberately unresolved addresses and no coordinates: no routing or GPS
  // transport should be invoked by a continuity regression test.
  pickupAddress: 'Unmapped pickup',
  dropoffAddress: 'Unmapped dropoff',
  distanceKm: 3.25,
  etaMinutes: 9,
  fareCentavos: 18765,
  platformFeeCentavos: fee,
  paymentMethod: 'cash',
  passengerName: 'Test Passenger',
  riderName: 'Test Rider',
  requestedAt: DateTime.utc(2026, 11, 6, 8),
  completedAt: status == RideStatus.completed
      ? DateTime.utc(2026, 11, 6, 9)
      : null,
);

class _Rides extends MockRideRepository {
  List<RideRecord> records = [];
  Future<List<RideRecord>> Function(String passenger)? read;
  Future<RideRecord> Function()? create;
  RepositoryFailure? cancelFailure;
  int createCalls = 0;
  final reads = <({String passenger, int? limit})>[];
  final cancellations = <({String id, String? reason})>[];

  @override
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  }) async {
    reads.add((passenger: passengerId, limit: limit));
    return read == null ? List.of(records) : await read!(passengerId);
  }

  @override
  Future<RideRecord> createRideRequest({
    required String pickupAddress,
    String? pickupBarangay,
    String? pickupPurok,
    double? pickupLatitude,
    double? pickupLongitude,
    required String dropoffAddress,
    String? dropoffBarangay,
    String? dropoffPurok,
    double? dropoffLatitude,
    double? dropoffLongitude,
    required double distanceKm,
    required int etaMinutes,
    required int fareCentavos,
    required int platformFeeCentavos,
    String? note,
    String? serviceAreaId,
  }) async {
    createCalls++;
    return create == null ? _ride() : await create!();
  }

  @override
  Future<RideRecord> cancelRide({
    required String rideId,
    String? reason,
  }) async {
    cancellations.add((id: rideId, reason: reason));
    if (cancelFailure != null) throw cancelFailure!;
    return _ride(id: rideId, status: RideStatus.cancelled);
  }
}

class _Watch {
  _Watch(this.value) {
    events = StreamController<void>(onCancel: () => cancellations++);
  }
  final String value;
  late final StreamController<void> events;
  int cancellations = 0;
}

class _Realtime implements SurgoRealtimeBackend {
  final watches = <_Watch>[];

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    expect(table, 'ride_requests');
    expect(column, 'passenger_id');
    final watch = _Watch(value);
    watches.add(watch);
    return watch.events.stream;
  }
}

class _Rig {
  _Rig(this.time) {
    final mock = RepositoryRegistry.mock();
    state.demoRideStore = null;
    state.configureAuth(_HostedAuth());
    state.configureRepositories(
      RepositoryRegistry(
        profiles: mock.profiles,
        catalog: mock.catalog,
        vehicles: mock.vehicles,
        rides: rides,
        rentals: mock.rentals,
        pasuyo: mock.pasuyo,
        notifications: mock.notifications,
        wallet: mock.wallet,
        verifications: mock.verifications,
        attachments: mock.attachments,
        isSupabaseBacked: true,
        realtime: realtime,
      ),
    );
    identity('passenger-1');
    state.riderOnline = false;
    state.setPickup('Unmapped pickup');
    state.setDestination('Unmapped dropoff');
    time.flushMicrotasks();
  }

  final FakeAsync time;
  final state = AppState.instance;
  final rides = _Rides();
  final realtime = _Realtime();

  void identity(String id) {
    state.identity = SurgoIdentity(
      userId: id,
      fullName: 'Test Passenger',
      capabilities: const {CapabilityType.passenger},
      eligibleCapabilities: const {},
      roles: const {'passenger'},
      providers: const {'phone'},
      profileExists: true,
    );
    state.currentAccount = Account(
      id: id,
      authUserId: id,
      passengerId: id,
      name: 'Test Passenger',
      phone: '',
      email: '',
    );
    state.authStatus = AuthStatus.signedIn;
  }

  void restore() {
    unawaited(state.restorePassengerRide());
    time.flushMicrotasks();
  }

  void refresh() {
    unawaited(state.refreshPassengerRide());
    time.flushMicrotasks();
  }

  void emit() {
    realtime.watches.last.events.add(null);
    time.flushMicrotasks();
  }

  void logout() {
    unawaited(state.logout());
    time.flushMicrotasks();
  }

  void dispose() {
    // Stop the owned ride session, not the shared AppState singleton.
    state.configureRepositories(RepositoryRegistry.mock());
    for (final watch in realtime.watches) {
      unawaited(watch.events.close());
    }
    state.bookingRouting.sync(start: null, end: null, enabled: false);
    state.rideRouting.sync(start: null, end: null, enabled: false);
    time.flushMicrotasks();
    expect(time.periodicTimerCount, 0);
    expect(time.nonPeriodicTimerCount, 0);
  }
}

void _continuityTest(String name, void Function(FakeAsync, _Rig) body) {
  test(name, () {
    fakeAsync((time) {
      final rig = _Rig(time);
      try {
        body(time, rig);
      } finally {
        rig.dispose();
      }
    });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;

  setUpAll(() => state.init());

  setUp(() async {
    state.demoRideStore = null;
    await state.logout();
    state.riderOnline = false;
  });

  tearDown(() async {
    await state.logout();
    state.configureRepositories(RepositoryRegistry.mock());
    state.configureAuth(MockAuthRepository());
    state.riderOnline = false;
  });

  for (final pending in [RideStatus.searching, RideStatus.awaitingAcceptance]) {
    _continuityTest(
      'restores ${pending.wireValue}, accepts through Realtime and retains the stored-fee receipt',
      (time, rig) {
        final db = state.db;
        final walletBefore = db.earnerWalletBalance;
        final historyBefore = List.of(db.rideHistory);
        final requestsBefore = List.of(db.rideRequests);
        rig.rides.records = [_ride(status: pending)];
        rig.restore();
        expect(state.passengerRideLoading, isFalse);
        expect(state.passengerRideFailure, isNull);
        expect(state.myRideRequest!.status, pending);
        expect(state.liveRideRequest!.id, 'ride-1');
        expect(state.activeRide, isNull, reason: 'an offer is not acceptance');
        expect(state.activeRideBreakdown, isNull);
        expect(rig.rides.reads.single, (passenger: 'passenger-1', limit: null));

        rig.rides.records = [_ride(status: RideStatus.accepted)];
        rig.emit();
        expect(state.activeRide, same(state.myRideRequest));
        expect(state.activeRide!.riderId, 'rider-1');
        expect(state.activeRide!.status, RideStatus.accepted);
        expect(state.activeRide!.platformFeeCentavos, 731);
        expect(state.activeRideBreakdown!.providerGets, 18765);
        expect(state.activeRideBreakdown!.surgoKeeps, 731);
        expect(state.activeRideBreakdown!.customerPays, 19496);

        // A changed route or a new booking quote must not reprice a stored ride.
        state.rideRouting.route = const GeoRoute(
          points: [],
          distanceMeters: 990000,
          durationSeconds: 99999,
        );
        state.setPickup('Another unmapped pickup');
        state.setDestination('Another unmapped destination');
        expect(state.priceFor(state.activeRide!).platformFee, 731);
        rig.rides.records = [_ride(status: RideStatus.completed)];
        time.elapse(const Duration(seconds: 15));
        time.flushMicrotasks();
        expect(state.liveRideRequest, isNull);
        expect(state.activeRide, isNull);
        expect(state.activeRideBreakdown, isNull);
        expect(state.myRideRequest!.status, RideStatus.completed);
        expect(state.lastCompletedRide!.id, 'ride-1');
        expect(state.lastCompletedRide!.fare, 18765);
        expect(state.lastCompletedRideDriver!.name, 'Test Rider');
        expect(state.lastRideBreakdown!.providerGets, 18765);
        expect(state.lastRideBreakdown!.surgoKeeps, 731);
        expect(state.lastRideBreakdown!.customerPays, 19496);
        final receipt = state.lastCompletedRide;
        final breakdown = state.lastRideBreakdown;
        rig.refresh();
        expect(state.lastCompletedRide, same(receipt));
        expect(state.lastRideBreakdown, same(breakdown));
        expect(db.earnerWalletBalance, walletBefore);
        expect(
          db.rideHistory,
          historyBefore,
          reason:
              'hosted reconciliation cannot settle local seed money/history',
        );
        expect(db.rideRequests, requestsBefore);
      },
    );
  }

  _continuityTest(
    'terminal history on initial restore is not a live request or a new receipt',
    (time, rig) {
      state.applyHostedRideUpdate(
        _ride(id: 'previous-receipt', status: RideStatus.completed),
      );
      final receipt = state.lastCompletedRide;
      final breakdown = state.lastRideBreakdown;
      rig.rides.records = [
        _ride(id: 'other-history', status: RideStatus.completed),
        _ride(id: 'cancelled-history', status: RideStatus.cancelled),
      ];
      rig.restore();
      expect(state.liveRideRequest, isNull);
      expect(state.activeRide, isNull);
      expect(state.lastCompletedRide, same(receipt));
      expect(state.lastRideBreakdown, same(breakdown));
    },
  );

  _continuityTest(
    'cancellation clears an accepted ride without replacing the previous receipt',
    (time, rig) {
      state.applyHostedRideUpdate(
        _ride(id: 'previous-receipt', status: RideStatus.completed),
      );
      final receipt = state.lastCompletedRide;
      final breakdown = state.lastRideBreakdown;
      rig.rides.records = [_ride(status: RideStatus.accepted)];
      rig.restore();
      rig.rides.records = [_ride(status: RideStatus.cancelled)];
      rig.emit();
      expect(state.myRideRequest!.status, RideStatus.cancelled);
      expect(state.liveRideRequest, isNull);
      expect(state.activeRide, isNull);
      expect(state.activeRideBreakdown, isNull);
      expect(state.lastCompletedRide, same(receipt));
      expect(state.lastRideBreakdown, same(breakdown));
    },
  );

  for (final status in [RideStatus.searching, RideStatus.accepted]) {
    _continuityTest(
      'successful empty refresh clears restored ${status.wireValue}',
      (time, rig) {
        rig.rides.records = [_ride(status: status)];
        rig.restore();
        rig.rides.records = [];
        rig.refresh();
        expect(state.passengerRideLoading, isFalse);
        expect(state.passengerRideFailure, isNull);
        expect(state.myRideRequest, isNull);
        expect(state.liveRideRequest, isNull);
        expect(state.rideProposal, isNull);
        expect(state.activeRide, isNull);
        expect(state.activeRideBreakdown, isNull);
      },
    );
  }

  _continuityTest(
    'cancel RepositoryFailure preserves the pending request for retry',
    (time, rig) {
      rig.rides.records = [_ride(status: RideStatus.awaitingAcceptance)];
      rig.restore();
      final pending = state.myRideRequest;
      final failure = RepositoryFailure.offline();
      rig.rides.cancelFailure = failure;
      Object? caught;
      unawaited(
        state.cancelHostedRideRequest(reason: 'Changed plans').catchError((
          Object error,
        ) {
          caught = error;
        }),
      );
      time.flushMicrotasks();
      expect(caught, same(failure));
      expect(state.myRideRequest, same(pending));
      expect(state.liveRideRequest, same(pending));
      expect(pending!.status, RideStatus.awaitingAcceptance);
      expect(rig.rides.cancellations, [
        (id: 'ride-1', reason: 'Changed plans'),
      ]);
      rig.rides.cancelFailure = null;
      unawaited(state.cancelHostedRideRequest());
      time.flushMicrotasks();
      expect(state.liveRideRequest, isNull);
      expect(state.myRideRequest!.status, RideStatus.cancelled);
      expect(rig.rides.cancellations, hasLength(2));
    },
  );

  _continuityTest(
    'failed refresh preserves pending until a successful empty retry',
    (time, rig) {
      rig.rides.records = [_ride()];
      rig.restore();
      final pending = state.myRideRequest;
      final failure = RepositoryFailure.offline();
      rig.rides.read = (_) async => throw failure;
      rig.refresh();
      expect(state.passengerRideFailure, same(failure));
      expect(state.myRideRequest, same(pending));
      expect(state.liveRideRequest, same(pending));
      rig.rides.read = null;
      rig.rides.records = [];
      rig.refresh();
      expect(state.passengerRideFailure, isNull);
      expect(state.liveRideRequest, isNull);
    },
  );

  _continuityTest(
    'duplicate create calls coalesce and reuse the same live request',
    (time, rig) {
      rig.restore();
      final created = Completer<RideRecord>();
      rig.rides.create = () => created.future;
      final results = <RideRequestItem>[];
      for (var i = 0; i < 10; i++) {
        unawaited(state.createHostedRideRequest().then(results.add));
      }
      time.flushMicrotasks();
      expect(rig.rides.createCalls, 1);
      expect(results, isEmpty);
      created.complete(_ride());
      time.flushMicrotasks();
      expect(results, hasLength(10));
      expect(
        results.every((request) => identical(request, results.first)),
        isTrue,
      );
      expect(state.myRideRequest, same(results.first));
      unawaited(state.createHostedRideRequest().then(results.add));
      time.flushMicrotasks();
      expect(rig.rides.createCalls, 1);
      expect(results.last, same(results.first));
    },
  );

  _continuityTest(
    'creating while a refresh is pending rejects its pre-create empty result',
    (time, rig) {
      rig.restore();
      final stale = Completer<List<RideRecord>>();
      final created = _ride();
      var calls = 0;
      rig.rides.read = (_) =>
          ++calls == 1 ? stale.future : Future.value([created]);
      rig.refresh();
      unawaited(state.createHostedRideRequest());
      time.flushMicrotasks();
      final request = state.myRideRequest;
      expect(request, isNotNull);
      final observedIds = <String?>[];
      void observe() => observedIds.add(state.liveRideRequest?.id);
      state.addListener(observe);
      try {
        stale.complete([]);
        time.flushMicrotasks();
        expect(calls, 2);
        expect(state.liveRideRequest!.id, request!.id);
        expect(observedIds, isNotEmpty);
        expect(
          observedIds,
          everyElement('ride-1'),
          reason: 'a pre-create read cannot transiently clear the new request',
        );
      } finally {
        state.removeListener(observe);
      }
    },
  );

  for (final fails in [false, true]) {
    _continuityTest(
      'logout isolates a new identity from a late restore ${fails ? 'failure' : 'success'}',
      (time, rig) {
        final late = Completer<List<RideRecord>>();
        rig.rides.read = (passenger) => passenger == 'passenger-1'
            ? late.future
            : Future.value([_ride(id: 'ride-2', passenger: 'passenger-2')]);
        rig.restore();
        expect(state.passengerRideLoading, isTrue);
        final oldWatch = rig.realtime.watches.single;
        rig.logout();
        rig.identity('passenger-2');
        rig.restore();
        expect(state.liveRideRequest!.id, 'ride-2');
        expect(state.passengerRideLoading, isFalse);
        if (fails) {
          late.completeError(RepositoryFailure.offline());
        } else {
          late.complete([_ride(status: RideStatus.accepted)]);
        }
        oldWatch.events.add(null);
        oldWatch.events.addError(RepositoryFailure.offline());
        time.flushMicrotasks();
        expect(oldWatch.cancellations, 1);
        expect(state.liveRideRequest!.id, 'ride-2');
        expect(state.myRideRequest!.passengerId, 'passenger-2');
        expect(state.activeRide, isNull);
        expect(state.passengerRideFailure, isNull);
        expect(state.passengerRideLoading, isFalse);
        expect(rig.realtime.watches.map((watch) => watch.value), [
          'passenger-1',
          'passenger-2',
        ]);
      },
    );
  }

  _continuityTest(
    'a new identity does not coalesce creation with the disposed identity',
    (time, rig) {
      rig.restore();
      final oldCreate = Completer<RideRecord>();
      final newCreate = Completer<RideRecord>();
      rig.rides.create = () =>
          rig.rides.createCalls == 1 ? oldCreate.future : newCreate.future;
      Object? oldFailure;
      Object? newFailure;
      RideRequestItem? newResult;
      unawaited(
        state.createHostedRideRequest().then<void>(
          (_) {},
          onError: (Object error) {
            oldFailure = error;
          },
        ),
      );
      time.flushMicrotasks();
      rig.logout();
      rig.identity('passenger-2');
      rig.restore();
      unawaited(
        state.createHostedRideRequest().then<void>(
          (request) {
            newResult = request;
          },
          onError: (Object error) {
            newFailure = error;
          },
        ),
      );
      time.flushMicrotasks();
      final createsBeforeCompletion = rig.rides.createCalls;
      // Complete both before asserting so a failure cannot leave a singleton's
      // operation pending and contaminate the next test.
      oldCreate.complete(_ride());
      newCreate.complete(_ride(id: 'ride-2', passenger: 'passenger-2'));
      time.flushMicrotasks();
      expect(
        createsBeforeCompletion,
        2,
        reason: 'create coalescing is scoped to one authenticated ride session',
      );
      expect(
        oldFailure,
        isA<RepositoryFailure>().having(
          (failure) => failure.kind,
          'kind',
          RepositoryFailureKind.conflict,
        ),
      );
      expect(newFailure, isNull);
      expect(newResult!.id, 'ride-2');
      expect(state.liveRideRequest, same(newResult));
      expect(state.myRideRequest!.passengerId, 'passenger-2');
    },
  );
}
