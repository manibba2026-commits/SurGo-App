import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/rider_home_screen.dart';
import 'package:surgo/state/app_state.dart';

/// Stage 2 proof for the rider's identity header: the name, the avatar and the
/// summary all come from the earner's profile row, so a Supabase build names
/// the signed-in account rather than the seeded earner, never prints the auth
/// uuid, and says so while the read is outstanding, absent or failed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  Future<void> settle() async {
    for (var turn = 0; turn < 12; turn++) {
      await Future<void>.value();
    }
  }

  Future<void> use(RepositoryRegistry registry) async {
    state.configureRepositories(registry);
    state.cache.restart();
    await settle();
  }

  /// A Supabase build keys the header by the signed-in account, so the stub
  /// row only lands when the session carries the same id the row does.
  void signInAs(String userId) {
    state.identity = SurgoIdentity(
      userId: userId,
      capabilities: {CapabilityType.rider},
      eligibleCapabilities: const {},
      roles: const {'rider'},
      providers: const {'phone'},
    );
  }

  setUpAll(() async => db.load());

  tearDown(() async {
    state.identity = null;
    await use(RepositoryRegistry.mock(db));
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RiderHomeScreen(embedded: false)));
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  group('rider home identity', () {
    testWidgets('a seeded build names the earner the repository returns',
        (tester) async {
      await open(tester);

      expect(find.text(db.earner.name), findsOneWidget);
      expect(
        find.text('⭐ ${db.earner.rating} · Since ${db.earner.memberSince}'),
        findsOneWidget,
        reason: 'the summary comes from the same seeded row, in words the '
            'record itself carries',
      );
      expect(find.textContaining('Earner ID'), findsNothing,
          reason: 'an internal id is not something the header can show in '
              'every build');
    });

    testWidgets('a Supabase build names the account the profile row carries',
        (tester) async {
      signInAs('9c4a1f2e-0000-4000-8000-0000000000aa');
      await use(RepositoryRegistry.supabase(_StubBackend(profileRows: [
        {
          'id': '9c4a1f2e-0000-4000-8000-0000000000aa',
          'full_name': 'Asha Bell',
          'first_name': 'Asha',
          'account_status': 'active',
          'rating': 4.8,
          'total_rides': 12,
          'created_at': '2024-03-11T01:02:03.000Z',
        },
      ])));

      await open(tester);

      expect(find.text('Asha Bell'), findsOneWidget);
      expect(find.text('⭐ 4.8 · Since 2024'), findsOneWidget);
      expect(find.text(db.earner.name), findsNothing,
          reason: 'a production read must not greet the seeded earner');
      expect(find.textContaining('9c4a1f2e'), findsNothing,
          reason: 'the auth uuid is an internal key, not header copy');
    });

    testWidgets('the header waits on the read instead of naming someone',
        (tester) async {
      final stall = Completer<void>();
      signInAs('9c4a1f2e-0000-4000-8000-0000000000aa');
      await use(RepositoryRegistry.supabase(_StubBackend(
        stall: stall,
        profileRows: [
          {
            'id': '9c4a1f2e-0000-4000-8000-0000000000aa',
            'full_name': 'Asha Bell',
            'account_status': 'active',
            'created_at': '2024-03-11T01:02:03.000Z',
          },
        ],
      )));

      await open(tester);

      expect(find.text('Loading your profile…'), findsOneWidget);
      expect(find.text(db.earner.name), findsNothing);

      stall.complete();
      await settle();
      await tester.pump();

      expect(find.text('Loading your profile…'), findsNothing);
      expect(find.text('Asha Bell'), findsOneWidget);
    });

    testWidgets('an account with no profile row says so', (tester) async {
      await use(RepositoryRegistry.supabase(_StubBackend(profileRows: [])));

      await open(tester);

      expect(find.text('No earner profile on this account'), findsOneWidget);
      expect(find.text(db.earner.name), findsNothing);
    });

    testWidgets('an unreachable read fails visibly instead of showing the seed',
        (tester) async {
      expect(db.earner.name, isNotEmpty);
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester);

      expect(find.text('The data service is unavailable right now.'),
          findsOneWidget);
      expect(find.text(db.earner.name), findsNothing,
          reason: 'a failed read shows nothing rather than a seeded person');
    });
  });
}

/// Answers the header's profile read, and leaves every other read empty
/// because this test is only about whose name the header wears.
class _StubBackend implements SurgoBackend {
  const _StubBackend({this.profileRows = const [], this.stall});

  final List<Map<String, dynamic>> profileRows;

  /// When set, no read answers until the test completes it.
  final Completer<void>? stall;

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
    await stall?.future;
    return const [];
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    await stall?.future;
    for (final row in profileRows) {
      if (row['id'] == eq['id']) return row;
    }
    return null;
  }
}
