import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/vehicle_documents_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/widgets/common.dart';

/// Stage 2 proof for the paperwork list: the cards come from the vehicle
/// repository's documents, read through the owner's fleet, so a Supabase build
/// shows the filed rows and a failed read is shown as a failure rather than the
/// seeded set.
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

  setUpAll(() async => db.load());
  tearDown(() => use(RepositoryRegistry.mock(db)));

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: VehicleDocumentsScreen()));
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

  /// One vehicle row, because the documents are read through the fleet.
  const fleetRow = <String, dynamic>{
    'id': 'veh-1',
    'owner_profile_id': 'auth-uuid-1',
    'service_area_id': 'sa-1',
    'name': 'Hilux Cargo',
    'vehicle_type': 'Pickup',
    'category': 'Truck',
    'make': 'Toyota',
    'model': 'Hilux',
    'model_year': 2023,
    'color': 'White',
    'plate_number': 'NGD 7788',
    'price_per_day_centavos': 180000,
    'status': 'active',
    'rating': 4.6,
    'total_rentals': 12,
  };

  group('vehicle documents', () {
    testWidgets('a seeded build lists the papers it always showed',
        (tester) async {
      await open(tester);

      expect(find.byType(SbCard), findsNWidgets(db.vehicleDocuments.length));
      expect(find.text(db.vehicleDocuments.first.title), findsOneWidget);
      expect(find.text('No. ${db.vehicleDocuments.first.number}'),
          findsOneWidget);
      expect(find.text('VERIFIED'), findsWidgets);
    });

    testWidgets('a Supabase build lists the filed rows it was given',
        (tester) async {
      await use(RepositoryRegistry.supabase(_FleetDocumentsBackend(
        vehicles: [fleetRow],
        documents: [
          {
            'id': 'doc-1',
            'vehicle_id': 'veh-1',
            'document_type': 'Vehicle Insurance (TPL)',
            'document_number': 'INS-99',
            'expires_at': '2027-06-02',
            'status': 'pending',
          },
        ],
      )));

      await open(tester);

      expect(find.text('Vehicle Insurance (TPL)'), findsOneWidget);
      expect(find.text('No. INS-99'), findsOneWidget);
      expect(find.text('Expires Jun 2, 2027'), findsOneWidget);
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text(db.vehicleDocuments.first.title), findsNothing,
          reason: 'a production read must not show the seeded paperwork');
    });

    testWidgets('documents filed against no vehicle read as none',
        (tester) async {
      await use(RepositoryRegistry.supabase(
          _FleetDocumentsBackend(vehicles: const [], documents: const [])));

      await open(tester);

      expect(find.text('No documents on file yet.'), findsOneWidget);
      expect(find.byType(SbCard), findsNothing);
    });

    testWidgets('an unreachable read fails visibly and recovers on retry',
        (tester) async {
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester);

      expect(find.text('The data service is unavailable'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(SbCard), findsNothing);

      await use(RepositoryRegistry.supabase(_FleetDocumentsBackend(
        vehicles: [fleetRow],
        documents: [
          {
            'id': 'doc-1',
            'vehicle_id': 'veh-1',
            'document_type': 'Barangay Clearance',
            'document_number': 'BC-2026-0142',
            'expires_at': '2027-08-12',
            'status': 'approved',
          },
        ],
      )));
      await tester.tap(find.text('Try again'));
      await land(tester);

      expect(find.text('No. BC-2026-0142'), findsOneWidget);
      expect(find.text('VERIFIED'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });
}

/// Answers the two queries the paperwork read makes: the owner's fleet, then
/// the documents filed against those vehicle ids.
class _FleetDocumentsBackend implements SurgoBackend {
  const _FleetDocumentsBackend({
    required this.vehicles,
    required this.documents,
  });

  final List<Map<String, dynamic>> vehicles;
  final List<Map<String, dynamic>> documents;

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
    if (table == 'vehicles') return vehicles;
    if (table != 'vehicle_documents') return const [];
    final ids = whereIn['vehicle_id'] ?? const [];
    return [
      for (final document in documents)
        if (ids.contains(document['vehicle_id'])) document
    ];
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async =>
      null;
}
