import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/repository_state.dart';
import 'package:surgo/state/domain_cache.dart';

/// The cache is what stands between a screen and a repository, so these tests
/// pin the rules the screens depend on: one read per slot, an explicit state
/// for every answer, and no seed rows behind a failed Supabase read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = DbService.instance;

  setUpAll(() async => db.load());

  DomainCache mockCache({String Function()? profileKey}) => DomainCache(
    registry: () => RepositoryRegistry.mock(db),
    profileKey: profileKey ?? () => DbService.primaryPassengerId,
    seedProfileKey: (role) => switch (role) {
      ActorRole.passenger => db.passenger.id,
      ActorRole.earner => db.earner.id,
      ActorRole.vehicleOwner => db.vehicleOwner.id,
      ActorRole.signedInUser => DbService.primaryPassengerId,
    },
  );

  DomainCache supabaseCache(SurgoBackend backend) => DomainCache(
    registry: () => RepositoryRegistry.supabase(backend),
    profileKey: () => 'p1',
    seedProfileKey: (_) => 'p1',
  );

  /// The same cache, for a test that changes who is signed in mid-flight.
  DomainCache supabaseCacheFor(SurgoBackend backend, String Function() key) =>
      DomainCache(
        registry: () => RepositoryRegistry.supabase(backend),
        profileKey: key,
        seedProfileKey: (_) => key(),
      );

  /// Lets a test watch the microtask the cache notifies on.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Runs every hop a finished read chains through: the parked answer resuming,
  /// the stale check, and the read it then starts.
  Future<void> drain() async {
    for (var hop = 0; hop < 5; hop++) {
      await settle();
    }
  }

  group('one read per slot', () {
    test('ensure reads once and keeps the result', () async {
      final backend = _CountingBackend(
        rowsByTable: {
          'profiles': [
            {'id': 'p1', 'full_name': 'Asha Bell', 'account_status': 'active'},
          ],
        },
      );
      final cache = supabaseCache(backend);

      await cache.ensure(DomainSlot.profile);
      final first = cache.stateOf<ProfileRecord>(DomainSlot.profile);

      expect(first.status, RepositoryStatus.data);
      expect(first.data!.fullName, 'Asha Bell');
      expect(backend.tables, ['profiles']);

      await cache.ensure(DomainSlot.profile);
      expect(
        backend.tables,
        hasLength(1),
        reason: 'a cached slot is not re-read when a screen reopens',
      );

      cache.dispose();
    });

    test('a list read that returns nothing fails with a reason', () async {
      final cache = supabaseCache(_CountingBackend());

      await cache.ensure(DomainSlot.barangays);
      final state = cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays);

      expect(
        state.status,
        RepositoryStatus.failure,
        reason: 'no active service area is a real answer, not an empty list',
      );
      expect(state.failure!.kind, RepositoryFailureKind.unsupported);
      expect(state.failure!.message, contains('service area'));

      cache.dispose();
    });

    test('a profile row that is absent reads as empty', () async {
      final cache = supabaseCache(_CountingBackend());

      await cache.ensure(DomainSlot.profile);

      expect(
        cache.stateOf<ProfileRecord>(DomainSlot.profile).status,
        RepositoryStatus.empty,
      );
      cache.dispose();
    });
  });

  group('no silent seed fallback', () {
    test(
      'an unreachable Supabase build fails instead of serving the seed',
      () async {
        final cache = supabaseCache(const UnreachableBackend());

        await cache.ensure(DomainSlot.profile);
        final state = cache.stateOf<ProfileRecord>(DomainSlot.profile);

        expect(state.status, RepositoryStatus.failure);
        expect(state.failure!.kind, RepositoryFailureKind.unavailable);
        expect(
          state.data,
          isNull,
          reason:
              'a production read that fails shows nothing, never a seeded '
              'profile',
        );

        await cache.ensure(DomainSlot.barangays);
        expect(
          cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays).data,
          isNull,
        );
        cache.dispose();
      },
    );

    test('a Supabase slot is not re-read when app data changes', () async {
      final backend = _CountingBackend();
      final cache = supabaseCache(backend);

      await cache.ensure(DomainSlot.profile);
      final reads = backend.tables.length;

      cache.onAppDataChanged();
      await settle();

      expect(
        backend.tables.length,
        reads,
        reason: 'unrelated app writes must not hammer the database',
      );
      cache.dispose();
    });

    test('prefill leaves a Supabase build unread', () async {
      final backend = _CountingBackend();
      final cache = supabaseCache(backend);

      await cache.prefill();

      expect(
        backend.tables,
        isEmpty,
        reason: 'boot must not fetch data no screen has asked for yet',
      );
      expect(cache.stateOf<ProfileRecord>(DomainSlot.profile).isIdle, isTrue);
      cache.dispose();
    });
  });

  group('mock mode', () {
    test('prefill settles every slot before a screen opens', () async {
      final cache = mockCache();

      await cache.prefill();

      expect(
        cache.stateOf<ProfileRecord>(DomainSlot.profile).status,
        RepositoryStatus.data,
      );
      expect(
        cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays).data,
        isNotEmpty,
      );
      expect(
        cache.stateOf<List<String>>(DomainSlot.profileRoles).data,
        isNotEmpty,
      );
      cache.dispose();
    });

    test('the cached list follows the seed when it changes', () async {
      final cache = mockCache();
      await cache.ensure(DomainSlot.barangays);
      final before = cache
          .stateOf<List<BarangayRecord>>(DomainSlot.barangays)
          .data!
          .length;

      db.barangays.add(Barangay(name: 'Probe Barangay', puroks: const []));
      try {
        cache.onAppDataChanged();
        await settle();

        final after = cache
            .stateOf<List<BarangayRecord>>(DomainSlot.barangays)
            .data!;
        expect(after.length, before + 1);
        expect(
          after.any((barangay) => barangay.name == 'Probe Barangay'),
          isTrue,
        );
      } finally {
        db.barangays.removeWhere(
          (barangay) => barangay.name == 'Probe Barangay',
        );
        cache.onAppDataChanged();
        await settle();
        expect(
          cache
              .stateOf<List<BarangayRecord>>(DomainSlot.barangays)
              .data!
              .any((barangay) => barangay.name == 'Probe Barangay'),
          isFalse,
        );
        cache.dispose();
      }
    });

    test(
      'a refresh keeps the previous answer on screen until it lands',
      () async {
        final cache = mockCache();
        await cache.ensure(DomainSlot.profile);

        final pending = cache.refresh(DomainSlot.profile);
        expect(
          cache.stateOf<ProfileRecord>(DomainSlot.profile).status,
          RepositoryStatus.data,
          reason: 'a refresh must not blank an already-visible record',
        );
        await pending;
        expect(
          cache.stateOf<ProfileRecord>(DomainSlot.profile).data,
          isNotNull,
        );
        cache.dispose();
      },
    );

    test('a mock refresh settles instead of re-notifying forever', () async {
      var appNotifications = 0;
      late final DomainCache cache;
      cache = mockCache()
        ..onChanged = () {
          appNotifications++;
          // Exactly how AppState wires it: the forward lands back on the
          // cache's own invalidation hook.
          cache.onAppDataChanged();
        };

      await cache.prefill();
      await settle();
      final settled = appNotifications;
      await settle();

      expect(settled, greaterThan(0));
      expect(
        appNotifications,
        settled,
        reason: 'the cache must not re-trigger itself through the app state',
      );
      expect(cache.stateOf<ProfileRecord>(DomainSlot.profile).hasData, isTrue);
      cache.dispose();
    });
  });

  group('session changes', () {
    test(
      'a new profile key reads the new person, not the cached answer',
      () async {
        var key = DbService.primaryPassengerId;
        final cache = mockCache(profileKey: () => key);

        await cache.ensure(DomainSlot.profile);
        final original = cache.stateOf<ProfileRecord>(DomainSlot.profile).data!;

        key = 'P002';
        cache.restart();
        await settle();

        final next = cache.stateOf<ProfileRecord>(DomainSlot.profile).data!;
        expect(next.id, isNot(original.id));
        expect(next.fullName, isNot(original.fullName));
        cache.dispose();
      },
    );

    test('a finished read reaches the app state', () async {
      var forwarded = 0;
      final cache = mockCache()..onChanged = () => forwarded++;

      await cache.ensure(DomainSlot.profile);
      await settle();

      expect(forwarded, greaterThan(0));
      expect(cache.stateOf<ProfileRecord>(DomainSlot.profile).hasData, isTrue);
      cache.dispose();
    });
  });

  group('session changes during a parked read', () {
    test('refresh callers await the coalesced authoritative read', () async {
      final backend = _GatedProfileBackend(
        rowsById: {
          'p1': const {
            'id': 'p1',
            'full_name': 'Current',
            'account_status': 'active',
          },
        },
      );
      final cache = supabaseCache(backend);
      final first = cache.ensure(DomainSlot.profile);
      final ensured = cache.ensure(DomainSlot.profile);
      final refresh = cache.refresh(DomainSlot.profile);
      final another = cache.refresh(DomainSlot.profile);
      expect(ensured, same(first));
      expect(refresh, same(first));
      expect(another, same(first));
      var completed = false;
      unawaited(refresh.then((_) => completed = true));
      backend.release();
      await drain();
      expect(backend.requestedIds, ['p1', 'p1']);
      expect(completed, isFalse);
      backend.release();
      await Future.wait([first, refresh, another]);
      expect(completed, isTrue);
      expect(
        cache.stateOf<ProfileRecord>(DomainSlot.profile).data!.fullName,
        'Current',
      );
      cache.dispose();
    });

    test(
      'a read in flight when the session changes cannot land its answer',
      () async {
        var key = 'p-old';
        final backend = _GatedProfileBackend(
          rowsById: {
            'p-old': const {
              'id': 'p-old',
              'full_name': 'Marta Old',
              'account_status': 'active',
            },
            'p-new': const {
              'id': 'p-new',
              'full_name': 'Nadia New',
              'account_status': 'active',
            },
          },
        );
        final cache = supabaseCacheFor(backend, () => key);

        unawaited(cache.ensure(DomainSlot.profile));
        await settle();
        expect(backend.requestedIds, ['p-old']);

        key = 'p-new';
        cache.restart();
        await settle();
        expect(
          cache.stateOf<ProfileRecord>(DomainSlot.profile).isLoading,
          isTrue,
          reason: 'a retired slot waits on a new read, not on nothing at all',
        );

        // The answer the previous session was owed arrives now.
        backend.release();
        await drain();

        expect(
          cache.stateOf<ProfileRecord>(DomainSlot.profile).data,
          isNull,
          reason:
              'the person signed in a moment ago must not reach the new '
              'session, not even as a frame of data',
        );
        expect(backend.requestedIds, ['p-old', 'p-new']);

        backend.release();
        await drain();

        expect(
          cache.stateOf<ProfileRecord>(DomainSlot.profile).data!.fullName,
          'Nadia New',
        );
        cache.dispose();
      },
    );

    test(
      'several session changes in a row leave only the last one cached',
      () async {
        var key = 'p-a';
        final backend = _GatedProfileBackend(
          rowsById: {
            'p-a': const {
              'id': 'p-a',
              'full_name': 'Ann A',
              'account_status': 'active',
            },
            'p-b': const {
              'id': 'p-b',
              'full_name': 'Bea B',
              'account_status': 'active',
            },
            'p-c': const {
              'id': 'p-c',
              'full_name': 'Cy C',
              'account_status': 'active',
            },
          },
        );
        final cache = supabaseCacheFor(backend, () => key);

        unawaited(cache.ensure(DomainSlot.profile));
        await settle();

        key = 'p-b';
        cache.restart();
        key = 'p-c';
        cache.restart();
        await settle();

        // Two requests were parked behind one read; the rerun is a single read
        // for whoever is signed in now, not one per restart.
        backend.release();
        await drain();
        expect(backend.requestedIds, ['p-a', 'p-c']);

        backend.release();
        await drain();
        expect(
          cache.stateOf<ProfileRecord>(DomainSlot.profile).data!.fullName,
          'Cy C',
        );
        cache.dispose();
      },
    );

    test('a rerun that fails stays a failure the screen can retry', () async {
      var key = 'p-old';
      final backend = _GatedProfileBackend(
        rowsById: {
          'p-old': const {
            'id': 'p-old',
            'full_name': 'Marta Old',
            'account_status': 'active',
          },
          'p-new': const {
            'id': 'p-new',
            'full_name': 'Nadia New',
            'account_status': 'active',
          },
        },
      );
      final cache = supabaseCacheFor(backend, () => key);

      unawaited(cache.ensure(DomainSlot.profile));
      await settle();
      key = 'p-new';
      cache.restart();
      backend.release();
      await drain();
      expect(backend.requestedIds, ['p-old', 'p-new']);

      // The read the session change parked now fails on the way back.
      backend.release(error: RepositoryFailure.offline());
      await drain();

      final state = cache.stateOf<ProfileRecord>(DomainSlot.profile);
      expect(state.status, RepositoryStatus.failure);
      expect(state.failure!.kind, RepositoryFailureKind.offline);
      expect(
        state.data,
        isNull,
        reason: 'a failed rerun shows no one rather than the previous person',
      );

      // Retrying a settled failure reads again, exactly as the screen's button
      // asks it to.
      unawaited(cache.retry(DomainSlot.profile));
      await settle();
      expect(backend.requestedIds, hasLength(3));
      backend.release();
      await drain();
      expect(
        cache.stateOf<ProfileRecord>(DomainSlot.profile).data!.fullName,
        'Nadia New',
      );
      cache.dispose();
    });
  });
}

/// A [SurgoBackend] whose answers the test hands out one at a time, so a read
/// can be held in flight across a session change and released afterwards.
class _GatedProfileBackend implements SurgoBackend {
  _GatedProfileBackend({required this.rowsById});

  final Map<String, Map<String, dynamic>> rowsById;

  /// Every profile id the cache has asked for, in order.
  final List<String> requestedIds = [];

  final List<_ParkedRow> _parked = [];

  /// Resolves the oldest waiting read and reports whose row it was asked for.
  String release({Object? error}) {
    final row = _parked.removeAt(0);
    if (error != null) {
      row.done.completeError(error);
    } else {
      row.done.complete(rowsById[row.id]);
    }
    return row.id;
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    final id = '${eq['id']}';
    requestedIds.add(id);
    final parked = _ParkedRow(id);
    _parked.add(parked);
    return await parked.done.future;
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
    throw RepositoryFailure.unsupported(
      'This test only parks single-row reads.',
    );
  }
}

class _ParkedRow {
  _ParkedRow(this.id);

  final String id;
  final Completer<Map<String, dynamic>?> done = Completer();
}

/// In-memory [SurgoBackend] that records which tables it was asked for.
class _CountingBackend implements SurgoBackend {
  _CountingBackend({this.rowsByTable = const {}});

  final Map<String, List<Map<String, dynamic>>> rowsByTable;
  final List<String> tables = [];

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
    tables.add(table);
    return rowsByTable[table] ?? const [];
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    tables.add(table);
    for (final row in rowsByTable[table] ?? const []) {
      if (eq.entries.every((filter) => row[filter.key] == filter.value)) {
        return row;
      }
    }
    return null;
  }
}
