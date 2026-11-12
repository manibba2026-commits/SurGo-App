import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/domain_cache.dart';

const _userA = AuthUser(
  id: 'notification-user-a',
  email: 'notification-a@surgo.test',
  fullName: 'Notification A',
  providers: {'email'},
);
const _userB = AuthUser(
  id: 'notification-user-b',
  email: 'notification-b@surgo.test',
  fullName: 'Notification B',
  providers: {'email'},
);
const _slots = [
  DomainSlot.unreadPassengerNotifications,
  DomainSlot.unreadEarnerNotifications,
  DomainSlot.passengerNotificationFeed,
  DomainSlot.earnerNotificationFeed,
];

typedef _Query = ({
  String columns,
  Map<String, Object> eq,
  List<String> whereNull,
  String? orderBy,
  int? limit,
});

/// Real AppState hosted semantics, without SDK sessions or network transport.
class _HostedAuth extends MockAuthRepository {
  final events = StreamController<AuthUser?>.broadcast(sync: true);
  AuthUser? session;
  Completer<SurgoIdentity>? pendingIdentity;
  int identityReads = 0;

  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => events.stream;

  @override
  Future<AuthUser?> restoreSession() async => session;

  @override
  Future<AuthUser> signInWithEmail({
    required String email,
    required String password,
  }) async => session = email == _userB.email ? _userB : _userA;

  SurgoIdentity identityFor(AuthUser user) => SurgoIdentity(
    userId: user.id,
    email: user.email,
    fullName: user.fullName,
    capabilities: const {CapabilityType.passenger},
    eligibleCapabilities: const {},
    roles: const {'passenger'},
    providers: user.providers,
    profileExists: true,
  );

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    identityReads++;
    return pendingIdentity == null
        ? identityFor(user)
        : await pendingIdentity!.future;
  }

  void emit(AuthUser? user) {
    session = user;
    events.add(user);
  }

  @override
  Future<void> signOut() async => emit(null);
}

class _Watch {
  _Watch(this.table, this.column, this.value, List<String> lifecycle) {
    events = StreamController<void>.broadcast(
      sync: true,
      onListen: () => lifecycle.add('listen:$table:$value'),
      onCancel: () {
        cancellations++;
        lifecycle.add('cancel:$table:$value');
      },
    );
  }

  final String table;
  final String column;
  final String value;
  late final StreamController<void> events;
  int cancellations = 0;
}

/// Exercises Supabase repository parsing/filtering, not a Supabase client.
class _Backend implements SurgoBackend, SurgoRealtimeBackend {
  _Backend({List<String>? lifecycle}) : lifecycle = lifecycle ?? [];

  final List<String> lifecycle;
  final queries = <_Query>[];
  final watches = <_Watch>[];
  Future<List<Map<String, dynamic>>> Function(_Query)? notificationRead;

  List<_Watch> get notificationWatches =>
      watches.where((watch) => watch.table == 'notifications').toList();

  List<Map<String, dynamic>> records(String profile) => [
    for (var i = 0; i < (profile == _userB.id ? 2 : 1); i++)
      {
        'id': '$profile-notification-$i',
        'profile_id': profile,
        'notification_type': 'ride',
        'title': 'Feed for $profile',
        'body': 'Offline repository answer',
        'read_at': null,
        'created_at': '2026-11-06T08:00:00Z',
      },
  ];

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    final watch = _Watch(table, column, value, lifecycle);
    watches.add(watch);
    return watch.events.stream;
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
    // Passenger ride restoration also owns a poll/watch; leave its feed empty.
    if (table != 'notifications') return [];
    final query = (
      columns: columns,
      eq: Map<String, Object>.of(eq),
      whereNull: List<String>.of(whereNull),
      orderBy: orderBy,
      limit: limit,
    );
    queries.add(query);
    return notificationRead == null
        ? records(eq['profile_id']! as String)
        : await notificationRead!(query);
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async => null;
}

// Attach a realtime spy to an otherwise genuinely mock registry so the
// negative capability test detects an accidental attempt to subscribe.
RepositoryRegistry _mockRegistry(_Backend backend) {
  final mock = RepositoryRegistry.mock();
  return RepositoryRegistry(
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
    realtime: backend,
  );
}

void _expectReads(Iterable<_Query> reads, String profile, int count) {
  final queries = reads.toList();
  expect(queries, hasLength(count));
  for (final query in queries) {
    expect(query.eq, {'profile_id': profile});
    expect(query.limit, isNull);
    if (query.columns == 'id') {
      expect(query.whereNull, ['read_at']);
      expect(query.orderBy, isNull);
    } else {
      expect(query.columns, contains('notification_type, title, body'));
      expect(query.whereNull, isEmpty);
      expect(query.orderBy, 'created_at');
    }
  }
  expect(
    queries.where((query) => query.columns == 'id'),
    hasLength(count ~/ 2),
  );
}

void _expectCache(AppState state, AuthUser user) {
  final count = user.id == _userB.id ? 2 : 1;
  for (final slot in _slots.take(2)) {
    expect(state.cache.dataOf<int>(slot), count);
  }
  for (final slot in _slots.skip(2)) {
    final feed = state.cache.dataOf<List<NotificationRecord>>(slot)!;
    expect(feed, hasLength(count));
    expect(feed.map((row) => row.title), everyElement('Feed for ${user.id}'));
  }
}

class _Rig {
  _Rig(this.time) {
    state.configureAuth(auth);
    state.configureRepositories(RepositoryRegistry.supabase(backend));
    time.flushMicrotasks();
    backend.queries.clear();
  }

  final FakeAsync time;
  final state = AppState.instance;
  final auth = _HostedAuth();
  final backend = _Backend();
  final otherAuth = <_HostedAuth>[];
  final otherBackends = <_Backend>[];
  final parked = <Completer<List<Map<String, dynamic>>>>[];

  void signIn([AuthUser user = _userA]) {
    var finished = false;
    unawaited(
      state
          .signInWithEmail(email: user.email!, password: 'offline-password')
          .then((failure) {
            expect(failure, isNull);
            finished = true;
          }),
    );
    time.flushMicrotasks();
    expect(finished, isTrue);
    expect(state.identity?.userId, user.id);
    expect(state.currentAccount?.authUserId, user.id);
    expect(state.isSignedIn, isTrue);
  }

  void logout() {
    var finished = false;
    unawaited(state.logout().then((_) => finished = true));
    time.flushMicrotasks();
    expect(finished, isTrue);
  }

  void dispose() {
    for (final backend in [backend, ...otherBackends]) {
      backend.notificationRead = null;
    }
    for (final provider in [auth, ...otherAuth]) {
      final pending = provider.pendingIdentity;
      if (pending != null && !pending.isCompleted) {
        pending.complete(provider.identityFor(provider.session ?? _userA));
      }
    }
    // Logout owns both the notification and passenger-ride timers. Do this
    // inside their fake-clock zone even when an assertion in the body failed.
    logout();
    for (final gate in parked) {
      if (!gate.isCompleted) gate.complete([]);
    }
    time.flushMicrotasks();
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    for (final provider in [auth, ...otherAuth]) {
      unawaited(provider.events.close());
    }
    for (final backend in [backend, ...otherBackends]) {
      for (final watch in backend.watches) {
        unawaited(watch.events.close());
      }
    }
    time.flushMicrotasks();
    expect(time.periodicTimerCount, 0);
    expect(time.nonPeriodicTimerCount, 0);
  }
}

void _lifecycleTest(String name, void Function(_Rig) body) {
  test(name, () {
    fakeAsync((time) {
      final rig = _Rig(time);
      try {
        body(rig);
      } finally {
        rig.dispose();
      }
    });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    final boot = _Backend();
    state.configureRepositories(RepositoryRegistry.supabase(boot));
    expect(state.ready, isFalse);
    expect(boot.notificationWatches, isEmpty);
    await state.init();
    expect(state.ready, isTrue);
    expect(state.isSignedIn, isFalse);
    expect(boot.queries, isEmpty);
    expect(boot.notificationWatches, isEmpty);
  });

  tearDown(() async => state.logout());

  _lifecycleTest(
    'sign-in immediately reads all four slots for the auth profile',
    (rig) {
      final cachedSlots = _slots
          .where((slot) => !state.cache.stateOf<Object?>(slot).isIdle)
          .length;
      expect(rig.backend.notificationWatches, isEmpty);
      rig.signIn();
      final watch = rig.backend.notificationWatches.single;
      expect((watch.column, watch.value), ('profile_id', _userA.id));
      // restart() also re-reads previously requested slots. The additional four
      // reads prove start includes refresh, even on a warm singleton cache.
      _expectReads(rig.backend.queries, _userA.id, cachedSlots + 4);
      _expectCache(state, _userA);
      expect(rig.time.elapsed, Duration.zero);
    },
  );

  _lifecycleTest('token refresh keeps one watcher and one notification poll', (
    rig,
  ) {
    rig.signIn();
    final watch = rig.backend.notificationWatches.single;
    final reads = rig.backend.queries.length;
    final identityReads = rig.auth.identityReads;
    final timers = rig.time.periodicTimerCount;
    for (var i = 0; i < 3; i++) {
      rig.auth.emit(_userA);
      rig.time.flushMicrotasks();
    }
    expect(rig.auth.identityReads, identityReads + 3);
    expect(rig.backend.notificationWatches, [watch]);
    expect(watch.cancellations, 0);
    expect(rig.backend.queries, hasLength(reads));
    expect(rig.time.periodicTimerCount, timers);
    rig.time.elapse(const Duration(seconds: 15));
    rig.time.flushMicrotasks();
    _expectReads(rig.backend.queries.skip(reads), _userA.id, 4);
  });

  for (final providerSignOut in [false, true]) {
    _lifecycleTest(
      '${providerSignOut ? 'provider sign-out' : 'logout'} cancels watch and polling',
      (rig) {
        rig.signIn();
        final watch = rig.backend.notificationWatches.single;
        if (providerSignOut) {
          rig.auth.emit(null);
          rig.time.flushMicrotasks();
        } else {
          rig.logout();
        }
        expect(watch.cancellations, 1);
        expect(state.identity, isNull);
        expect(state.currentAccount, isNull);
        expect(state.isSignedIn, isFalse);
        // Session cleanup intentionally restarts cached slots under the
        // signed-out key. Only subsequent polling/signals must produce none.
        final reads = rig.backend.queries.length;
        watch.events.add(null);
        rig.time.elapse(const Duration(minutes: 1));
        rig.time.flushMicrotasks();
        expect(rig.backend.queries, hasLength(reads));
        expect(rig.backend.notificationWatches, [watch]);
        expect(rig.time.periodicTimerCount, 0);
        expect(rig.time.nonPeriodicTimerCount, 0);
      },
    );
  }

  _lifecycleTest('identity switch retires old watch and filters new profile', (
    rig,
  ) {
    rig.signIn();
    final old = rig.backend.notificationWatches.single;
    final before = rig.backend.queries.length;
    rig.auth.emit(_userB);
    rig.time.flushMicrotasks();
    expect(state.identity?.userId, _userB.id);
    expect(state.currentAccount?.authUserId, _userB.id);
    expect(old.cancellations, 1);
    final next = rig.backend.notificationWatches.last;
    expect(rig.backend.notificationWatches, hasLength(2));
    expect((next.column, next.value), ('profile_id', _userB.id));
    expect(rig.backend.queries.skip(before), isNotEmpty);
    for (final query in rig.backend.queries.skip(before)) {
      expect(query.eq, {'profile_id': _userB.id});
    }
    _expectCache(state, _userB);
    rig.backend.queries.clear();
    old.events.add(null);
    rig.time.flushMicrotasks();
    expect(rig.backend.queries, isEmpty);
    next.events.add(null);
    rig.time.flushMicrotasks();
    _expectReads(rig.backend.queries, _userB.id, 4);
  });

  _lifecycleTest('registry replacement stops old monitor before new watch', (
    rig,
  ) {
    rig.signIn();
    final old = rig.backend.notificationWatches.single;
    final replacement = _Backend(lifecycle: rig.backend.lifecycle);
    rig.otherBackends.add(replacement);
    rig.backend.lifecycle.clear();
    state.configureRepositories(RepositoryRegistry.supabase(replacement));
    rig.time.flushMicrotasks();
    expect(old.cancellations, 1);
    final next = replacement.notificationWatches.single;
    expect((next.column, next.value), ('profile_id', _userA.id));
    expect(
      rig.backend.lifecycle.indexOf('cancel:notifications:${_userA.id}'),
      lessThan(
        rig.backend.lifecycle.indexOf('listen:notifications:${_userA.id}'),
      ),
    );
    _expectReads(replacement.queries, _userA.id, 8);
    final oldReads = rig.backend.queries.length;
    replacement.queries.clear();
    old.events.add(null);
    rig.time.flushMicrotasks();
    expect(replacement.queries, isEmpty);
    next.events.add(null);
    rig.time.flushMicrotasks();
    _expectReads(replacement.queries, _userA.id, 4);
    replacement.queries.clear();
    rig.time.elapse(const Duration(seconds: 15));
    rig.time.flushMicrotasks();
    _expectReads(replacement.queries, _userA.id, 4);
    expect(rig.backend.queries, hasLength(oldReads));
    _expectCache(state, _userA);
  });

  for (final user in [_userA, _userB]) {
    _lifecycleTest(
      'configureAuth waits for ${user == _userA ? 'unchanged' : 'new'} identity before starting',
      (rig) {
        rig.signIn();
        final old = rig.backend.notificationWatches.single;
        final replacement = _HostedAuth()
          ..pendingIdentity = Completer<SurgoIdentity>();
        rig.otherAuth.add(replacement);
        state.configureAuth(replacement);
        rig.time.flushMicrotasks();
        expect(old.cancellations, 1);
        expect(state.identity?.userId, _userA.id);
        replacement.emit(user);
        rig.time.flushMicrotasks();
        expect(replacement.identityReads, 1);
        final reads = rig.backend.queries.length;
        rig.time.elapse(const Duration(seconds: 45));
        rig.time.flushMicrotasks();
        expect(rig.backend.notificationWatches, [old]);
        expect(rig.backend.queries, hasLength(reads));
        replacement.pendingIdentity!.complete(replacement.identityFor(user));
        replacement.pendingIdentity = null;
        rig.time.flushMicrotasks();
        expect(state.identity?.userId, user.id);
        expect(state.currentAccount?.authUserId, user.id);
        expect(rig.backend.notificationWatches, hasLength(2));
        final next = rig.backend.notificationWatches.last;
        expect((next.column, next.value), ('profile_id', user.id));
        _expectReads(
          rig.backend.queries.skip(reads),
          user.id,
          user == _userA ? 4 : 8,
        );
        _expectCache(state, user);
        rig.auth.emit(user == _userA ? _userB : _userA);
        rig.time.flushMicrotasks();
        expect(state.identity?.userId, user.id);
        expect(rig.backend.notificationWatches, hasLength(2));
      },
    );
  }

  _lifecycleTest(
    'hosted auth with mock registry starts no notification monitor',
    (rig) {
      state.configureRepositories(_mockRegistry(rig.backend));
      rig.time.flushMicrotasks();
      rig.signIn();
      expect(state.usesHostedIdentity, isTrue);
      expect(state.usesHostedRideDispatch, isFalse);
      rig.auth.emit(_userA);
      rig.time.elapse(const Duration(minutes: 1));
      rig.time.flushMicrotasks();
      expect(rig.backend.notificationWatches, isEmpty);
      expect(rig.backend.queries, isEmpty);
      expect(rig.time.periodicTimerCount, 0);
    },
  );

  _lifecycleTest('old parked feed cannot publish into the next session cache', (
    rig,
  ) {
    rig.signIn();
    final old = rig.backend.notificationWatches.single;
    final gate = Completer<List<Map<String, dynamic>>>();
    rig.parked.add(gate);
    rig.backend.notificationRead = (query) async {
      if (query.eq['profile_id'] == _userA.id && query.columns != 'id') {
        return gate.future;
      }
      return rig.backend.records(query.eq['profile_id']! as String);
    };
    old.events.add(null);
    rig.time.flushMicrotasks();
    expect(rig.backend.queries.last.columns, isNot('id'));
    expect(gate.isCompleted, isFalse);

    final published = <String>[];
    void observe() {
      if (state.identity?.userId != _userB.id) return;
      for (final slot in _slots.skip(2)) {
        final feed = state.cache.dataOf<List<NotificationRecord>>(slot);
        if (feed != null) published.addAll(feed.map((row) => row.title));
      }
    }

    state.cache.addListener(observe);
    try {
      final before = rig.backend.queries.length;
      rig.signIn(_userB);
      expect(old.cancellations, 1);
      expect(rig.backend.notificationWatches.last.value, _userB.id);
      expect(
        state.cache
            .stateOf<List<NotificationRecord>>(
              DomainSlot.passengerNotificationFeed,
            )
            .isLoading,
        isTrue,
      );
      gate.complete(rig.backend.records(_userA.id));
      rig.time.flushMicrotasks();
      _expectCache(state, _userB);
      expect(published, isNotEmpty);
      expect(published, everyElement('Feed for ${_userB.id}'));
      for (final query in rig.backend.queries.skip(before)) {
        expect(query.eq, {'profile_id': _userB.id});
      }
      final reads = rig.backend.queries.length;
      old.events.add(null);
      rig.time.flushMicrotasks();
      expect(rig.backend.queries, hasLength(reads));
    } finally {
      state.cache.removeListener(observe);
    }
  });
}
