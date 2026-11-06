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

  /// Lets a test watch the microtask the cache notifies on.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('one read per slot', () {
    test('ensure reads once and keeps the result', () async {
      final backend = _CountingBackend(rowsByTable: {
        'profiles': [
          {'id': 'p1', 'full_name': 'Asha Bell', 'account_status': 'active'},
        ],
      });
      final cache = supabaseCache(backend);

      await cache.ensure(DomainSlot.profile);
      final first = cache.stateOf<ProfileRecord>(DomainSlot.profile);

      expect(first.status, RepositoryStatus.data);
      expect(first.data!.fullName, 'Asha Bell');
      expect(backend.tables, ['profiles']);

      await cache.ensure(DomainSlot.profile);
      expect(backend.tables, hasLength(1),
          reason: 'a cached slot is not re-read when a screen reopens');

      cache.dispose();
    });

    test('a list read that returns nothing fails with a reason', () async {
      final cache = supabaseCache(_CountingBackend());

      await cache.ensure(DomainSlot.barangays);
      final state = cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays);

      expect(state.status, RepositoryStatus.failure,
          reason: 'no active service area is a real answer, not an empty list');
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
    test('an unreachable Supabase build fails instead of serving the seed',
        () async {
      final cache = supabaseCache(const UnreachableBackend());

      await cache.ensure(DomainSlot.profile);
      final state = cache.stateOf<ProfileRecord>(DomainSlot.profile);

      expect(state.status, RepositoryStatus.failure);
      expect(state.failure!.kind, RepositoryFailureKind.unavailable);
      expect(state.data, isNull,
          reason: 'a production read that fails shows nothing, never a seeded '
              'profile');

      await cache.ensure(DomainSlot.barangays);
      expect(
        cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays).data,
        isNull,
      );
      cache.dispose();
    });

    test('a Supabase slot is not re-read when app data changes', () async {
      final backend = _CountingBackend();
      final cache = supabaseCache(backend);

      await cache.ensure(DomainSlot.profile);
      final reads = backend.tables.length;

      cache.onAppDataChanged();
      await settle();

      expect(backend.tables.length, reads,
          reason: 'unrelated app writes must not hammer the database');
      cache.dispose();
    });

    test('prefill leaves a Supabase build unread', () async {
      final backend = _CountingBackend();
      final cache = supabaseCache(backend);

      await cache.prefill();

      expect(backend.tables, isEmpty,
          reason: 'boot must not fetch data no screen has asked for yet');
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
      final before =
          cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays).data!.length;

      db.barangays.add(Barangay(name: 'Probe Barangay', puroks: const []));
      try {
        cache.onAppDataChanged();
        await settle();

        final after =
            cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays).data!;
        expect(after.length, before + 1);
        expect(after.any((barangay) => barangay.name == 'Probe Barangay'),
            isTrue);
      } finally {
        db.barangays.removeWhere((barangay) => barangay.name == 'Probe Barangay');
        cache.onAppDataChanged();
        await settle();
        expect(
          cache.stateOf<List<BarangayRecord>>(DomainSlot.barangays).data!
              .any((barangay) => barangay.name == 'Probe Barangay'),
          isFalse,
        );
        cache.dispose();
      }
    });

    test('a refresh keeps the previous answer on screen until it lands',
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
      expect(cache.stateOf<ProfileRecord>(DomainSlot.profile).data, isNotNull);
      cache.dispose();
    });

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
      expect(appNotifications, settled,
          reason: 'the cache must not re-trigger itself through the app state');
      expect(
        cache.stateOf<ProfileRecord>(DomainSlot.profile).hasData,
        isTrue,
      );
      cache.dispose();
    });
  });

  group('session changes', () {
    test('a new profile key reads the new person, not the cached answer',
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
    });

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
