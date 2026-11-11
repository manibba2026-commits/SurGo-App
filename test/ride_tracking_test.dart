import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_location_repository.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/services/ride_tracking.dart';

final _t0 = DateTime.utc(2026, 11, 6, 8);

Map<String, dynamic> _ride(
  String id, {
  String? rider = 'rider-1',
  String status = 'accepted',
}) => {
  'id': id,
  'passenger_id': 'passenger-1',
  'rider_id': rider,
  'service_area_id': 'area-1',
  'status': status,
  'pickup_address': 'Pickup',
  'dropoff_address': 'Dropoff',
};

Map<String, dynamic> _point({
  String id = 'point-1',
  String ride = 'ride-1',
  String? rider = 'rider-1',
  double latitude = 9.1036,
  double longitude = 126.1354,
  DateTime? at,
}) => {
  'id': id,
  'ride_id': ride,
  'rider_id': rider,
  'latitude': latitude,
  'longitude': longitude,
  'recorded_at': (at ?? _t0).toIso8601String(),
};

class _ReadBackend implements SurgoBackend {
  List<Map<String, dynamic>> points = [_point()];
  Map<String, dynamic>? presence;
  Future<Map<String, dynamic>?> Function(String)? readRide;
  Future<List<Map<String, dynamic>>> Function(String)? readPoints;
  final List<
    ({
      String table,
      Map<String, Object> eq,
      String? orderBy,
      bool ascending,
      int? limit,
    })
  >
  queries = [];
  final List<String> rideReads = [];

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    if (table == 'rider_presence') {
      expect(eq.keys, ['profile_id']);
      return presence;
    }
    expect(table, 'ride_requests');
    expect(eq.keys, ['id']);
    final id = eq['id']! as String;
    rideReads.add(id);
    return readRide == null ? _ride(id) : await readRide!(id);
  }

  @override
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async {
    queries.add((
      table: table,
      eq: eq,
      orderBy: orderBy,
      ascending: ascending,
      limit: limit,
    ));
    if (readPoints != null) return await readPoints!(eq['ride_id']! as String);
    final sorted =
        points.where((row) => row['ride_id'] == eq['ride_id']).toList()..sort(
          (a, b) => (b['recorded_at'] as String).compareTo(
            a['recorded_at'] as String,
          ),
        );
    return sorted.take(limit ?? sorted.length).toList();
  }
}

class _Watch {
  _Watch(this.table, this.column, this.value) {
    events = StreamController<void>(
      onCancel: () {
        cancelled++;
      },
    );
  }
  final String table;
  final String column;
  final String value;
  late final StreamController<void> events;
  int cancelled = 0;
}

class _Realtime implements SurgoRealtimeBackend {
  final List<_Watch> watches = [];
  bool throwOnWatch = false;

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    if (throwOnWatch) throw RepositoryFailure.permissionDenied();
    final watch = _Watch(table, column, value);
    watches.add(watch);
    return watch.events.stream;
  }

  void dispose() {
    for (final watch in watches) {
      unawaited(watch.events.close());
    }
  }
}

class _Rig {
  _Rig(this.time, {bool useRealtime = true}) {
    tracking = RideTracking(
      rides: SupabaseRideRepository(backend),
      locations: SupabaseRideLocationRepository(backend),
      realtime: useRealtime ? realtime : null,
      clock: () => now,
    );
  }
  final FakeAsync time;
  final _ReadBackend backend = _ReadBackend();
  final _Realtime realtime = _Realtime();
  late final RideTracking tracking;
  DateTime get now => _t0.add(time.elapsed);

  void start([String ride = 'ride-1', String rider = 'rider-1']) {
    tracking.start(ride, rider);
    time.flushMicrotasks();
  }

  void refresh() {
    unawaited(tracking.refresh());
    time.flushMicrotasks();
  }

  void emit(int index) {
    realtime.watches[index].events.add(null);
    time.flushMicrotasks();
  }

  void dispose() {
    tracking.dispose();
    realtime.dispose();
    time.flushMicrotasks();
    expect(time.periodicTimerCount, 0);
    expect(time.nonPeriodicTimerCount, 0);
  }
}

void _trackingTest(
  String name,
  void Function(FakeAsync, _Rig) body, {
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

// The transport double preserves the actual SDK subscription signatures.
class _Channel implements RealtimeChannel {
  String? schema;
  String? table;
  PostgresChangeFilter? filter;
  PostgresChangeEvent? event;
  void Function(RealtimeSubscribeStatus, Object?)? status;
  void Function(PostgresChangePayload)? changed;

  @override
  RealtimeChannel onPostgresChanges({
    required PostgresChangeEvent event,
    String? schema,
    String? table,
    PostgresChangeFilter? filter,
    List<PostgresChangeFilter>? filters,
    List<String>? select,
    required void Function(PostgresChangePayload) callback,
  }) {
    this.event = event;
    this.schema = schema;
    this.table = table;
    this.filter = filter;
    changed = callback;
    return this;
  }

  @override
  RealtimeChannel subscribe([
    void Function(RealtimeSubscribeStatus, Object?)? callback,
    Duration? timeout,
  ]) {
    status = callback;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements SupabaseClient {
  final List<_Channel> channels = [];
  final List<String> names = [];
  final List<RealtimeChannel> removed = [];

  @override
  RealtimeChannel channel(
    String name, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) {
    names.add(name);
    final channel = _Channel();
    channels.add(channel);
    return channel;
  }

  @override
  Future<String> removeChannel(RealtimeChannel channel) async {
    removed.add(channel);
    return 'ok';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rides implements RideRepository {
  _Rides(this.record);
  RideRecord? record;
  @override
  Future<RideRecord?> fetchRide(String rideId) async => record;
  @override
  Future<RiderPresenceRecord?> fetchPresence(String profileId) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Locations implements RideLocationRepository {
  _Locations(this.record);
  RideLocationRecord record;
  @override
  Future<List<RideLocationRecord>> fetchRecentPositions(
    String rideId, {
    int limit = 20,
  }) async {
    expect(limit, 1);
    return [record];
  }
}

void main() {
  group('realtime transport', () {
    test(
      'eq/public scope, subscribe/change signals, typed errors and cancellation',
      () async {
        final client = _Client();
        final backend = SupabaseBackend(client: client);
        var signals = 0;
        final errors = <Object>[];
        final subscription = backend
            .watchRows(
              table: 'ride_locations',
              column: 'ride_id',
              value: 'ride-1',
            )
            .listen(
              (_) {
                signals++;
              },
              onError: (Object error) {
                errors.add(error);
              },
            );
        final channel = client.channels.single;
        expect(channel.schema, 'public');
        expect(channel.table, 'ride_locations');
        expect(channel.event, PostgresChangeEvent.all);
        expect(channel.filter!.type, PostgresChangeFilterType.eq);
        expect(channel.filter!.column, 'ride_id');
        expect(channel.filter!.value, 'ride-1');
        expect(
          signals,
          0,
          reason: 'listening is not a subscription acknowledgement',
        );
        channel.status!(RealtimeSubscribeStatus.subscribed, null);
        channel.changed!(
          PostgresChangePayload(
            schema: 'public',
            table: 'ride_locations',
            commitTimestamp: _t0,
            eventType: PostgresChangeEvent.insert,
            newRecord: {'latitude': 0},
            oldRecord: {},
            errors: null,
          ),
        );
        channel.status!(
          RealtimeSubscribeStatus.channelError,
          RepositoryFailure.permissionDenied(),
        );
        channel.status!(RealtimeSubscribeStatus.timedOut, null);
        channel.status!(RealtimeSubscribeStatus.closed, null);
        await Future<void>.delayed(Duration.zero);
        expect(signals, 2);
        expect(errors.cast<RepositoryFailure>().map((error) => error.kind), [
          RepositoryFailureKind.permissionDenied,
          RepositoryFailureKind.offline,
          RepositoryFailureKind.unavailable,
        ]);
        channel.status!(RealtimeSubscribeStatus.subscribed, null);
        await Future<void>.delayed(Duration.zero);
        expect(
          signals,
          3,
          reason: 'rejoin refreshes even without a row change',
        );
        await subscription.cancel();
        expect(client.removed, [channel]);
        channel.status!(RealtimeSubscribeStatus.closed, null);
        await Future<void>.delayed(Duration.zero);
        expect(errors, hasLength(3));
      },
    );

    test(
      'watches own separate channels; empty scope gives a typed error',
      () async {
        final client = _Client();
        final backend = SupabaseBackend(client: client);
        final a = backend
            .watchRows(table: 'ride_requests', column: 'id', value: 'ride-1')
            .listen((_) {});
        final b = backend
            .watchRows(table: 'ride_requests', column: 'id', value: 'ride-1')
            .listen((_) {});
        expect(client.names.toSet(), hasLength(2));
        await a.cancel();
        expect(client.removed, [client.channels[0]]);
        await b.cancel();
        await expectLater(
          backend.watchRows(
            table: 'ride_locations',
            column: 'ride_id',
            value: '',
          ),
          emitsError(
            isA<RepositoryFailure>().having(
              (f) => f.kind,
              'kind',
              RepositoryFailureKind.invalidData,
            ),
          ),
        );
      },
    );
  });

  group('registry', () {
    test('read-only and mock stay compatible; realtime is optional', () {
      final backend = _ReadBackend();
      final readOnly = RepositoryRegistry.supabase(backend);
      expect(readOnly.rideLocations, isA<SupabaseRideLocationRepository>());
      expect(readOnly.realtime, isNull);
      final hostedBackend = SupabaseBackend(client: _Client());
      expect(
        RepositoryRegistry.supabase(hostedBackend).realtime,
        same(hostedBackend),
      );
      final mock = RepositoryRegistry.mock();
      expect(mock.rideLocations, isNull);
      expect(mock.realtime, isNull);
      final direct = RepositoryRegistry(
        profiles: mock.profiles,
        catalog: mock.catalog,
        vehicles: mock.vehicles,
        rides: mock.rides,
        rentals: mock.rentals,
        pasuyo: mock.pasuyo,
        notifications: mock.notifications,
        wallet: mock.wallet,
        verifications: mock.verifications,
        attachments: mock.attachments,
        isSupabaseBacked: false,
      );
      expect(direct.rideLocations, isNull);
      expect(direct.realtime, isNull);
    });
  });

  _trackingTest(
    'presence updates preserve simulated provenance without inventing trip GPS',
    (time, rig) {
      rig.backend.points = [];
      rig.backend.presence = {
        'profile_id': 'rider-1',
        'is_online': true,
        'is_available': false,
        'latitude': 9.10,
        'longitude': 126.13,
        'is_simulated': true,
        'source': 'demo',
        'updated_at': _t0.toIso8601String(),
      };
      rig.start();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.presence!.isSimulated, isTrue);
      rig.backend.presence!['longitude'] = 126.14;
      rig.emit(2);
      expect(rig.tracking.presence!.longitude, 126.14);
      expect(rig.tracking.position, isNull);
      rig.backend.presence!['is_online'] = false;
      rig.emit(2);
      expect(rig.tracking.presence, isNull);
    },
  );

  _trackingTest('newest DESC/limit 1 is read on all channel signals', (
    time,
    rig,
  ) {
    rig.backend.points = [
      _point(id: 'older', at: _t0.subtract(const Duration(seconds: 10))),
      _point(id: 'newest'),
    ];
    expect(rig.tracking.position, isNull);
    expect(rig.tracking.stale, isTrue);
    rig.start();
    expect(rig.tracking.position!.id, 'newest');
    expect(rig.tracking.latestRide!.id, 'ride-1');
    final query = rig.backend.queries.single;
    expect(query.table, 'ride_locations');
    expect(query.eq, {'ride_id': 'ride-1'});
    expect(query.orderBy, 'recorded_at');
    expect(query.ascending, isFalse);
    expect(query.limit, 1);
    expect(rig.realtime.watches.map((w) => (w.table, w.column, w.value)), [
      ('ride_locations', 'ride_id', 'ride-1'),
      ('ride_requests', 'id', 'ride-1'),
      ('rider_presence', 'profile_id', 'rider-1'),
    ]);
    expect(rig.tracking.realtimeConnected, isFalse);
    rig.emit(0);
    expect(rig.tracking.realtimeConnected, isFalse);
    rig.emit(1);
    expect(rig.tracking.realtimeConnected, isFalse);
    rig.emit(2);
    expect(rig.tracking.realtimeConnected, isTrue);
    time.elapse(const Duration(seconds: 1));
    rig.backend.points.add(_point(id: 'updated', at: rig.now));
    rig.emit(0);
    expect(rig.tracking.position!.id, 'updated');
    rig.backend.readRide = (id) async => _ride(id, status: 'completed');
    rig.emit(1);
    expect(rig.tracking.latestRide!.status.isTerminal, isTrue);
    expect(
      rig.realtime.watches.every((w) => w.cancelled == 0),
      isTrue,
      reason: 'Main, not the tracker, handles terminal state',
    );
  });

  _trackingTest(
    'empty trail never seeds a point; stale read is not an outage',
    (time, rig) {
      rig.backend.points.clear();
      rig.start();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.stale, isTrue);
      expect(rig.tracking.failure, isNull);
      rig.backend.points = [
        _point(at: _t0.subtract(const Duration(seconds: 46))),
      ];
      rig.refresh();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.stale, isTrue);
      expect(rig.tracking.failure, isNull);
    },
  );

  _trackingTest('45s boundary and expiry notify even while reads hang', (
    time,
    rig,
  ) {
    rig.start();
    var notifications = 0;
    rig.tracking.addListener(() {
      notifications++;
    });
    final blocked = Completer<Map<String, dynamic>?>();
    rig.backend.readRide = (_) => blocked.future;
    time.elapse(const Duration(seconds: 45));
    time.flushMicrotasks();
    expect(rig.tracking.stale, isFalse);
    final before = notifications;
    time.elapse(const Duration(microseconds: 1));
    time.flushMicrotasks();
    expect(rig.tracking.position, isNull);
    expect(rig.tracking.stale, isTrue);
    expect(notifications, greaterThan(before));
    blocked.complete(_ride('ride-1'));
    time.flushMicrotasks();
    rig.backend.points = [_point(id: 'resumed', at: rig.now)];
    rig.refresh();
    expect(rig.tracking.position!.id, 'resumed');
    expect(rig.tracking.stale, isFalse);
  });

  _trackingTest(
    'future skew accepts 15s, rejects beyond 15s and missing time',
    (time, rig) {
      rig.backend.points = [_point(at: _t0.add(const Duration(seconds: 15)))];
      rig.start();
      expect(rig.tracking.stale, isFalse);
      rig.backend.points = [_point(at: _t0.add(const Duration(seconds: 16)))];
      rig.refresh();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.failure!.kind, RepositoryFailureKind.invalidData);
      rig.backend.points = [_point()..['recorded_at'] = null];
      rig.refresh();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.failure!.kind, RepositoryFailureKind.invalidData);
    },
  );

  _trackingTest('record ride/rider mismatches cannot reuse a previous point', (
    time,
    rig,
  ) {
    rig.start();
    for (final bad in [
      _point(ride: 'ride-other'),
      _point(rider: 'rider-other'),
      _point(rider: null),
    ]) {
      rig.backend.readPoints = (_) async => [bad];
      rig.refresh();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.stale, isTrue);
      expect(rig.tracking.failure!.kind, RepositoryFailureKind.invalidData);
    }
  });

  _trackingTest('ride reassignment/unassignment/wrong id rejects trail reads', (
    time,
    rig,
  ) {
    rig.start();
    final locationReads = rig.backend.queries.length;
    for (final ride in [
      _ride('ride-1', rider: 'rider-other'),
      _ride('ride-1', rider: null),
      _ride('ride-other'),
    ]) {
      rig.backend.readRide = (_) async => ride;
      rig.refresh();
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.failure!.kind, RepositoryFailureKind.invalidData);
      expect(rig.backend.queries, hasLength(locationReads));
    }
    rig.backend.readRide = (_) async => null;
    rig.refresh();
    expect(rig.tracking.latestRide, isNull);
    expect(rig.tracking.failure!.kind, RepositoryFailureKind.notFound);
  });

  test(
    'fake repositories reject invalid/nonfinite/null-island coordinates',
    () {
      fakeAsync((time) {
        final rides = _Rides(RideRecord.fromRow(_ride('ride-1')));
        final locations = _Locations(RideLocationRecord.fromRow(_point()));
        final tracking = RideTracking(
          rides: rides,
          locations: locations,
          clock: () => _t0,
        );
        try {
          tracking.start('ride-1', 'rider-1');
          time.flushMicrotasks();
          expect(tracking.stale, isFalse);
          for (final coordinates in [
            (0.0, 0.0),
            (91.0, 126.0),
            (-91.0, 126.0),
            (9.0, 181.0),
            (9.0, -181.0),
            (double.nan, 126.0),
            (9.0, double.infinity),
          ]) {
            locations.record = RideLocationRecord(
              id: 'bad',
              rideId: 'ride-1',
              riderId: 'rider-1',
              latitude: coordinates.$1,
              longitude: coordinates.$2,
              recordedAt: _t0,
            );
            unawaited(tracking.refresh());
            time.flushMicrotasks();
            expect(tracking.position, isNull);
            expect(tracking.failure!.kind, RepositoryFailureKind.invalidData);
          }
        } finally {
          tracking.dispose();
        }
        expect(time.periodicTimerCount, 0);
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  _trackingTest('no realtime still reconciles every 15s', (time, rig) {
    rig.start();
    rig.backend.points = [
      _point(id: 'polled', at: _t0.add(const Duration(seconds: 15))),
    ];
    time.elapse(const Duration(seconds: 14));
    time.flushMicrotasks();
    expect(rig.backend.rideReads, hasLength(1));
    time.elapse(const Duration(seconds: 1));
    time.flushMicrotasks();
    expect(rig.tracking.position!.id, 'polled');
    expect(rig.backend.rideReads, hasLength(2));
    expect(rig.tracking.realtimeConnected, isFalse);
    expect(rig.tracking.failure, isNull);
  }, useRealtime: false);

  _trackingTest(
    'channel errors persist through polls and clear only on reconnect',
    (time, rig) {
      rig.start();
      rig.emit(0);
      rig.emit(1);
      rig.emit(2);
      final failure = RepositoryFailure.offline();
      rig.realtime.watches[0].events.addError(failure);
      time.flushMicrotasks();
      expect(rig.tracking.realtimeConnected, isFalse);
      expect(rig.tracking.failure, same(failure));
      rig.backend.points = [
        _point(id: 'polled', at: _t0.add(const Duration(seconds: 15))),
      ];
      final before = rig.backend.rideReads.length;
      time.elapse(const Duration(seconds: 15));
      time.flushMicrotasks();
      expect(rig.backend.rideReads.length, greaterThan(before));
      expect(rig.tracking.position!.id, 'polled');
      expect(rig.tracking.realtimeConnected, isFalse);
      expect(rig.tracking.failure, same(failure));
      rig.emit(1);
      expect(rig.tracking.realtimeConnected, isFalse);
      rig.emit(0);
      expect(rig.tracking.realtimeConnected, isTrue);
      expect(rig.tracking.failure, isNull);
      unawaited(rig.realtime.watches[1].events.close());
      time.flushMicrotasks();
      expect(rig.tracking.realtimeConnected, isFalse);
      expect(rig.tracking.failure!.kind, RepositoryFailureKind.unavailable);
    },
  );

  _trackingTest('synchronous watch failure is typed and polling survives', (
    time,
    rig,
  ) {
    rig.realtime.throwOnWatch = true;
    rig.start();
    expect(rig.tracking.failure!.kind, RepositoryFailureKind.permissionDenied);
    expect(rig.tracking.realtimeConnected, isFalse);
    time.elapse(const Duration(seconds: 15));
    time.flushMicrotasks();
    expect(rig.backend.rideReads, hasLength(2));
    expect(rig.tracking.position, isNotNull);
    expect(rig.tracking.failure!.kind, RepositoryFailureKind.permissionDenied);
  });

  _trackingTest('read failures are typed and the next poll recovers', (
    time,
    rig,
  ) {
    rig.backend.readRide = (_) async => throw RepositoryFailure.offline();
    rig.start();
    expect(rig.tracking.position, isNull);
    expect(rig.tracking.failure!.kind, RepositoryFailureKind.offline);
    rig.backend.readRide = null;
    time.elapse(const Duration(seconds: 15));
    time.flushMicrotasks();
    expect(rig.tracking.failure, isNull);
    expect(rig.tracking.position, isNotNull);
    rig.backend.readPoints = (_) async =>
        throw RepositoryFailure.permissionDenied();
    rig.refresh();
    expect(rig.tracking.position, isNull);
    expect(rig.tracking.failure!.kind, RepositoryFailureKind.permissionDenied);
  }, useRealtime: false);

  _trackingTest('bursts coalesce behind one in-flight read, without overlap', (
    time,
    rig,
  ) {
    final first = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    rig.backend.readPoints = (_) {
      calls++;
      return calls == 1
          ? first.future
          : Future.value([_point(id: 'follow-up', at: rig.now)]);
    };
    rig.start();
    for (var i = 0; i < 20; i++) {
      rig.realtime.watches[i % 2].events.add(null);
      unawaited(rig.tracking.refresh());
    }
    time.flushMicrotasks();
    time.elapse(const Duration(seconds: 15));
    time.flushMicrotasks();
    expect(calls, 1);
    first.complete([_point(id: 'first')]);
    time.flushMicrotasks();
    expect(
      calls,
      2,
      reason: 'one follow-up handles the whole invalidation burst',
    );
    expect(rig.tracking.position!.id, 'follow-up');
  });

  _trackingTest(
    'switch rejects late position results and clears/cancels old session',
    (time, rig) {
      rig.start();
      final late = Completer<List<Map<String, dynamic>>>();
      rig.backend.readPoints = (id) => id == 'ride-1'
          ? late.future
          : Future.value([_point(id: 'trip-2', ride: 'ride-2')]);
      rig.refresh();
      rig.tracking.start('ride-2', 'rider-1');
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.latestRide, isNull);
      expect(rig.tracking.realtimeConnected, isFalse);
      time.flushMicrotasks();
      expect(
        rig.realtime.watches.take(3).every((w) => w.cancelled == 1),
        isTrue,
      );
      expect(rig.tracking.position!.id, 'trip-2');
      late.complete([_point(id: 'late-old-trip')]);
      rig.realtime.watches[0].events.addError(RepositoryFailure.offline());
      time.flushMicrotasks();
      expect(rig.tracking.position!.id, 'trip-2');
      expect(rig.tracking.latestRide!.id, 'ride-2');
      expect(rig.tracking.failure, isNull);
      rig.tracking.stop();
      time.flushMicrotasks();
      expect(rig.realtime.watches.every((w) => w.cancelled == 1), isTrue);
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.latestRide, isNull);
      final reads = rig.backend.rideReads.length;
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(rig.backend.rideReads, hasLength(reads));
    },
  );

  _trackingTest('late ride completion cannot even initiate an old trail read', (
    time,
    rig,
  ) {
    final late = Completer<Map<String, dynamic>?>();
    rig.backend.readRide = (id) =>
        id == 'ride-1' ? late.future : Future.value(_ride(id));
    rig.start();
    rig.backend.points = [_point(ride: 'ride-2')];
    rig.start('ride-2');
    final trailReads = rig.backend.queries.length;
    late.complete(_ride('ride-1'));
    time.flushMicrotasks();
    expect(rig.backend.queries, hasLength(trailReads));
    expect(rig.tracking.latestRide!.id, 'ride-2');
    expect(rig.tracking.position!.rideId, 'ride-2');
  });

  _trackingTest(
    'same ride/new rider is a new generation, including late errors',
    (time, rig) {
      final late = Completer<Map<String, dynamic>?>();
      rig.backend.readRide = (_) => late.future;
      rig.start();
      rig.backend.readRide = (id) async => _ride(id, rider: 'rider-2');
      rig.backend.points = [_point(rider: 'rider-2')];
      rig.start('ride-1', 'rider-2');
      late.completeError(RepositoryFailure.offline());
      time.flushMicrotasks();
      expect(rig.tracking.failure, isNull);
      expect(rig.tracking.position!.riderId, 'rider-2');
      expect(
        rig.realtime.watches.take(3).every((w) => w.cancelled == 1),
        isTrue,
      );
    },
  );

  _trackingTest(
    'dispose rejects late reads/events and removes all timers/listeners',
    (time, rig) {
      final late = Completer<List<Map<String, dynamic>>>();
      rig.backend.readPoints = (_) => late.future;
      rig.start();
      var notifications = 0;
      rig.tracking.addListener(() {
        notifications++;
      });
      rig.tracking.dispose();
      late.completeError(RepositoryFailure.offline());
      rig.realtime.watches[0].events.add(null);
      time.flushMicrotasks();
      final reads = rig.backend.rideReads.length;
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      rig.tracking.start('ride-2', 'rider-2');
      rig.refresh();
      expect(notifications, 0);
      expect(rig.tracking.position, isNull);
      expect(rig.tracking.latestRide, isNull);
      expect(rig.tracking.failure, isNull);
      expect(rig.tracking.realtimeConnected, isFalse);
      expect(rig.backend.rideReads, hasLength(reads));
      expect(rig.realtime.watches.every((w) => w.cancelled == 1), isTrue);
    },
  );
}
