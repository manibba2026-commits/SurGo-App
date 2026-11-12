import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/services/notification_session.dart';
import 'package:surgo/state/domain_cache.dart';

const _profile = '11111111-1111-1111-1111-111111111111';
const _slots = [
  DomainSlot.unreadPassengerNotifications,
  DomainSlot.unreadEarnerNotifications,
  DomainSlot.passengerNotificationFeed,
  DomainSlot.earnerNotificationFeed,
];

class _Backend implements SurgoBackend, RowRealtimeBackend {
  final queries =
      <
        ({
          String table,
          String columns,
          Map<String, Object> eq,
          List<String> whereNull,
          String? orderBy,
          int? limit,
        })
      >[];
  final watches = <({String table, String column, String value})>[];
  final parked = <Completer<List<Map<String, dynamic>>>>[];
  late final events = StreamController<void>(
    onCancel: () async {
      cancellations++;
      if (cancelFails) throw StateError('cancel unavailable');
    },
  );
  bool gated = false;
  bool watchFails = false;
  bool cancelFails = false;
  int cancellations = 0;
  int active = 0;
  int maxActive = 0;
  Object? readError;
  List<Map<String, dynamic>> records = [
    {
      'id': 'n1',
      'notification_type': 'ride',
      'title': 'Assigned',
      'body': 'Your rider accepted.',
      'read_at': null,
    },
  ];

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    if (watchFails) throw RepositoryFailure.unavailable();
    watches.add((table: table, column: column, value: value));
    return events.stream;
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
      columns: columns,
      eq: Map.of(eq),
      whereNull: List.of(whereNull),
      orderBy: orderBy,
      limit: limit,
    ));
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (gated) {
        final done = Completer<List<Map<String, dynamic>>>();
        parked.add(done);
        return await done.future;
      }
      if (readError != null) throw readError!;
      return records;
    } finally {
      active--;
    }
  }

  void release({Object? error}) {
    final done = parked.removeAt(0);
    if (error != null) {
      done.completeError(error);
    } else {
      done.complete(records);
    }
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async => throw StateError('Notifications must only SELECT rows.');
}

void _sessionTest(
  String name,
  void Function(
    FakeAsync time,
    _Backend backend,
    DomainCache cache,
    NotificationSession session,
  )
  body, {
  bool realtime = true,
}) {
  test(
    name,
    () => fakeAsync((time) {
      final backend = _Backend();
      final registry = RepositoryRegistry.supabase(backend);
      final cache = DomainCache(
        registry: () => registry,
        profileKey: () => _profile,
        seedProfileKey: (_) => 'never-seed',
      );
      final session = NotificationSession(
        cache: cache,
        profileId: _profile,
        realtime: realtime ? backend : null,
      );
      try {
        body(time, backend, cache, session);
      } finally {
        session.stop();
        cache.dispose();
        while (backend.parked.isNotEmpty) {
          backend.release(error: RepositoryFailure.offline());
        }
        unawaited(backend.events.close());
        time.flushMicrotasks();
        expect(time.periodicTimerCount, 0);
        expect(time.nonPeriodicTimerCount, 0);
      }
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _sessionTest('uses exact authenticated filter; invalidates all four slots', (
    time,
    backend,
    cache,
    session,
  ) {
    session.start();
    session.start();
    expect(backend.watches.single, (
      table: 'notifications',
      column: 'profile_id',
      value: _profile,
    ));
    expect(time.periodicTimerCount, 1);
    backend.events.add(null);
    time.flushMicrotasks();
    expect(backend.queries, hasLength(4));
    for (final query in backend.queries) {
      expect(query.table, 'notifications');
      expect(query.eq, {'profile_id': _profile});
      expect(query.limit, isNull);
    }
    expect(
      backend.queries
          .take(2)
          .every((q) => q.columns == 'id' && q.whereNull.single == 'read_at'),
      isTrue,
    );
    expect(
      backend.queries
          .skip(2)
          .every((q) => q.orderBy == 'created_at' && q.whereNull.isEmpty),
      isTrue,
    );
    for (final slot in _slots.take(2)) {
      expect(cache.dataOf<int>(slot), 1);
    }
    for (final slot in _slots.skip(2)) {
      expect(
        cache.dataOf<List<NotificationRecord>>(slot)!.single.title,
        'Assigned',
      );
    }
    expect(backend.maxActive, 1);
  });

  for (final realtime in [false, true]) {
    _sessionTest('15-second reconciliation with realtime=$realtime', (
      time,
      backend,
      cache,
      session,
    ) {
      session.start();
      time.elapse(const Duration(seconds: 14, milliseconds: 999));
      expect(backend.queries, isEmpty);
      time.elapse(const Duration(milliseconds: 1));
      time.flushMicrotasks();
      expect(backend.queries, hasLength(4));
      backend.records = [];
      time.elapse(const Duration(seconds: 15));
      time.flushMicrotasks();
      expect(backend.queries, hasLength(8));
      expect(cache.dataOf<int>(_slots.first), 0);
      expect(
        cache.stateOf<List<NotificationRecord>>(_slots.last).isEmpty,
        isTrue,
      );
    }, realtime: realtime);
  }

  _sessionTest('manual, realtime and poll bursts share one serialized drain', (
    time,
    backend,
    cache,
    session,
  ) {
    backend.gated = true;
    session.start();
    final refresh = session.refresh();
    var finished = false;
    unawaited(refresh.then((_) => finished = true));
    for (var i = 0; i < 30; i++) {
      expect(session.refresh(), same(refresh));
      backend.events.add(null);
    }
    time.flushMicrotasks();
    time.elapse(const Duration(seconds: 15));
    time.flushMicrotasks();
    expect(backend.queries, hasLength(1));
    for (var i = 0; i < 7; i++) {
      backend.release();
      time.flushMicrotasks();
      expect(finished, isFalse);
    }
    backend.release();
    time.flushMicrotasks();
    expect(finished, isTrue);
    expect(backend.queries, hasLength(8));
    expect(backend.maxActive, 1);
    expect(time.nonPeriodicTimerCount, 0);
  });

  _sessionTest('refresh awaits an existing cache flight AND its parked rerun', (
    time,
    backend,
    cache,
    session,
  ) {
    backend.gated = true;
    unawaited(cache.ensure(_slots.first));
    time.flushMicrotasks();
    var finished = false;
    unawaited(session.refresh().then((_) => finished = true));
    backend.release();
    time.flushMicrotasks();
    expect(backend.queries, hasLength(2));
    expect(backend.queries.last.columns, 'id');
    expect(finished, isFalse);
    backend.release();
    time.flushMicrotasks();
    expect(backend.queries, hasLength(3));
    for (var i = 0; i < 3; i++) {
      backend.release();
      time.flushMicrotasks();
    }
    expect(finished, isTrue);
    expect(backend.queries, hasLength(5));
    expect(backend.maxActive, 1);
  });

  _sessionTest(
    '20s timeout retains a stalled flight without accumulating timers',
    (time, backend, cache, session) {
      backend.gated = true;
      session.start();
      var finished = false;
      unawaited(session.refresh().then((_) => finished = true));
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 19));
      expect(finished, isFalse);
      time.elapse(const Duration(seconds: 1));
      time.flushMicrotasks();
      expect(finished, isTrue);
      expect(time.nonPeriodicTimerCount, 0);
      for (var i = 0; i < 100; i++) {
        unawaited(session.refresh());
        backend.events.add(null);
      }
      time.elapse(const Duration(minutes: 5));
      time.flushMicrotasks();
      expect(backend.queries, hasLength(1));
      expect(time.nonPeriodicTimerCount, 0);
      // The original cache flight finally settles; a fresh pass recovers.
      backend.gated = false;
      backend.release();
      time.flushMicrotasks();
      expect(backend.queries, hasLength(5));
      expect(backend.maxActive, 1);
      expect(cache.dataOf<int>(_slots.first), 1);
    },
  );

  _sessionTest('unavailable realtime safely falls back to polling', (
    time,
    backend,
    cache,
    session,
  ) {
    backend.watchFails = true;
    backend.readError = RepositoryFailure.unavailable();
    session.start();
    time.elapse(const Duration(seconds: 15));
    time.flushMicrotasks();
    expect(backend.queries, hasLength(4));
    for (final slot in _slots) {
      expect(
        cache.stateOf<Object?>(slot).failure!.kind,
        RepositoryFailureKind.unavailable,
      );
      expect(cache.dataOf<Object?>(slot), isNull);
    }
    backend.readError = null;
    time.elapse(const Duration(seconds: 15));
    time.flushMicrotasks();
    expect(cache.dataOf<int>(_slots.first), 1);
  });

  _sessionTest(
    'stream errors and reconnection request SELECTs, not fake rows',
    (time, backend, cache, session) {
      session.start();
      backend.events.addError(RepositoryFailure.offline());
      time.flushMicrotasks();
      expect(backend.queries, hasLength(4));
      backend.records = [];
      backend.events.add(null);
      time.flushMicrotasks();
      expect(backend.queries, hasLength(8));
      expect(cache.dataOf<int>(_slots.first), 0);
    },
  );

  for (final fails in [false, true]) {
    _sessionTest(
      'stop suppresses late ${fails ? 'errors' : 'reads'} and passes',
      (time, backend, cache, session) {
        backend.gated = true;
        backend.cancelFails = true;
        session.start();
        var finished = false;
        unawaited(session.refresh().then((_) => finished = true));
        unawaited(session.refresh());
        time.flushMicrotasks();
        session.stop();
        session.stop();
        session.start();
        time.flushMicrotasks();
        expect(finished, isTrue);
        expect(time.nonPeriodicTimerCount, 0);
        backend.release(error: fails ? RepositoryFailure.offline() : null);
        backend.events.add(null);
        backend.events.addError(RepositoryFailure.unavailable());
        time.flushMicrotasks();
        time.elapse(const Duration(minutes: 1));
        unawaited(session.refresh());
        time.flushMicrotasks();
        expect(backend.queries, hasLength(1));
        expect(backend.watches, hasLength(1));
        expect(backend.cancellations, 1);
      },
    );
  }

  test('cache disposal and session stop suppress late cache notifications', () {
    fakeAsync((time) {
      final backend = _Backend()..gated = true;
      final cache = DomainCache(
        registry: () => RepositoryRegistry.supabase(backend),
        profileKey: () => _profile,
        seedProfileKey: (_) => 'never-seed',
      );
      var notifications = 0;
      cache.addListener(() => notifications++);
      final session = NotificationSession(
        cache: cache,
        profileId: _profile,
        realtime: backend,
      );
      session.start();
      unawaited(session.refresh());
      time.flushMicrotasks();
      session.stop();
      cache.dispose();
      backend.release(error: RepositoryFailure.offline());
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(notifications, 0);
      expect(backend.queries, hasLength(1));
      expect(time.periodicTimerCount, 0);
      expect(time.nonPeriodicTimerCount, 0);
      unawaited(backend.events.close());
      time.flushMicrotasks();
    });
  });

  test('empty profile never installs an unscoped watch or starts reads', () {
    fakeAsync((time) {
      final backend = _Backend();
      final cache = DomainCache(
        registry: () => RepositoryRegistry.supabase(backend),
        profileKey: () => '',
        seedProfileKey: (_) => 'seed',
      );
      final session = NotificationSession(
        cache: cache,
        profileId: ' ',
        realtime: backend,
      );
      session.start();
      unawaited(session.refresh());
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(backend.watches, isEmpty);
      expect(backend.queries, isEmpty);
      expect(time.periodicTimerCount, 0);
      session.stop();
      cache.dispose();
    });
  });
}
