import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/repository_state.dart';
import 'package:surgo/screens/home_screen.dart';
import 'package:surgo/screens/profile_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/domain_cache.dart';
import 'package:surgo/widgets/common.dart';
import 'package:surgo/widgets/location_picker.dart';
import 'package:surgo/widgets/repository_states.dart';

/// Drains the microtask the cache notifies on.
///
/// Yields rather than a timer: inside a widget test the clock is fake, so a
/// delayed future would not fire until the test pumped time.
Future<void> settle() async {
  for (var turn = 0; turn < 12; turn++) {
    await Future<void>.value();
  }
}

/// Stage 2 proof for the profile and catalog domain: these screens ask the
/// installed registry for their data, render an explicit state for every
/// answer, and never show seed rows when a production read fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  setUpAll(() async => db.load());

  /// Installs [registry] and makes the cache re-read what screens already asked
  /// for, so no test inherits another test's answer.
  Future<void> use(RepositoryRegistry registry) async {
    state.configureRepositories(registry);
    state.cache.restart();
    await settle();
  }

  setUp(() => use(RepositoryRegistry.mock(db)));

  tearDown(() => use(RepositoryRegistry.mock(db)));

  Widget pickerHost(ValueChanged<String?> onPicked) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => SbPrimaryButton(
              label: 'Pick a place',
              onPressed: () async =>
                  onPicked(await showLocationPicker(context,
                      title: 'Set pickup location')),
            ),
          ),
        ),
      );

  /// Bounded pumps instead of `pumpAndSettle`, because a slot that has not
  /// landed yet shows an indeterminate spinner that never "settles".
  Future<void> openPicker(WidgetTester tester,
      {ValueChanged<String?>? onPicked}) async {
    await tester.pumpWidget(pickerHost(onPicked ?? (_) {}));
    await tester.tap(find.text('Pick a place'));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  Future<void> pumpProfile(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: const ProfileScreen(embedded: false)));
    await settle();
    await tester.pump();
  }

  group('profile header', () {
    testWidgets('a seeded build shows the repository answer, which is the seed',
        (tester) async {
      await use(RepositoryRegistry.mock(db));
      await state.cache.prefill();

      await pumpProfile(tester);

      expect(find.text('Jr Derigay'), findsOneWidget);
      expect(find.text('⭐ 4.9 · Member since 2024'), findsOneWidget);
      expect(find.text('JD'), findsOneWidget);
      expect(find.byIcon(Icons.verified), findsOneWidget);
      expect(find.byType(SbListLoading), findsNothing);
    });

    testWidgets('a Supabase build shows the profile row, not the seeded person',
        (tester) async {
      await use(RepositoryRegistry.supabase(_StubBackend(
        rowsByTable: {
          'profiles': [
            {
              'id': 'auth-uuid-1',
              'full_name': 'Asha Bell',
              'account_status': 'active',
              'rating': 4.4,
              'total_rides': 9,
              'created_at': '2025-03-04T00:00:00Z',
            },
          ],
        },
      )));

      await pumpProfile(tester);

      expect(find.text('Asha Bell'), findsOneWidget);
      expect(find.text('⭐ 4.4 · Member since 2025'), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
      expect(find.text('Jr Derigay'), findsNothing);
      expect(find.byIcon(Icons.verified), findsNothing,
          reason: 'no approved role rows means no verified badge');
    });

    testWidgets('an unreachable Supabase build fails in place of the header',
        (tester) async {
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await pumpProfile(tester);

      expect(find.text('Jr Derigay'), findsNothing,
          reason: 'a failed production read must not fall back to the seed');
      expect(find.byType(SbFailureState), findsOneWidget);
      expect(find.text('The data service is unavailable'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('location picker', () {
    testWidgets('the sheet lists the repository barangays and returns a label',
        (tester) async {
      await use(RepositoryRegistry.mock(db));
      await state.cache.prefill();

      final first = db.barangays.first;
      String? picked;
      await openPicker(tester, onPicked: (value) => picked = value);

      expect(find.text('Set pickup location'), findsOneWidget);
      expect(find.text(first.name), findsOneWidget);
      expect(find.byType(SbListLoading), findsNothing);

      await tester.tap(find.text(first.name));
      await settle();
      await tester.pump();

      expect(find.text('Step 2 of 2 · Choose a purok in ${first.name}'),
          findsOneWidget);

      final purok = first.puroks.first;
      await tester.tap(find.text(purok));
      await settle();
      await tester.pump();

      await tester.tap(find.text('Confirm · $purok, ${first.name}'));
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      expect(picked, '$purok, ${first.name}');
    });

    testWidgets('a search narrows the repository list', (tester) async {
      await use(RepositoryRegistry.mock(db));
      await state.cache.prefill();

      final match = db.barangays.firstWhere((b) => b.puroks.length > 1);
      await openPicker(tester);

      await tester.enterText(find.byType(TextField), match.name);
      await settle();
      await tester.pump();

      // The query itself is also on screen in the field, so the assertion is
      // on the barangay card rather than on any matching text.
      expect(find.widgetWithText(SbCard, match.name), findsOneWidget);
      for (final other in db.barangays.where((b) => b.name != match.name)) {
        expect(find.widgetWithText(SbCard, other.name), findsNothing);
      }
    });

    testWidgets('a build with no active service area says so', (tester) async {
      await use(RepositoryRegistry.supabase(_StubBackend()));

      await openPicker(tester);

      expect(find.byType(SbFailureState), findsOneWidget);
      expect(find.text('Not available in this build'), findsOneWidget);
      expect(find.textContaining('service area'), findsOneWidget);
    });
  });

  group('home greeting', () {
    Future<void> openHome(WidgetTester tester) async {
      await tester
          .pumpWidget(const MaterialApp(home: HomeScreen(embedded: false)));
      await settle();
      await tester.pump();
    }

    testWidgets('a seeded build greets the passenger profile row',
        (tester) async {
      await openHome(tester);

      expect(find.text('Hi, ${db.passenger.firstName}'), findsOneWidget);
      expect(find.text('Hi there'), findsNothing,
          reason: 'the read has landed, so the un-named greeting is gone');
    });

    testWidgets('a Supabase build greets the person the profile row names',
        (tester) async {
      await use(RepositoryRegistry.supabase(_StubBackend(
        rowsByTable: {
          'profiles': [
            {
              'id': 'auth-uuid-1',
              'full_name': 'Asha Bell',
              'first_name': 'Asha',
            },
          ],
        },
      )));

      await openHome(tester);

      expect(find.text('Hi, Asha'), findsOneWidget);
      expect(find.text('Hi, ${db.passenger.firstName}'), findsNothing,
          reason: 'a production read must not greet the seeded passenger');
    });

    testWidgets('an unreachable read greets without naming anyone',
        (tester) async {
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await openHome(tester);

      expect(find.text('Hi there'), findsOneWidget);
      expect(find.text('Hi, ${db.passenger.firstName}'), findsNothing);
    });
  });

  group('the installed registry really is the source', () {
    test('a Supabase build re-reads instead of reusing the seed answer',
        () async {
      await use(RepositoryRegistry.mock(db));
      await state.cache.ensure(DomainSlot.profile);
      await settle();
      expect(
        state.cache.stateOf<ProfileRecord>(DomainSlot.profile).data!.fullName,
        'Jr Derigay',
      );

      await use(RepositoryRegistry.supabase(_StubBackend(
        rowsByTable: {
          'profiles': [
            {
              'id': 'auth-uuid-1',
              'full_name': 'Benedict Y.',
              'account_status': 'suspended',
            },
          ],
        },
      )));

      final landed = state.cache.stateOf<ProfileRecord>(DomainSlot.profile);
      expect(landed.status, RepositoryStatus.data);
      expect(landed.data!.fullName, 'Benedict Y.');
      expect(landed.data!.isSuspended, isTrue);
    });

    test('a failure is kept as a failure, never replaced by seed data',
        () async {
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));
      await state.cache.ensure(DomainSlot.profileRoles);

      final answer = state.cache.stateOf<List<String>>(DomainSlot.profileRoles);
      expect(answer.status, RepositoryStatus.failure);
      expect(answer.failure!.kind, RepositoryFailureKind.unavailable);
      expect(answer.data, isNull);
    });
  });
}

/// In-memory backend answering from fixed rows, so a screen test can prove
/// which data source its content came from.
class _StubBackend implements SurgoBackend {
  _StubBackend({this.rowsByTable = const {}});

  final Map<String, List<Map<String, dynamic>>> rowsByTable;

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
    return rowsByTable[table] ?? const [];
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    final rows = rowsByTable[table] ?? const [];
    return rows.isEmpty ? null : rows.first;
  }
}
