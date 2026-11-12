import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/data/models.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/rental_repository.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_mappers.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/active_rental_screen.dart';
import 'package:surgo/screens/rental_detail_screen.dart';
import 'package:surgo/screens/rental_list_screen.dart';
import 'package:surgo/screens/vehicle_owner_bookings_screen.dart';
import 'package:surgo/screens/vehicle_owner_home_screen.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/domain_cache.dart';
import 'package:surgo/state/rental_status.dart';
import 'package:surgo/widgets/common.dart';

class _HostedAuth extends MockAuthRepository {
  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<void> signOut() async {}
}

RentalRecord _record({
  String id = 'rental-1',
  RentalStatus status = RentalStatus.requested,
}) => RentalRecord(
  id: id,
  renterId: 'auth-renter',
  ownerId: 'auth-owner',
  vehicleId: 'vehicle-live',
  serviceAreaId: 'area-live',
  status: status,
  startAt: DateTime.utc(2026, 11, 12, 9),
  endAt: DateTime.utc(2026, 11, 14, 9),
  durationHours: 48,
  vehicleName: id == 'rental-1'
      ? 'Real rental vehicle'
      : 'Other rental vehicle',
  vehicleType: 'Motorcycle',
  ownerName: 'Real Owner',
  renterName: 'Real Renter',
  totalFareCentavos: 23456,
  // Deliberately non-formula value: receipts must use the agreed row fee.
  platformFeeCentavos: 4321,
);

class _Rentals extends MockRentalRepository {
  List<RentalRecord> records = [_record()];
  RepositoryFailure? readFailure;
  RepositoryFailure? cancelFailure;
  RepositoryFailure? respondFailure;
  Completer<List<RentalRecord>>? heldRead;
  Completer<RentalRecord>? heldAction;
  int reads = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  int cancellations = 0;
  int responses = 0;
  int creates = 0;
  final advances = <RentalStatus>[];
  final renterKeys = <String>[];
  final ownerKeys = <String>[];

  Future<List<RentalRecord>> _read() async {
    reads++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (readFailure != null) throw readFailure!;
      return heldRead == null ? List.of(records) : await heldRead!.future;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<List<RentalRecord>> fetchRentalsByRenter(
    String renterId, {
    int? limit,
  }) {
    renterKeys.add(renterId);
    return _read();
  }

  @override
  Future<List<RentalRecord>> fetchRentalsByOwner(String ownerId, {int? limit}) {
    ownerKeys.add(ownerId);
    return _read();
  }

  @override
  Future<RentalRecord?> fetchRental(String rentalId) async {
    for (final record in records) {
      if (record.id == rentalId) return record;
    }
    return null;
  }

  @override
  Future<RentalRecord> advance({
    required String rentalId,
    required RentalStatus status,
  }) async {
    advances.add(status);
    final result = heldAction == null
        ? _record(id: rentalId, status: status)
        : await heldAction!.future;
    records = [result];
    return result;
  }

  @override
  Future<RentalRecord> respond({
    required String rentalId,
    required bool accept,
  }) async {
    responses++;
    if (respondFailure != null) throw respondFailure!;
    final result = heldAction == null
        ? _record(
            id: rentalId,
            status: accept ? RentalStatus.accepted : RentalStatus.declined,
          )
        : await heldAction!.future;
    records = [result];
    return result;
  }

  @override
  Future<RentalRecord> cancel({
    required String rentalId,
    String? reason,
  }) async {
    cancellations++;
    if (cancelFailure != null) throw cancelFailure!;
    final result = heldAction == null
        ? _record(id: rentalId, status: RentalStatus.cancelled)
        : await heldAction!.future;
    records = [result];
    return result;
  }

  @override
  Future<RentalRecord> createRequest({
    required String vehicleId,
    required DateTime startAt,
    required DateTime endAt,
    required String pickupLocation,
    required String pickupBarangayId,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
  }) async {
    creates++;
    expect(
      startAt.isAfter(DateTime.now().subtract(const Duration(hours: 1))),
      isTrue,
    );
    expect(pickupLatitude, isNull);
    expect(pickupLongitude, isNull);
    final result = heldAction == null ? _record() : await heldAction!.future;
    records = [result];
    return result;
  }
}

class _Watch {
  _Watch(this.table, this.column, this.value, {bool failCancellation = false}) {
    events = StreamController<void>(
      onCancel: () async {
        cancellations++;
        await Future<void>.value();
        if (failCancellation) throw StateError('Realtime teardown failed');
      },
    );
  }
  final String table;
  final String column;
  final String value;
  late final StreamController<void> events;
  int cancellations = 0;
}

class _Realtime implements SurgoRealtimeBackend {
  final watches = <_Watch>[];
  bool failCancellation = false;

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    final watch = _Watch(
      table,
      column,
      value,
      failCancellation: failCancellation,
    );
    watches.add(watch);
    return watch.events.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;
  final db = DbService.instance;
  late _Rentals rentals;
  late _Realtime realtime;
  late List<RentalHistoryItem> history;
  late List<OwnerBookingRequest> ownerRequests;

  Future<void> settle() async {
    for (var turn = 0; turn < 20; turn++) {
      await Future<void>.value();
    }
  }

  Future<void> identify(String id, {bool owner = false}) async {
    state.currentAccount = db.accounts.first.copyWith(
      authUserId: id,
      approvedCapabilities: const {
        CapabilityType.passenger,
        CapabilityType.vehicleOwner,
      },
    );
    state.authStatus = AuthStatus.signedIn;
    state.mode = owner ? UserMode.vehicleOwner : UserMode.passenger;
    state.identity = SurgoIdentity(
      userId: id,
      capabilities: const {
        CapabilityType.passenger,
        CapabilityType.vehicleOwner,
      },
      eligibleCapabilities: const {},
      roles: const {'passenger', 'vehicle_owner'},
      providers: const {'phone'},
    );
    state.notifyListeners();
    await settle();
  }

  Future<void> use({bool hosted = true, bool owner = false}) async {
    final mock = RepositoryRegistry.mock(db);
    state.configureAuth(_HostedAuth());
    state.configureRepositories(
      hosted
          ? RepositoryRegistry(
              profiles: mock.profiles,
              catalog: mock.catalog,
              vehicles: mock.vehicles,
              rides: mock.rides,
              rentals: rentals,
              pasuyo: mock.pasuyo,
              notifications: mock.notifications,
              wallet: mock.wallet,
              verifications: mock.verifications,
              attachments: mock.attachments,
              isSupabaseBacked: true,
              realtime: realtime,
            )
          : mock,
    );
    await identify(owner ? 'auth-owner' : 'auth-renter', owner: owner);
    state.cache.restart();
    if (rentals.heldRead == null) {
      await state.cache.ensure(DomainSlot.passengerRentalBookings);
      await state.cache.ensure(DomainSlot.ownerRentalBookings);
    }
    await settle();
  }

  Future<void> land(WidgetTester tester) async {
    await tester.pump();
    await settle();
    await tester.pump();
    await settle();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> open(
    WidgetTester tester,
    Widget screen, {
    Object? argument,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1800));
    addTearDown(() async {
      await close(tester);
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  settings: RouteSettings(arguments: argument),
                  builder: (_) => screen,
                ),
              ),
              child: const Text('Open rentals'),
            ),
          ),
        ),
        routes: {
          '/home': (_) => const Scaffold(body: Text('Home destination')),
          '/owner': (_) => const Scaffold(body: Text('Owner Home destination')),
        },
      ),
    );
    await tester.tap(find.text('Open rentals'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await land(tester);
  }

  setUpAll(() async => db.load());
  setUp(() {
    rentals = _Rentals();
    realtime = _Realtime();
    history = List.of(db.rentalHistory);
    ownerRequests = List.of(db.ownerBookingRequests);
    state.activeRentalBooking = null;
  });
  tearDown(() async {
    // A failed assertion must not strand a singleton cache read in later tests.
    final heldRead = rentals.heldRead;
    rentals.heldRead = null;
    if (heldRead != null && !heldRead.isCompleted) {
      heldRead.complete(List.of(rentals.records));
    }
    final heldAction = rentals.heldAction;
    rentals.heldAction = null;
    if (heldAction != null && !heldAction.isCompleted) {
      heldAction.complete(_record());
    }
    await settle();
    state.cancelRentalBooking();
    state.configureAuth(MockAuthRepository());
    state.currentAccount = null;
    state.identity = null;
    db.rentalHistory
      ..clear()
      ..addAll(history);
    db.ownerBookingRequests
      ..clear()
      ..addAll(ownerRequests);
    state.configureRepositories(RepositoryRegistry.mock(db));
    state.cache.restart();
    // Drain real-zone mock flights before the next widget test's fake zone.
    await state.cache.prefill();
    await settle();
    for (final watch in realtime.watches) {
      await watch.events.close();
    }
  });

  test(
    'hosted quotes round elapsed time at exact and fractional day boundaries',
    () {
      final start = DateTime.utc(2026, 11, 12, 9);
      for (final sample in <(Duration, int)>[
        (const Duration(microseconds: 1), 1),
        (const Duration(hours: 24), 1),
        (const Duration(hours: 24, microseconds: 1), 2),
        (const Duration(hours: 48), 2),
        (const Duration(hours: 48, seconds: 1), 3),
        (const Duration(hours: 49), 3),
      ]) {
        final (elapsed, expectedDays) = sample;
        final days = hostedRentalQuoteDays(start, start.add(elapsed));
        expect(days, expectedDays, reason: '$elapsed');
        final sqlHours = (elapsed.inMicroseconds / Duration.microsecondsPerHour)
            .ceil();
        expect(
          HostedFees.rentalPlatformFee(days! * 24),
          HostedFees.rentalPlatformFee(sqlHours),
        );
      }
      // These instants cross three calendar dates but span only 24h 1s.
      final nearMidnight = DateTime.utc(2026, 11, 12, 23, 59, 59);
      expect(
        hostedRentalQuoteDays(nearMidnight, DateTime.utc(2026, 11, 14)),
        2,
      );
      // Offset changes are priced by real elapsed time, not local midnight.
      expect(
        hostedRentalQuoteDays(
          DateTime.parse('2026-11-01T00:00:00-04:00'),
          DateTime.parse('2026-11-02T00:00:00-05:00'),
        ),
        2,
      );
      expect(hostedRentalQuoteDays(start, start), isNull);
      expect(
        hostedRentalQuoteDays(
          start,
          start.subtract(const Duration(seconds: 1)),
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'hosted auth with seeded repositories keeps selector and timed demo approval',
    (tester) async {
      await use(hosted: false);
      await open(tester, const RentalListScreen());
      for (final filter in [
        'All',
        'Motorcycle',
        'Multicab',
        'Van',
        'Tricycle',
      ]) {
        expect(find.text(filter), findsWidgets);
      }
      expect(find.text(MockData.rentalVehicles.first.name), findsOneWidget);
      await tester.tap(find.text(MockData.rentalVehicles.first.name));
      await land(tester);
      expect(find.text('Pick-up barangay'), findsNothing);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(
        find.text('This vehicle is in the workshop and cannot be booked yet.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Unavailable'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(RentalDetailScreen),
          matching: find.byIcon(Icons.arrow_back),
        ),
      );
      await land(tester);
      final bookable = MockData.rentalVehicles.singleWhere(
        (v) => v.id == 'RV001',
      );
      await tester.tap(find.text(bookable.name));
      await land(tester);
      final request = find.widgetWithText(ElevatedButton, 'Request Rental');
      expect(tester.widget<ElevatedButton>(request).onPressed, isNotNull);
      await tester.ensureVisible(request);
      await tester.tap(request);
      await land(tester);
      expect(state.activeRentalBooking, isNotNull);
      expect(find.text('Rental requested'), findsOneWidget);
      await tester.tap(find.text('View Request'));
      await land(tester);
      expect(find.text('Waiting for owner approval…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await land(tester);
      expect(state.activeRentalBooking!.status, RentalStatus.accepted);
      expect(find.text('Pick up the vehicle'), findsOneWidget);
      expect(realtime.watches, isEmpty);
      await close(tester);
    },
  );

  testWidgets('seeded owner screens remain local with hosted auth', (
    tester,
  ) async {
    await use(hosted: false, owner: true);
    await open(tester, const VehicleOwnerBookingsScreen(embedded: false));
    expect(find.text(db.ownerBookingRequests.first.vehicleName), findsWidgets);
    await close(tester);
    await open(tester, const VehicleOwnerHomeScreen(embedded: false));
    expect(find.text(db.vehicleOwner.name), findsOneWidget);
    expect(realtime.watches, isEmpty);
    await close(tester);
  });

  testWidgets(
    'renter watches authenticated rows and reconciles owner approval',
    (tester) async {
      await use();
      await open(tester, const ActiveRentalScreen());
      final watch = realtime.watches.single;
      expect(
        (watch.table, watch.column, watch.value),
        ('rental_bookings', 'renter_id', 'auth-renter'),
      );
      expect(rentals.renterKeys.last, 'auth-renter');
      expect(find.text('REQUESTED'), findsOneWidget);
      expect(find.textContaining('Waiting for owner approval'), findsOneWidget);
      expect(find.textContaining('position is unavailable'), findsOneWidget);
      rentals.records = [_record(status: RentalStatus.accepted)];
      watch.events.add(null);
      await land(tester);
      expect(find.text('APPROVED'), findsOneWidget);
      expect(find.text('Pick up the vehicle'), findsOneWidget);
      expect(rentals.advances, isEmpty);
      await close(tester);
      expect(watch.cancellations, 1);
    },
  );

  testWidgets(
    'pickup and return actions are latched and renter cannot finalize',
    (tester) async {
      rentals.records = [_record(status: RentalStatus.accepted)];
      await use();
      await open(tester, const ActiveRentalScreen());
      rentals.heldAction = Completer<RentalRecord>();
      final pickup = find.text('Pick up the vehicle');
      await tester.tap(pickup);
      await tester.tap(pickup);
      expect(rentals.advances, [RentalStatus.active]);
      rentals.heldAction!.complete(_record(status: RentalStatus.active));
      await land(tester);
      rentals.heldAction = null;
      expect(find.text('ACTIVE'), findsOneWidget);
      await tester.tap(find.text('Return the vehicle'));
      await land(tester);
      expect(rentals.advances, [RentalStatus.active, RentalStatus.returned]);
      expect(find.text('RETURNED'), findsOneWidget);
      expect(
        find.textContaining('Waiting for the owner to confirm'),
        findsOneWidget,
      );
      expect(find.text('Complete rental'), findsNothing);
      expect(find.text('Confirm return & complete'), findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'tracked terminal receipt survives realtime completion and another request',
    (tester) async {
      rentals.records = [_record(status: RentalStatus.returned)];
      await use();
      await open(tester, const ActiveRentalScreen());
      rentals.records = [
        _record(status: RentalStatus.completed),
        _record(id: 'rental-2'),
      ];
      realtime.watches.single.events.add(null);
      await land(tester);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(find.text('Rental receipt'), findsOneWidget);
      expect(find.text('Real rental vehicle'), findsOneWidget);
      expect(find.text('Other rental vehicle'), findsNothing);
      final split = state.hostedRentalBreakdown(
        rentalBookingFromRecord(_record(status: RentalStatus.completed)),
      );
      for (final amount in [
        split.providerGets,
        split.surgoKeeps,
        split.customerPays,
      ]) {
        expect(find.text(Money.format(amount)), findsOneWidget);
      }
      expect(find.text('Open rentals'), findsNothing);
      await tester.tap(find.byTooltip('Home'));
      await land(tester);
      expect(find.text('Home destination'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'explicit terminal entry displays completed, cancelled and declined states',
    (tester) async {
      for (final status in [
        RentalStatus.completed,
        RentalStatus.cancelled,
        RentalStatus.declined,
      ]) {
        rentals.records = [_record(status: status)];
        await use();
        await open(tester, const ActiveRentalScreen(rentalId: 'rental-1'));
        expect(find.text(status.shortLabel.toUpperCase()), findsOneWidget);
        expect(find.text('Cancel Request'), findsNothing);
        expect(find.byType(SbPrimaryButton), findsNothing);
        await close(tester);
      }
    },
  );

  testWidgets(
    'successful empty stays on screen and explicit refresh recovers',
    (tester) async {
      rentals.records = [];
      await use();
      await open(tester, const ActiveRentalScreen());
      expect(find.text('No current rental request.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Open rentals'), findsNothing);
      rentals.records = [_record()];
      await tester.tap(find.text('Refresh'));
      await land(tester);
      expect(find.text('REQUESTED'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('failure is distinct from empty and retry is explicit', (
    tester,
  ) async {
    rentals.readFailure = RepositoryFailure.conflict('Rental read denied');
    await use();
    await open(tester, const ActiveRentalScreen());
    expect(find.text('Rental read denied'), findsOneWidget);
    expect(find.text('No current rental request.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    rentals.readFailure = null;
    await tester.tap(find.text('Refresh'));
    await land(tester);
    expect(find.text('REQUESTED'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'refresh timeout retains the cached rental and recovery controls',
    (tester) async {
      await use();
      await state.cache.ensure(DomainSlot.passengerRentalBookings);
      rentals.heldRead = Completer<List<RentalRecord>>();
      await open(tester, const ActiveRentalScreen());
      expect(find.text('REQUESTED'), findsOneWidget);
      expect(find.text('Real rental vehicle'), findsOneWidget);
      expect(find.text('Loading your rental…'), findsNothing);
      await tester.pump(const Duration(seconds: 21));
      await land(tester);
      expect(
        find.text('Rental refresh took too long. Try again.'),
        findsOneWidget,
      );
      expect(find.text('REQUESTED'), findsOneWidget);
      expect(find.text('Real rental vehicle'), findsOneWidget);
      final refresh = find.widgetWithIcon(IconButton, Icons.refresh);
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(find.byTooltip('Home'), findsOneWidget);
      final cancel = find.byType(SbOutlineButton);
      expect(tester.widget<SbOutlineButton>(cancel).onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      rentals.heldRead!.complete([_record()]);
      rentals.heldRead = null;
      await land(tester);
      await tester.tap(refresh);
      await land(tester);
      expect(
        find.text('Rental refresh took too long. Try again.'),
        findsNothing,
      );
      expect(tester.widget<SbOutlineButton>(cancel).onPressed, isNotNull);
      await close(tester);
    },
  );

  testWidgets('cold loading timeout leaves explicit refresh and Home', (
    tester,
  ) async {
    rentals.records = [];
    rentals.heldRead = Completer<List<RentalRecord>>();
    await use();
    await open(tester, const ActiveRentalScreen());
    expect(find.text('Loading your rental…'), findsOneWidget);
    expect(find.text('Real rental vehicle'), findsNothing);
    await tester.pump(const Duration(seconds: 21));
    await land(tester);
    expect(
      find.text('Rental refresh took too long. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Loading your rental…'), findsNothing);
    final refresh = find.byType(SbOutlineButton).first;
    expect(tester.widget<SbOutlineButton>(refresh).onPressed, isNotNull);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    rentals.heldRead!.complete([]);
    rentals.heldRead = null;
    await land(tester);
    await tester.tap(find.text('Refresh'));
    await land(tester);
    expect(find.text('No current rental request.'), findsOneWidget);
    await close(tester);
  });

  testWidgets('cancellation failure is surfaced without losing the request', (
    tester,
  ) async {
    await use();
    await open(tester, const ActiveRentalScreen());
    rentals.heldAction = Completer<RentalRecord>();
    final cancel = find.text('Cancel Request');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.tap(cancel);
    expect(rentals.cancellations, 1);
    rentals.heldAction!.completeError(
      RepositoryFailure.conflict('Owner already changed this request'),
    );
    rentals.heldAction = null;
    await land(tester);
    expect(find.text('Owner already changed this request'), findsOneWidget);
    expect(find.text('REQUESTED'), findsOneWidget);
    expect(find.text('Open rentals'), findsNothing);
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await land(tester);
    expect(rentals.cancellations, 2);
    expect(find.text('CANCELLED'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'row event storms serialize and coalesce and polling stops on disposal',
    (tester) async {
      await use();
      await open(tester, const ActiveRentalScreen());
      final watch = realtime.watches.single;
      final before = rentals.reads;
      rentals.heldRead = Completer<List<RentalRecord>>();
      watch.events.add(null);
      await land(tester);
      for (var event = 0; event < 30; event++) {
        watch.events.add(null);
      }
      await land(tester);
      expect(rentals.reads, before + 1);
      expect(rentals.maxInFlight, 1);
      final held = rentals.heldRead!;
      rentals.heldRead = null;
      rentals.records = [_record(status: RentalStatus.accepted)];
      held.complete([_record()]);
      await land(tester);
      expect(rentals.reads, before + 2);
      expect(find.text('APPROVED'), findsOneWidget);
      rentals.records = [_record(status: RentalStatus.active)];
      await tester.pump(const Duration(seconds: 15));
      await land(tester);
      expect(find.text('ACTIVE'), findsOneWidget);
      await close(tester);
      final stopped = rentals.reads;
      await tester.pump(const Duration(seconds: 30));
      expect(rentals.reads, stopped);
      expect(watch.cancellations, 1);
    },
  );

  testWidgets('session change retires subscription and hides previous rental', (
    tester,
  ) async {
    await use();
    await open(tester, const ActiveRentalScreen());
    final watch = realtime.watches.single;
    rentals.heldRead = Completer<List<RentalRecord>>();
    watch.events.add(null);
    await land(tester);
    await identify('different-auth-user');
    await land(tester);
    expect(watch.cancellations, 1);
    expect(find.textContaining('Your session changed.'), findsOneWidget);
    rentals.heldRead!.complete([_record(status: RentalStatus.completed)]);
    rentals.heldRead = null;
    await land(tester);
    expect(find.text('Real rental vehicle'), findsNothing);
    final stopped = rentals.reads;
    await tester.pump(const Duration(seconds: 30));
    expect(rentals.reads, stopped);
    await close(tester);
  });

  testWidgets('same-user relogin cannot revive a retired rental scope', (
    tester,
  ) async {
    realtime.failCancellation = true;
    await use();
    await open(tester, const ActiveRentalScreen());
    final watch = realtime.watches.single;
    rentals.heldRead = Completer<List<RentalRecord>>();
    watch.events.add(null);
    await land(tester);
    await state.logout();
    await land(tester);
    expect(watch.cancellations, 1);
    expect(tester.takeException(), isNull);
    await identify('auth-renter');
    await land(tester);
    expect(find.textContaining('Your session changed.'), findsOneWidget);
    expect(find.text('Real rental vehicle'), findsNothing);
    expect(find.text('Cancel Request'), findsNothing);
    rentals.heldRead!.complete([_record(status: RentalStatus.completed)]);
    rentals.heldRead = null;
    await land(tester);
    final stopped = rentals.reads;
    await tester.pump(const Duration(seconds: 31));
    await land(tester);
    expect(rentals.reads, stopped);
    expect(realtime.watches, hasLength(1));
    expect(find.textContaining('Your session changed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
    await open(tester, const ActiveRentalScreen(rentalId: 'rental-1'));
    expect(realtime.watches, hasLength(2));
    expect(find.text('REQUESTED'), findsOneWidget);
    await close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subscription cancellation errors are contained on disposal', (
    tester,
  ) async {
    realtime.failCancellation = true;
    await use();
    await open(tester, const ActiveRentalScreen());
    final watch = realtime.watches.single;
    await close(tester);
    await land(tester);
    expect(watch.cancellations, 1);
    expect(tester.takeException(), isNull);
    final stopped = rentals.reads;
    await tester.pump(const Duration(seconds: 31));
    expect(rentals.reads, stopped);
  });

  testWidgets(
    'owner Home exits use the owner dashboard for rows and empty reads',
    (tester) async {
      for (final empty in [false, true]) {
        for (final screen in <Widget>[
          const ActiveRentalScreen(rentalId: 'rental-1'),
          const VehicleOwnerBookingsScreen(embedded: false),
        ]) {
          rentals.records = empty
              ? []
              : [_record(status: RentalStatus.returned)];
          await use(owner: true);
          await open(
            tester,
            screen,
            argument: ownerBookingFromRecord(
              _record(status: RentalStatus.returned),
            ),
          );
          expect(state.homeRoute, '/owner');
          final home = find.byIcon(Icons.home_outlined);
          expect(home, findsOneWidget);
          await tester.ensureVisible(home);
          await tester.tap(home);
          await land(tester);
          expect(find.text('Owner Home destination'), findsOneWidget);
          expect(find.text('Home destination'), findsNothing);
          await close(tester);
        }
      }
    },
  );

  testWidgets(
    'owner watches incoming requests and acceptance never auto-starts',
    (tester) async {
      rentals.records = [];
      await use(owner: true);
      await open(tester, const VehicleOwnerBookingsScreen(embedded: false));
      final watch = realtime.watches.single;
      expect(
        (watch.table, watch.column, watch.value),
        ('rental_bookings', 'owner_id', 'auth-owner'),
      );
      expect(rentals.ownerKeys.last, 'auth-owner');
      rentals.records = [_record()];
      watch.events.add(null);
      await land(tester);
      expect(find.text('Real Renter'), findsOneWidget);
      rentals.heldAction = Completer<RentalRecord>();
      await tester.tap(find.text('Accept'));
      await tester.tap(find.text('Accept'));
      expect(rentals.responses, 1);
      expect(find.text('APPROVED'), findsNothing);
      rentals.heldAction!.complete(_record(status: RentalStatus.accepted));
      await land(tester);
      expect(find.text('APPROVED'), findsOneWidget);
      expect(rentals.advances, isEmpty);
      rentals.records = [_record(status: RentalStatus.returned)];
      watch.events.add(null);
      await land(tester);
      final entry = find.widgetWithText(
        TextButton,
        'Confirm return & complete',
      );
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await land(tester);
      rentals.heldAction = null;
      final complete = find.widgetWithText(
        SbPrimaryButton,
        'Confirm return & complete',
      );
      expect(complete, findsOneWidget);
      await tester.ensureVisible(complete);
      await tester.tap(complete);
      await land(tester);
      expect(rentals.advances, [RentalStatus.completed]);
      expect(find.text('Rental receipt'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('owner refusal remains visible and realtime reconciles decline', (
    tester,
  ) async {
    await use(owner: true);
    await open(tester, const VehicleOwnerBookingsScreen(embedded: false));
    rentals.respondFailure = RepositoryFailure.conflict(
      'Request is no longer pending',
    );
    await tester.tap(find.text('Accept'));
    await land(tester);
    expect(find.text('Request is no longer pending'), findsOneWidget);
    expect(find.text('REQUESTED'), findsOneWidget);
    rentals.respondFailure = null;
    await tester.tap(find.text('Decline'));
    await land(tester);
    expect(find.text('DECLINED'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'owner home reconciles real requests with the same scoped watch',
    (tester) async {
      rentals.records = [];
      await use(owner: true);
      await open(tester, const VehicleOwnerHomeScreen(embedded: false));
      final watch = realtime.watches.single;
      expect(watch.column, 'owner_id');
      rentals.records = [_record()];
      watch.events.add(null);
      await land(tester);
      final requested = find.text('Real Renter wants to rent');
      await tester.ensureVisible(requested);
      expect(requested, findsOneWidget);
      await close(tester);
      expect(watch.cancellations, 1);
    },
  );

  testWidgets(
    'owner-home response latch follows its rental when rows reorder',
    (tester) async {
      rentals.records = [_record(), _record(id: 'rental-2')];
      await use(owner: true);
      await open(tester, const VehicleOwnerHomeScreen(embedded: false));
      Finder row(String id) => find.byWidgetPredicate(
        (widget) => widget is Padding && widget.key == ValueKey(id),
      );
      final first = row('rental-1');
      final other = row('rental-2');
      final accept = find.descendant(
        of: first,
        matching: find.widgetWithText(ElevatedButton, 'Accept'),
      );
      await tester.ensureVisible(accept);
      rentals.heldAction = Completer<RentalRecord>();
      await tester.tap(accept);
      await land(tester);
      expect(rentals.responses, 1);
      rentals.records = [_record(id: 'rental-2'), _record()];
      realtime.watches.single.events.add(null);
      await land(tester);
      expect(
        state.cache
            .dataOf<List<RentalRecord>>(DomainSlot.ownerRentalBookings)!
            .map((record) => record.id),
        ['rental-2', 'rental-1'],
      );
      final saving = find.descendant(
        of: first,
        matching: find.widgetWithText(ElevatedButton, 'Saving…'),
      );
      expect(saving, findsOneWidget);
      expect(tester.widget<ElevatedButton>(saving).onPressed, isNull);
      final decline = find.descendant(
        of: first,
        matching: find.widgetWithText(OutlinedButton, 'Decline'),
      );
      expect(tester.widget<OutlinedButton>(decline).onPressed, isNull);
      final otherAccept = find.descendant(
        of: other,
        matching: find.widgetWithText(ElevatedButton, 'Accept'),
      );
      expect(tester.widget<ElevatedButton>(otherAccept).onPressed, isNotNull);
      await tester.ensureVisible(saving);
      await tester.tap(saving);
      expect(rentals.responses, 1);
      rentals.heldAction!.complete(_record(status: RentalStatus.accepted));
      rentals.heldAction = null;
      await land(tester);
      expect(find.text('Real Renter · Approved'), findsOneWidget);
      expect(find.text('Saving…'), findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'hosted request submission is latched and carries the returned booking id',
    (tester) async {
      rentals.records = [];
      await use();
      await open(
        tester,
        RentalDetailScreen(vehicle: MockData.rentalVehicles.first),
      );
      final barangay = state.cache
          .dataOf<List<BarangayRecord>>(DomainSlot.barangays)!
          .first;
      final picker = find.byType(DropdownButton<String>);
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await land(tester);
      final option = find.text(barangay.name).last;
      await tester.ensureVisible(option);
      await tester.tap(option);
      await land(tester);
      expect(tester.widget<DropdownButton<String>>(picker).value, barangay.id);
      rentals.heldAction = Completer<RentalRecord>();
      final request = find.widgetWithText(ElevatedButton, 'Request Rental');
      expect(tester.widget<ElevatedButton>(request).onPressed, isNotNull);
      await tester.ensureVisible(request);
      await tester.tap(request);
      await tester.tap(request);
      expect(rentals.creates, 1);
      rentals.heldAction!.complete(_record());
      await land(tester);
      expect(find.text('Rental requested'), findsOneWidget);
      await tester.tap(find.text('View Request'));
      await tester.pump(const Duration(milliseconds: 400));
      await land(tester);
      expect(find.text('Real rental vehicle'), findsOneWidget);
      rentals.records = [
        _record(status: RentalStatus.completed),
        _record(id: 'rental-2'),
      ];
      realtime.watches.single.events.add(null);
      await land(tester);
      expect(find.text('Rental receipt'), findsOneWidget);
      expect(find.text('Other rental vehicle'), findsNothing);
      await close(tester);
    },
  );
}
