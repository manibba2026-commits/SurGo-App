import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_mappers.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/screens/home_screen.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';

/// Stage 2 proof for the passenger home's Recent Bookings card: the three
/// rows come from the ride-history repository, a seeded build keeps showing
/// the seed's own bookings (and follows a ride completed this run), and a
/// Supabase build shows only the signed-in account's terminal rides — never
/// the seed, and never a request still being matched.
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

  /// A Supabase build keys the read by the signed-in account, so the stub
  /// rows only land when the session carries the same id the rows do.
  void signInAs(String userId) {
    state.identity = SurgoIdentity(
      userId: userId,
      capabilities: {CapabilityType.passenger},
      eligibleCapabilities: const {},
      roles: const {'passenger'},
      providers: const {'phone'},
    );
  }

  late List<RideHistoryItem> rideHistory;

  setUpAll(() async => db.load());

  setUp(() {
    rideHistory = List.of(db.rideHistory);
  });

  tearDown(() async {
    db.rideHistory
      ..clear()
      ..addAll(rideHistory);
    state.identity = null;
    await use(RepositoryRegistry.mock(db));
  });

  Future<void> open(WidgetTester tester) async {
    // Recent Bookings sits at the bottom of a long ListView; a viewport this
    // tall builds every card so the finders can see them without scrolling.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen(embedded: false)));
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  Future<void> land(WidgetTester tester) async {
    await tester.pump();
    await settle();
    await tester.pump();
  }

  group('ride history read', () {
    test('the mock history is the seed history, without open requests',
        () async {
      final repository = MockRideRepository(db);
      final records = await repository.fetchRideHistory(db.passenger.id);
      expect(records.map((r) => r.id), db.rideHistory.map((h) => h.id));
      expect(records.every((r) => r.status.isTerminal), isTrue);
      expect(await repository.fetchRideHistory('P002'), isEmpty);

      final few = await repository.fetchRideHistory(db.passenger.id, limit: 3);
      expect(few.map((r) => r.id), db.rideHistory.take(3).map((h) => h.id));
    });

    test('the mapper joins a seed route once and keeps its money', () async {
      final records =
          await MockRideRepository(db).fetchRideHistory(db.passenger.id);
      expect(records, isNotEmpty);
      for (var i = 0; i < records.length; i++) {
        final seed = db.rideHistory[i];
        final item = rideHistoryFromRow(records[i]);
        expect(item.route, seed.route,
            reason: 'pickup and dropoff join back into the seed route, '
                'not a doubled one');
        expect(item.fare, seed.fare);
        expect(item.status, seed.status);
        expect(item.date, displayTimestamp(seed.completedAt));
      }
    });
  });

  group('recent bookings card', () {
    testWidgets('a seeded build lists the three bookings it always showed',
        (tester) async {
      await open(tester);

      expect(find.text('Poblacion → SM Terminal'), findsOneWidget);
      expect(find.text('Purok 5 → Barangay Hall'), findsOneWidget);
      expect(find.text('Downtown → Public Market'), findsOneWidget);
      expect(find.textContaining(Money.format(6500)), findsOneWidget);
      expect(find.text('COMPLETED'), findsNWidgets(3));
      expect(find.text('SM Terminal → Poblacion'), findsNothing,
          reason: 'the card stops at three bookings');
      expect(find.text('Purok 3, San Isidro'), findsNothing,
          reason: 'an open request is not a booking yet');
    });

    testWidgets('a seeded build follows a ride completed this run',
        (tester) async {
      await open(tester);

      db.rideHistory.insert(
        0,
        RideHistoryItem(
          id: 'rh-test',
          route: 'Bagong Lungsod → Test Destination',
          date: 'Just now',
          fare: 12300,
          status: 'Completed',
          vehicleType: 'Tricycle',
          driverName: 'Test Rider',
          rating: 5,
          completedAt: DateTime.now(),
        ),
      );
      state.notifyListeners();
      await land(tester);

      expect(find.text('Bagong Lungsod → Test Destination'), findsOneWidget);
      expect(find.text('Downtown → Public Market'), findsNothing,
          reason: 'the newest booking pushes the oldest of the three out');
    });

    testWidgets('a Supabase build lists the rows it was given, not the seed',
        (tester) async {
      signInAs('9c4a1f2e-0000-4000-8000-0000000000bb');
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'ride_requests': [
          {
            'id': 'ride-1',
            'passenger_id': '9c4a1f2e-0000-4000-8000-0000000000bb',
            'service_area_id': 'sa-tandag-city',
            'status': 'completed',
            'pickup_address': 'Mabua',
            'dropoff_address': 'Public Market',
            'fare_centavos': 5500,
            'requested_at': '2026-11-01T02:00:00.000Z',
            'completed_at': '2026-11-01T02:25:00.000Z',
          },
          {
            'id': 'ride-2',
            'passenger_id': '9c4a1f2e-0000-4000-8000-0000000000bb',
            'service_area_id': 'sa-tandag-city',
            'status': 'cancelled',
            'pickup_address': 'Awasian',
            'dropoff_address': 'City Hall',
            'fare_centavos': 6000,
            'requested_at': '2026-10-30T08:00:00.000Z',
            'cancelled_at': '2026-10-30T08:05:00.000Z',
          },
        ],
      })));

      await open(tester);

      expect(find.text('Mabua → Public Market'), findsOneWidget);
      expect(find.text('Awasian → City Hall'), findsOneWidget);
      expect(find.textContaining(Money.format(5500)), findsOneWidget);
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('Poblacion → SM Terminal'), findsNothing,
          reason: 'a production read must not list the seeded bookings');
    });

    testWidgets('a Supabase account with no rides says so', (tester) async {
      signInAs('9c4a1f2e-0000-4000-8000-0000000000bb');
      await use(RepositoryRegistry.supabase(_FixedBackend()));

      await open(tester);

      expect(find.text('No bookings yet'), findsOneWidget);
      expect(find.text('Poblacion → SM Terminal'), findsNothing);
    });

    testWidgets('an unreachable read fails visibly instead of showing the seed',
        (tester) async {
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester);

      expect(find.text('The data service is unavailable'), findsOneWidget);
      expect(find.text('Poblacion → SM Terminal'), findsNothing,
          reason: 'a failed read shows nothing rather than seeded bookings');
    });

    testWidgets('the card waits on the read instead of listing the seed',
        (tester) async {
      final stall = Completer<void>();
      signInAs('9c4a1f2e-0000-4000-8000-0000000000bb');
      await use(RepositoryRegistry.supabase(_FixedBackend(
        stall: stall,
        rowsByTable: {
          'ride_requests': [
            {
              'id': 'ride-1',
              'passenger_id': '9c4a1f2e-0000-4000-8000-0000000000bb',
              'service_area_id': 'sa-tandag-city',
              'status': 'completed',
              'pickup_address': 'Mabua',
              'dropoff_address': 'Public Market',
              'fare_centavos': 5500,
              'completed_at': '2026-11-01T02:25:00.000Z',
            },
          ],
        },
      )));

      await open(tester);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Poblacion → SM Terminal'), findsNothing);

      stall.complete();
      await settle();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Mabua → Public Market'), findsOneWidget);
    });
  });
}

/// Answers each table with fixed rows, and holds every read until the test
/// releases [stall] when one is given.
class _FixedBackend implements SurgoBackend {
  _FixedBackend({this.rowsByTable = const {}, this.stall});

  final Map<String, List<Map<String, dynamic>>> rowsByTable;
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
    final found = rowsByTable[table] ?? const [];
    return limit == null ? found : found.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    await stall?.future;
    final found = rowsByTable[table] ?? const [];
    if (found.isEmpty) return null;
    for (final row in found) {
      if (eq.entries.every((where) => row[where.key] == where.value)) {
        return row;
      }
    }
    return found.first;
  }
}