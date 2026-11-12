import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/services/passenger_ride_session.dart';
import 'package:surgo/state/ride_status.dart';

const _passenger = 'passenger-1';

RideRequestItem _request({
  String id = 'ride-1',
  String passenger = _passenger,
  RideStatus status = RideStatus.searching,
}) => RideRequestItem(
  id: id,
  passengerId: passenger,
  riderId: status == RideStatus.searching ? null : 'rider-1',
  vehicleId: 'vehicle-1',
  passengerName: 'Test Passenger',
  passengerInitials: 'TP',
  passengerRating: 4.75,
  pickupBarangay: 'Poblacion',
  pickupPurok: 'Purok 3',
  pickup: 'Pickup, Poblacion',
  pickupLatitude: 9.1036,
  pickupLongitude: 126.1354,
  dropoffBarangay: 'San Isidro',
  dropoffPurok: 'Purok 2',
  dropoff: 'Dropoff, San Isidro',
  dropoffLatitude: 9.12,
  dropoffLongitude: 126.14,
  distanceKm: 3.25,
  etaMinutes: 9,
  fare: 18765,
  platformFeeCentavos: 731,
  riderName: 'Test Rider',
  paymentMethod: 'Cash',
  note: 'Booking for someone else',
  requestedAt: 'Just now',
  requestedAtIso: DateTime.utc(2026, 11, 6, 8, 9, 10),
  status: status,
);

RideRecord _record({
  String id = 'ride-1',
  String? passenger = _passenger,
  RideStatus status = RideStatus.searching,
}) => RideRecord(
  id: id,
  passengerId: passenger,
  riderId: status == RideStatus.searching ? null : 'rider-1',
  serviceAreaId: 'area-1',
  status: status,
  pickupAddress: 'Pickup',
  dropoffAddress: 'Dropoff',
  fareCentavos: 18765,
  platformFeeCentavos: 731,
);

class _Rides extends MockRideRepository {
  List<RideRecord> records = [];
  Future<List<RideRecord>> Function()? read;
  final queries = <({String passenger, int? limit})>[];
  int historyReads = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<List<RideRecord>> fetchRidesForPassenger(
    String passengerId, {
    int? limit,
  }) async {
    queries.add((passenger: passengerId, limit: limit));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final result = read == null
          ? List<RideRecord>.of(records)
          : await read!();
      return limit == null ? result : result.take(limit).toList();
    } finally {
      inFlight--;
    }
  }

  @override
  Future<List<RideRecord>> fetchRideHistory(
    String passengerId, {
    int? limit,
  }) async {
    historyReads++;
    throw StateError('Continuity must read all passenger rides, not history.');
  }
}

class _Watch {
  _Watch(this.table, this.column, this.value) {
    events = StreamController<void>(onCancel: () => cancellations++);
  }

  final String table;
  final String column;
  final String value;
  late final StreamController<void> events;
  int cancellations = 0;
}

class _Realtime implements SurgoRealtimeBackend {
  final watches = <_Watch>[];
  RepositoryFailure? watchFailure;

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    if (watchFailure != null) throw watchFailure!;
    final watch = _Watch(table, column, value);
    watches.add(watch);
    return watch.events.stream;
  }

  void close() {
    for (final watch in watches) {
      unawaited(watch.events.close());
    }
  }
}

class _Rig {
  _Rig(this.time, {bool useRealtime = true}) {
    session = PassengerRideSession(
      rides: rides,
      profileId: _passenger,
      realtime: useRealtime ? realtime : null,
      onChanged: (ride, failure) => changes.add((ride: ride, failure: failure)),
    );
  }

  final FakeAsync time;
  final rides = _Rides();
  final realtime = _Realtime();
  final changes = <({RideRecord? ride, RepositoryFailure? failure})>[];
  late final PassengerRideSession session;

  void refresh() {
    unawaited(session.refresh());
    time.flushMicrotasks();
  }

  void emit() {
    realtime.watches.single.events.add(null);
    time.flushMicrotasks();
  }

  void dispose() {
    session.stop();
    realtime.close();
    time.flushMicrotasks();
    expect(time.periodicTimerCount, 0);
    expect(time.nonPeriodicTimerCount, 0);
  }
}

void _sessionTest(
  String name,
  void Function(FakeAsync time, _Rig rig) body, {
  bool useRealtime = true,
}) {
  test(name, () {
    fakeAsync((time) {
      final rig = _Rig(time, useRealtime: useRealtime);
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

  group('SharedPreferencesDemoRideRequestStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    for (final status in RideStatus.values.where((s) => !s.isTerminal)) {
      test(
        'restores ${status.wireValue} with every stored field intact',
        () async {
          final original = _request(status: status);
          await SharedPreferencesDemoRideRequestStore().write(
            _passenger,
            original,
          );

          // A fresh store represents restarting the application.
          final restored = await SharedPreferencesDemoRideRequestStore().read(
            _passenger,
          );
          expect(restored, isNotNull);
          expect(restored, isNot(same(original)));
          expect(restored!.toJson(), original.toJson());
          expect(restored.requestedAtIso, DateTime.utc(2026, 11, 6, 8, 9, 10));
          expect(restored.platformFeeCentavos, 731);
          final preferences = await SharedPreferences.getInstance();
          expect(
            jsonDecode(preferences.getString('surgo.demo.ride.$_passenger')!),
            original.toJson(),
          );
        },
      );
    }

    test('accounts restore and remove only their own request', () async {
      final store = SharedPreferencesDemoRideRequestStore();
      final first = _request();
      final second = _request(
        id: 'ride-2',
        passenger: 'passenger-2',
        status: RideStatus.inProgress,
      );
      await store.write(_passenger, first);
      await store.write('passenger-2', second);
      expect((await store.read(_passenger))!.toJson(), first.toJson());
      expect((await store.read('passenger-2'))!.toJson(), second.toJson());
      expect(await store.read('passenger-3'), isNull);

      await store.write(_passenger, null);
      expect(await store.read(_passenger), isNull);
      expect((await store.read('passenger-2'))!.toJson(), second.toJson());
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('surgo.demo.ride.$_passenger'), isFalse);
      expect(preferences.containsKey('surgo.demo.ride.passenger-2'), isTrue);
    });

    for (final status in [RideStatus.completed, RideStatus.cancelled]) {
      test('${status.wireValue} cannot restore as a live request', () async {
        final store = SharedPreferencesDemoRideRequestStore();
        await store.write(_passenger, _request(status: status));
        expect(
          await SharedPreferencesDemoRideRequestStore().read(_passenger),
          isNull,
        );
        await store.write(_passenger, null);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.containsKey('surgo.demo.ride.$_passenger'), isFalse);
      });
    }

    test('a foreign passenger in an account key is not restored', () async {
      SharedPreferences.setMockInitialValues({
        'surgo.demo.ride.$_passenger': jsonEncode(
          _request(passenger: 'passenger-2').toJson(),
        ),
      });
      expect(
        await SharedPreferencesDemoRideRequestStore().read(_passenger),
        isNull,
      );
    });

    for (final invalid in ['{broken', '[]', '{"id":"incomplete"}']) {
      test(
        'corrupt stored value $invalid is removed without leaking accounts',
        () async {
          final valid = _request(passenger: 'passenger-2');
          SharedPreferences.setMockInitialValues({
            'surgo.demo.ride.$_passenger': invalid,
            'surgo.demo.ride.passenger-2': jsonEncode(valid.toJson()),
          });
          final store = SharedPreferencesDemoRideRequestStore();
          expect(await store.read(_passenger), isNull);
          final preferences = await SharedPreferences.getInstance();
          expect(
            preferences.containsKey('surgo.demo.ride.$_passenger'),
            isFalse,
          );
          expect((await store.read('passenger-2'))!.toJson(), valid.toJson());
        },
      );
    }

    test(
      'queued writes snapshot mutable requests and reads await the queue',
      () async {
        final store = SharedPreferencesDemoRideRequestStore();
        final request = _request();
        final first = store.write(_passenger, request);
        request.status = RideStatus.awaitingAcceptance;
        request.riderId = 'rider-1';
        final second = store.write(_passenger, request);
        final finalSnapshot = Map<String, dynamic>.of(request.toJson());
        request.status = RideStatus.completed;
        request.riderId = 'later-mutation';

        final restored = await store.read(_passenger);
        await Future.wait([first, second]);
        expect(restored!.toJson(), finalSnapshot);
        final remove = store.write(_passenger, null);
        expect(await store.read(_passenger), isNull);
        await remove;
      },
    );
  });

  group('PassengerRideSession', () {
    _sessionTest('Realtime invalidates only the scoped passenger query', (
      time,
      rig,
    ) {
      rig.rides.records = [_record()];
      rig.session.start();
      rig.refresh();
      expect(rig.realtime.watches, hasLength(1));
      final watch = rig.realtime.watches.single;
      expect(
        (watch.table, watch.column, watch.value),
        ('ride_requests', 'passenger_id', _passenger),
      );
      expect(rig.changes.single.ride!.status, RideStatus.searching);
      final before = rig.rides.queries.length;
      rig.rides.records = [_record(status: RideStatus.accepted)];
      rig.emit();
      expect(rig.rides.queries, hasLength(before + 1));
      expect(rig.changes.last.ride!.status, RideStatus.accepted);
      expect(rig.changes.last.failure, isNull);
      expect(rig.rides.queries.every((q) => q.passenger == _passenger), isTrue);
    });

    for (final useRealtime in [true, false]) {
      _sessionTest('polls at 15s with Realtime=$useRealtime', (time, rig) {
        rig.rides.records = [_record()];
        rig.session.start();
        rig.refresh();
        final before = rig.rides.queries.length;
        rig.rides.records = [_record(status: RideStatus.awaitingAcceptance)];
        time.elapse(const Duration(seconds: 14, milliseconds: 999));
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(before));
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(before + 1));
        expect(rig.changes.last.ride!.status, RideStatus.awaitingAcceptance);
        rig.rides.records = [_record(status: RideStatus.inProgress)];
        time.elapse(const Duration(seconds: 15));
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(before + 2));
        expect(rig.changes.last.ride!.status, RideStatus.inProgress);
      }, useRealtime: useRealtime);
    }

    _sessionTest(
      'does not limit to recent history and finds an older live ride',
      (time, rig) {
        rig.rides.records = [
          for (var i = 0; i < 100; i++)
            _record(id: 'history-$i', status: RideStatus.completed),
          _record(id: 'older-live', status: RideStatus.awaitingAcceptance),
        ];
        rig.refresh();
        expect(rig.rides.queries.single, (passenger: _passenger, limit: null));
        expect(rig.rides.historyReads, 0);
        expect(rig.changes.single.ride!.id, 'older-live');
      },
    );

    _sessionTest(
      'ignores foreign and unowned rows, including a matching ride id',
      (time, rig) {
        rig.session.recordWrite(_record());
        rig.rides.records = [
          _record(passenger: 'passenger-2', status: RideStatus.completed),
          _record(id: 'foreign-live', passenger: 'passenger-2'),
          _record(id: 'missing-passenger', passenger: null),
          _record(id: 'owned', status: RideStatus.accepted),
        ];
        rig.refresh();
        expect(rig.changes.single.ride!.id, 'owned');
        rig.rides.records = [
          _record(
            id: 'owned',
            passenger: 'passenger-2',
            status: RideStatus.completed,
          ),
          _record(id: 'foreign-live', passenger: 'passenger-2'),
        ];
        rig.refresh();
        expect(rig.changes.last, (ride: null, failure: null));
      },
    );

    _sessionTest('a successful empty read clears a previous read failure', (
      time,
      rig,
    ) {
      final failure = RepositoryFailure.offline();
      rig.rides.read = () async => throw failure;
      rig.refresh();
      expect(rig.changes.single, (ride: null, failure: failure));
      rig.rides.read = null;
      rig.refresh();
      expect(rig.changes.last, (ride: null, failure: null));
      expect(rig.changes, hasLength(2));
    });

    _sessionTest(
      'successful empty read invalidates a previously live request',
      (time, rig) {
        rig.rides.records = [_record()];
        rig.refresh();
        rig.rides.records = [];
        rig.refresh();
        expect(rig.changes, hasLength(2));
        expect(rig.changes.last, (ride: null, failure: null));
      },
    );

    for (final status in [RideStatus.completed, RideStatus.cancelled]) {
      _sessionTest(
        'delivers tracked ${status.wireValue}, not unrelated history',
        (time, rig) {
          rig.rides.records = [_record()];
          rig.refresh();
          final terminal = _record(status: status);
          rig.rides.records = [
            _record(id: 'unrelated-history', status: RideStatus.completed),
            terminal,
          ];
          rig.refresh();
          expect(rig.changes.last.ride, same(terminal));
          expect(rig.changes.last.failure, isNull);
          rig.refresh();
          expect(rig.changes.last, (ride: null, failure: null));
        },
      );
    }

    _sessionTest(
      'recordWrite tracks a terminal result even before the first read',
      (time, rig) {
        final terminal = _record(status: RideStatus.cancelled);
        rig.session.recordWrite(terminal);
        rig.rides.records = [terminal];
        rig.refresh();
        expect(rig.changes.single.ride, same(terminal));
      },
    );

    _sessionTest('a new live ride wins over the previous terminal request', (
      time,
      rig,
    ) {
      rig.session.recordWrite(_record());
      final live = _record(id: 'new-request');
      rig.rides.records = [_record(status: RideStatus.completed), live];
      rig.refresh();
      expect(rig.changes.single.ride, same(live));
    });

    _sessionTest(
      'recordWrite rejects a pending pre-write read and rereads without another signal',
      (time, rig) {
        final stale = Completer<List<RideRecord>>();
        final fresh = _record(status: RideStatus.accepted);
        rig.rides.read = () => rig.rides.queries.length == 1
            ? stale.future
            : Future.value([fresh]);
        rig.refresh();
        expect(rig.rides.queries, hasLength(1));
        rig.session.recordWrite(fresh);
        stale.complete([_record()]);
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(2));
        expect(rig.rides.maxInFlight, 1);
        expect(
          rig.changes,
          hasLength(1),
          reason: 'pre-write searching must never replace acceptance',
        );
        expect(rig.changes.single, (ride: fresh, failure: null));
      },
    );

    _sessionTest(
      'recordWrite rejects a stale failed read and retries immediately',
      (time, rig) {
        final stale = Completer<List<RideRecord>>();
        final fresh = _record(status: RideStatus.accepted);
        rig.rides.read = () => rig.rides.queries.length == 1
            ? stale.future
            : Future.value([fresh]);
        rig.refresh();
        rig.session.recordWrite(fresh);
        stale.completeError(RepositoryFailure.offline());
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(2));
        expect(rig.rides.maxInFlight, 1);
        expect(
          rig.changes,
          [(ride: fresh, failure: null)],
          reason: 'an obsolete read failure is not the current session failure',
        );
      },
    );

    _sessionTest(
      'multiple write revisions during a read still serialize one fresh reread',
      (time, rig) {
        final stale = Completer<List<RideRecord>>();
        final accepted = _record(status: RideStatus.accepted);
        final terminal = _record(status: RideStatus.cancelled);
        rig.rides.read = () => rig.rides.queries.length == 1
            ? stale.future
            : Future.value([terminal]);
        rig.refresh();
        rig.session.recordWrite(accepted);
        rig.session.recordWrite(terminal);
        stale.complete([accepted]);
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(2));
        expect(rig.changes, [(ride: terminal, failure: null)]);
        expect(rig.rides.maxInFlight, 1);
      },
    );

    _sessionTest(
      'manual, Realtime and poll bursts coalesce behind a single read',
      (time, rig) {
        final first = Completer<List<RideRecord>>();
        final second = Completer<List<RideRecord>>();
        rig.rides.read = () =>
            rig.rides.queries.length == 1 ? first.future : second.future;
        rig.session.start();
        final drained = rig.session.refresh();
        var finished = false;
        unawaited(drained.then((_) => finished = true));
        for (var i = 0; i < 20; i++) {
          unawaited(rig.session.refresh());
          rig.realtime.watches.single.events.add(null);
        }
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 15));
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(1));
        expect(rig.rides.maxInFlight, 1);
        expect(finished, isFalse);
        first.complete([_record()]);
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(2));
        expect(
          finished,
          isFalse,
          reason: 'refresh completes only after queued invalidations drain',
        );
        second.complete([_record(status: RideStatus.accepted)]);
        time.flushMicrotasks();
        expect(finished, isTrue);
        expect(rig.rides.queries, hasLength(2));
        expect(rig.rides.maxInFlight, 1);
        expect(rig.changes.last.ride!.status, RideStatus.accepted);
      },
    );

    _sessionTest(
      'current failure maps to offline and the next poll recovers',
      (time, rig) {
        rig.rides.read = () async => throw TimeoutException('blocked read');
        rig.session.start();
        rig.refresh();
        expect(rig.changes.single.ride, isNull);
        expect(rig.changes.single.failure!.kind, RepositoryFailureKind.offline);
        rig.rides.read = null;
        rig.rides.records = [_record(status: RideStatus.accepted)];
        time.elapse(const Duration(seconds: 15));
        time.flushMicrotasks();
        expect(rig.changes.last.ride!.status, RideStatus.accepted);
        expect(rig.changes.last.failure, isNull);
      },
      useRealtime: false,
    );

    _sessionTest(
      'Realtime errors invalidate reads and reconnection reads again',
      (time, rig) {
        rig.session.start();
        rig.refresh();
        final before = rig.rides.queries.length;
        rig.rides.records = [_record(status: RideStatus.accepted)];
        rig.realtime.watches.single.events.addError(
          RepositoryFailure.offline(),
        );
        time.flushMicrotasks();
        expect(rig.rides.queries, hasLength(before + 1));
        expect(rig.changes.last.ride!.status, RideStatus.accepted);
        rig.rides.records = [_record(status: RideStatus.inProgress)];
        rig.emit();
        expect(rig.rides.queries, hasLength(before + 2));
        expect(rig.changes.last.ride!.status, RideStatus.inProgress);
      },
    );

    _sessionTest(
      'synchronous subscription failure is typed and polling survives',
      (time, rig) {
        final failure = RepositoryFailure.permissionDenied();
        rig.realtime.watchFailure = failure;
        rig.session.start();
        expect(rig.changes, [(ride: null, failure: failure)]);
        rig.rides.records = [_record()];
        time.elapse(const Duration(seconds: 15));
        time.flushMicrotasks();
        expect(rig.changes.last.ride!.id, 'ride-1');
        expect(rig.changes.last.failure, isNull);
      },
    );

    for (final fails in [false, true]) {
      _sessionTest(
        'stop ignores late ${fails ? 'failure' : 'success'}, queued reads and events',
        (time, rig) {
          final late = Completer<List<RideRecord>>();
          rig.rides.read = () => late.future;
          rig.session.start();
          rig.refresh();
          rig.emit();
          unawaited(rig.session.refresh());
          rig.session.stop();
          rig.session.stop();
          if (fails) {
            late.completeError(RepositoryFailure.offline());
          } else {
            late.complete([_record(status: RideStatus.accepted)]);
          }
          rig.realtime.watches.single.events.add(null);
          rig.realtime.watches.single.events.addError(
            RepositoryFailure.offline(),
          );
          time.flushMicrotasks();
          time.elapse(const Duration(minutes: 1));
          rig.refresh();
          expect(rig.changes, isEmpty);
          expect(rig.rides.queries, hasLength(1));
          expect(rig.realtime.watches.single.cancellations, 1);
          expect(time.periodicTimerCount, 0);
        },
      );
    }
  });
}
