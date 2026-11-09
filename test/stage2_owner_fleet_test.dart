import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/vehicle_owner_home_screen.dart';
import 'package:surgo/screens/vehicle_owner_vehicles_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/widgets/surfaces.dart';

/// Stage 2 proof for the owner's fleet: the Vehicles tab and the home preview
/// list come from the vehicle repository, so a Supabase build shows the owner's
/// own rows and a failed read is shown as a failure instead of the seed fleet.
///
/// The fleet itself is written through [AppState] in mock mode only, so the
/// seeded vehicles are snapshotted and put back after each test.
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

  late List<Map<String, Object?>> fleet;

  setUpAll(() async => db.load());

  setUp(() {
    fleet = [
      for (final vehicle in db.ownerVehicles)
        {
          'id': vehicle.id,
          'name': vehicle.name,
          'type': vehicle.type,
          'category': vehicle.category,
          'plate': vehicle.plate,
          'pricePerDay': vehicle.pricePerDay,
          'status': vehicle.status,
        },
    ];
  });

  tearDown(() async {
    for (final saved in fleet) {
      for (final vehicle in db.ownerVehicles) {
        if (vehicle.id != saved['id']) continue;
        vehicle.status = saved['status'] as String;
      }
    }
    await use(RepositoryRegistry.mock(db));
  });

  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(home: screen));
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  /// Lets a settled read reach the widget after a state change.
  Future<void> land(WidgetTester tester) async {
    await tester.pump();
    await settle();
    await tester.pump();
  }

  group('owner fleet', () {
    testWidgets('a seeded build lists the vehicles the owner manages',
        (tester) async {
      await open(tester, const VehicleOwnerVehiclesScreen(embedded: false));

      expect(find.byType(SbTintedCard), findsNWidgets(db.ownerVehicles.length));
      expect(find.text(db.ownerVehicles.first.name), findsOneWidget);

      final listed = db.ownerVehicles.first.status;
      await tester.tap(find.byType(SbTintedCard).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maintenance').last);
      await land(tester);

      expect(db.ownerVehicles.first.status, 'Maintenance',
          reason: 'the read follows the write, not the seed table');
      expect(find.text('Maintenance'), findsWidgets);
      expect(listed, isNot('Maintenance'));
    });

    testWidgets('the home tab counts the same fleet the tab lists',
        (tester) async {
      await open(tester, const Scaffold(body: VehicleOwnerHomeScreen()));

      expect(find.text('${db.ownerVehicles.length}'), findsOneWidget);
      expect(find.text(db.ownerVehicles.first.name), findsOneWidget);
    });

    testWidgets('a Supabase build lists the owner rows it was given',
        (tester) async {
      await use(RepositoryRegistry.supabase(_FixedBackend(vehicleRows: [
        {
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
        },
      ])));

      await open(tester, const VehicleOwnerVehiclesScreen(embedded: false));

      expect(find.text('Hilux Cargo'), findsOneWidget);
      expect(find.text('Truck · Pickup · Plate NGD 7788'), findsOneWidget);
      expect(find.textContaining('₱1,800.00/day'), findsOneWidget);
      expect(find.text(db.ownerVehicles.first.name), findsNothing,
          reason: 'a production read must not show the seeded fleet');
    });

    testWidgets('an owner with no rows is offered a vehicle to add',
        (tester) async {
      await use(RepositoryRegistry.supabase(const _FixedBackend(vehicleRows: [])));

      await open(tester, const VehicleOwnerVehiclesScreen(embedded: false));

      expect(find.text("You haven't listed any vehicles yet."), findsOneWidget);
      expect(find.byType(SbTintedCard), findsNothing);
    });

    testWidgets('an unreachable fleet fails visibly instead of showing seeds',
        (tester) async {
      expect(db.ownerVehicles, isNotEmpty);
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester, const VehicleOwnerVehiclesScreen(embedded: false));

      expect(find.text('The data service is unavailable'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(SbTintedCard), findsNothing);
    });
  });
}

/// A backend that answers every read with the same rows, because the fleet
/// screen only makes one query.
class _FixedBackend implements SurgoBackend {
  const _FixedBackend({required this.vehicleRows});

  final List<Map<String, dynamic>> vehicleRows;

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
  }) async =>
      vehicleRows;

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async =>
      vehicleRows.isEmpty ? null : vehicleRows.first;
}
