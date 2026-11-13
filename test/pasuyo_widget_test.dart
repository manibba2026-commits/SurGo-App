import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/pasuyo_repository.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/pasuyo_post_screen.dart';
import 'package:surgo/screens/pasuyo_screen.dart';
import 'package:surgo/screens/pasuyo_task_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/pasuyo_status.dart';
import 'package:surgo/widgets/common.dart';
import 'package:surgo/widgets/flow_scaffold.dart';
import 'package:surgo/widgets/pasuyo_stepper.dart';

class _HostedAuth extends MockAuthRepository {
  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();
}

ServiceRequestRecord _task({
  PasuyoStatus status = PasuyoStatus.available,
  String title = 'Buy groceries',
  String customer = 'customer-1',
  String? provider,
  int? actual,
  String id = 'task-1',
}) => ServiceRequestRecord(
  id: id,
  customerId: customer,
  providerId: provider ?? (status.isOpen ? null : 'helper-1'),
  serviceAreaId: 'area-1',
  category: PasuyoCategory.groceries,
  status: status,
  title: title,
  pickupAddress: 'Grocery pickup',
  dropoffAddress: 'Customer address',
  quotedFeeCentavos: 18765,
  platformFeeCentavos: 731,
  paymentMethod: 'cash',
  providerName: status.isOpen ? null : 'Test Helper',
  items: [
    ServiceRequestItemRecord(
      id: 'item-1',
      serviceRequestId: id,
      name: 'Milk',
      quantity: 2,
      estimatedUnitPriceCentavos: 6000,
      actualUnitPriceCentavos: actual,
    ),
  ],
);

class _Errands extends MockPasuyoRepository {
  ServiceRequestRecord? record = _task();
  Future<ServiceRequestRecord?> Function()? read;
  Future<void> Function()? beforeWrite;
  RepositoryFailure? cancelFailure;
  int reads = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  int accepts = 0;
  int cancellations = 0;
  final actualWrites = <List<Map<String, dynamic>>>[];

  @override
  Future<ServiceRequestRecord?> fetchRequest(String requestId) async {
    expectSync(requestId, 'task-1');
    reads++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return read == null ? record : await read!();
    } finally {
      inFlight--;
    }
  }

  @override
  Future<List<ServiceRequestRecord>> fetchRequestsByCustomer(
    String customerId, {
    int? limit,
  }) async => [if (record?.customerId == customerId) record!];

  @override
  Future<List<ServiceRequestRecord>> fetchRequestsByProvider(
    String providerId, {
    int? limit,
  }) async => [if (record?.providerId == providerId) record!];

  @override
  Future<List<ServiceRequestRecord>> fetchOpenFeed(
    String serviceAreaId, {
    PasuyoCategory? category,
    int? limit,
  }) async => [if (record?.status.isOpen == true) record!];

  @override
  Future<ServiceRequestRecord> accept(String requestId) async {
    accepts++;
    await beforeWrite?.call();
    return record = _task(status: PasuyoStatus.accepted);
  }

  @override
  Future<ServiceRequestRecord> advance({
    required String requestId,
    required PasuyoStatus status,
  }) async => record = _task(status: status);

  @override
  Future<ServiceRequestRecord> setItemActuals({
    required String requestId,
    required List<Map<String, dynamic>> items,
  }) async {
    actualWrites.add(items);
    return record = _task(
      status: record!.status,
      actual: items.first['actual_unit_price_centavos'] as int,
    );
  }

  @override
  Future<ServiceRequestRecord> cancel({
    required String requestId,
    String? reason,
  }) async {
    cancellations++;
    if (cancelFailure != null) throw cancelFailure!;
    return record = _task(status: PasuyoStatus.cancelled);
  }
}

class _Watch {
  _Watch(this.table, this.column, this.value) {
    events = StreamController<void>(onCancel: () => cancellations++);
  }
  final String table;
  final String column;
  final String value;
  late final StreamController<void> events;
  int cancellations = 0;
}

class _Realtime implements SurgoRealtimeBackend {
  final watches = <_Watch>[];

  @override
  Stream<void> watchRows({
    required String table,
    required String column,
    required String value,
  }) {
    final watch = _Watch(table, column, value);
    watches.add(watch);
    return watch.events.stream;
  }
}

RepositoryRegistry _registry(
  _Errands errands,
  _Realtime? realtime, {
  bool hosted = true,
}) {
  final seed = RepositoryRegistry.mock();
  return RepositoryRegistry(
    profiles: seed.profiles,
    catalog: seed.catalog,
    vehicles: seed.vehicles,
    rides: seed.rides,
    rentals: seed.rentals,
    pasuyo: errands,
    notifications: seed.notifications,
    wallet: seed.wallet,
    verifications: seed.verifications,
    attachments: seed.attachments,
    personalLists: seed.personalLists,
    isSupabaseBacked: hosted,
    realtime: realtime,
  );
}

void _identity(String? id) {
  final state = AppState.instance;
  state.identity = id == null
      ? null
      : SurgoIdentity(
          userId: id,
          fullName: 'Pasuyo Tester',
          capabilities: const {CapabilityType.passenger},
          eligibleCapabilities: const {},
          roles: const {'passenger'},
          providers: const {'phone'},
          profileExists: true,
        );
  state.currentAccount = id == null
      ? null
      : Account(
          id: id,
          authUserId: id,
          passengerId: id,
          name: 'Pasuyo Tester',
          phone: '',
          email: '',
        );
  state.authStatus = id == null ? AuthStatus.signedOut : AuthStatus.signedIn;
  state.notifyListeners();
}

Widget _app(Widget screen) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: screen,
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _pump(tester);
}

void main() {
  final state = AppState.instance;
  late _Errands errands;
  late _Realtime realtime;
  late RepositoryRegistry savedRegistry;
  late SurgoIdentity? savedIdentity;
  late Account? savedAccount;
  late AuthStatus savedAuthStatus;
  late PasuyoTask? savedActive;
  late List<PasuyoTask> savedTasks;

  setUpAll(() async => DbService.instance.load());

  setUp(() {
    savedRegistry = state.repositories;
    savedIdentity = state.identity;
    savedAccount = state.currentAccount;
    savedAuthStatus = state.authStatus;
    savedActive = state.activePasuyoTask;
    savedTasks = List.of(state.db.pasuyoTasks);
    errands = _Errands();
    realtime = _Realtime();
    state.configureAuth(_HostedAuth());
    state.configureRepositories(_registry(errands, realtime));
    _identity('customer-1');
  });

  tearDown(() async {
    state.configureRepositories(savedRegistry);
    state.configureAuth(MockAuthRepository());
    state.identity = savedIdentity;
    state.currentAccount = savedAccount;
    state.authStatus = savedAuthStatus;
    state.activePasuyoTask = savedActive;
    state.activePasuyoBreakdown = null;
    state.db.pasuyoTasks
      ..clear()
      ..addAll(savedTasks);
    for (final watch in realtime.watches) {
      await watch.events.close();
    }
  });

  Future<void> mount(WidgetTester tester, {bool helper = false}) async {
    await tester.binding.setSurfaceSize(const Size(900, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(PasuyoTaskScreen(taskId: 'task-1', helperMode: helper)),
    );
    await _pump(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  for (final helper in [false, true]) {
    testWidgets(
      '${helper ? 'helper' : 'customer'} observes independent server transitions',
      (tester) async {
        if (helper) _identity('helper-1');
        await mount(tester, helper: helper);
        expect(realtime.watches.single.table, 'service_requests');
        expect(realtime.watches.single.column, 'id');
        expect(realtime.watches.single.value, 'task-1');
        expect(find.byType(SbSearchRadar), findsOneWidget);
        expect(find.text(PasuyoStatus.available.label), findsWidgets);
        expect(
          find.widgetWithText(SbPrimaryButton, 'Accept task'),
          helper ? findsOneWidget : findsNothing,
        );

        for (final status in [
          PasuyoStatus.accepted,
          PasuyoStatus.goingToPickup,
          PasuyoStatus.atPickup,
          PasuyoStatus.pickedUp,
          PasuyoStatus.delivering,
          PasuyoStatus.atCustomer,
          PasuyoStatus.delivered,
        ]) {
          errands.record = _task(status: status, actual: 5025);
          realtime.watches.single.events.add(null);
          await _pump(tester);
          expect(find.text(status.label), findsWidgets);
          final stepper = tester.widget<PasuyoStepper>(
            find.byType(PasuyoStepper),
          );
          expect(stepper.task.status, status);
          expect(
            tester
                .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator),
                )
                .value,
            status.stepIndex / (PasuyoStatus.flow.length - 1),
          );
          expect(
            find.widgetWithText(
              SbPrimaryButton,
              status.advanceActionLabel ?? 'No action',
            ),
            helper && !status.isTerminal ? findsOneWidget : findsNothing,
          );
        }
        expect(
          errands.accepts,
          0,
          reason: 'Updates never accept on behalf of the helper',
        );
        expect(find.text('Fee breakdown'), findsOneWidget);
        expect(find.text('Customer pays in cash'), findsOneWidget);
        expect(find.text('₱295.46'), findsOneWidget);
        expect(find.text('Back to Home'), findsOneWidget);
        expect(find.text('Cancel errand'), findsNothing);
        expect(find.byType(TextField), findsNothing);
      },
    );
  }

  testWidgets('15-second reconciliation works without realtime', (
    tester,
  ) async {
    state.configureRepositories(_registry(errands, null));
    await mount(tester);
    final reads = errands.reads;
    errands.record = _task(status: PasuyoStatus.delivering);
    await tester.pump(const Duration(seconds: 14));
    expect(errands.reads, reads);
    await tester.pump(const Duration(seconds: 1));
    await _pump(tester);
    expect(errands.reads, reads + 1);
    expect(find.text(PasuyoStatus.delivering.label), findsWidgets);
  });

  testWidgets('invalidation bursts serialize and coalesce reads', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<ServiceRequestRecord?>();
    final reads = errands.reads;
    errands.read = () => pending.future;
    realtime.watches.single.events.add(null);
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      realtime.watches.single.events.add(null);
    }
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(errands.reads, reads + 1);
    expect(errands.maxInFlight, 1);
    errands.read = null;
    errands.record = _task(status: PasuyoStatus.accepted);
    pending.complete(_task());
    await _pump(tester);
    expect(errands.reads, reads + 2);
    expect(errands.maxInFlight, 1);
    expect(find.text(PasuyoStatus.accepted.label), findsWidgets);
  });

  testWidgets(
    'write latch rejects double taps and pre-write reads cannot roll back status',
    (tester) async {
      _identity('helper-1');
      await mount(tester, helper: true);
      final stale = Completer<ServiceRequestRecord?>();
      errands.read = () => stale.future;
      realtime.watches.single.events.add(null);
      await tester.pump();
      errands.read = null;
      final write = Completer<void>();
      errands.beforeWrite = () => write.future;
      final button = tester.widget<SbPrimaryButton>(
        find.widgetWithText(SbPrimaryButton, 'Accept task'),
      );
      button.onPressed!();
      button.onPressed!();
      expect(errands.accepts, 1);
      write.complete();
      await _pump(tester);
      stale.complete(_task(title: 'Stale pre-write task'));
      await _pump(tester);
      expect(find.text('Stale pre-write task'), findsNothing);
      expect(find.text(PasuyoStatus.accepted.label), findsWidgets);
      expect(
        find.widgetWithText(
          SbPrimaryButton,
          PasuyoStatus.accepted.advanceActionLabel!,
        ),
        findsOneWidget,
      );
      expect(errands.accepts, 1);
    },
  );

  testWidgets(
    'actual costs validate pesos and preserve provider fare, fee and cash receipt',
    (tester) async {
      _identity('helper-1');
      errands.record = _task(status: PasuyoStatus.atPickup);
      await mount(tester, helper: true);
      for (final raw in ['NaN', 'Infinity', '-1', '1.234', '1e2']) {
        await tester.enterText(find.byType(TextField), raw);
        await _tap(
          tester,
          find.widgetWithText(SbPrimaryButton, 'Save item costs'),
        );
        expect(errands.actualWrites, isEmpty);
        expect(find.text('Enter a valid amount for Milk.'), findsOneWidget);
      }
      await tester.enterText(find.byType(TextField), '50.25');
      await _tap(
        tester,
        find.widgetWithText(SbPrimaryButton, 'Save item costs'),
      );
      expect(errands.actualWrites.single.single, {
        'id': 'item-1',
        'actual_unit_price_centavos': 5025,
        'quantity': 2.0,
      });
      expect(find.text('₱187.65'), findsOneWidget);
      expect(find.text('₱7.31'), findsOneWidget);
      expect(find.text('₱100.50'), findsOneWidget);
      expect(find.text('₱295.46'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '0');
      await _tap(
        tester,
        find.widgetWithText(SbPrimaryButton, 'Save item costs'),
      );
      expect(errands.actualWrites.last.single['actual_unit_price_centavos'], 0);
      expect(find.text('₱194.96'), findsOneWidget);
    },
  );

  testWidgets('failed cancellation shows server refusal and keeps the task', (
    tester,
  ) async {
    errands.record = _task(status: PasuyoStatus.delivering);
    errands.cancelFailure = RepositoryFailure.conflict(
      'The server refused this cancellation.',
    );
    await mount(tester);
    await _tap(tester, find.widgetWithText(SbOutlineButton, 'Cancel errand'));
    await _tap(tester, find.widgetWithText(TextButton, 'Cancel errand'));
    expect(errands.cancellations, 1);
    expect(find.text('The server refused this cancellation.'), findsOneWidget);
    expect(find.text('Errand cancelled.'), findsNothing);
    expect(find.text(PasuyoStatus.delivering.label), findsWidgets);
    expect(find.text('Fee breakdown'), findsOneWidget);
    expect(
      find.widgetWithText(SbOutlineButton, 'Cancel errand'),
      findsOneWidget,
    );
  });

  testWidgets(
    'customer and unrelated helper have no assigned-helper controls',
    (tester) async {
      errands.record = _task(status: PasuyoStatus.atPickup);
      await mount(tester);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.widgetWithText(
          SbPrimaryButton,
          PasuyoStatus.atPickup.advanceActionLabel!,
        ),
        findsNothing,
      );
      _identity('unrelated-helper');
      await tester.pumpWidget(
        _app(const PasuyoTaskScreen(taskId: 'task-1', helperMode: true)),
      );
      await _pump(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Cancel errand'), findsNothing);
      expect(
        find.widgetWithText(
          SbPrimaryButton,
          PasuyoStatus.atPickup.advanceActionLabel!,
        ),
        findsNothing,
      );
      errands.record = _task(customer: 'unrelated-helper');
      realtime.watches.last.events.add(null);
      await _pump(tester);
      expect(
        find.text('Accept task'),
        findsNothing,
        reason: 'Cannot accept your own errand',
      );
    },
  );

  testWidgets('account changes discard old reads and old read failures', (
    tester,
  ) async {
    final old = Completer<ServiceRequestRecord?>();
    errands.read = () => old.future;
    await mount(tester);
    errands.read = null;
    errands.record = _task(
      title: 'Second account task',
      customer: 'customer-2',
    );
    _identity('customer-2');
    await _pump(tester);
    expect(realtime.watches.first.cancellations, 1);
    expect(find.text('Second account task'), findsOneWidget);
    old.completeError(RepositoryFailure.permissionDenied());
    await _pump(tester);
    expect(find.text('Second account task'), findsOneWidget);
    expect(
      find.text('You do not have permission to read this data.'),
      findsNothing,
    );

    final lateRead = Completer<ServiceRequestRecord?>();
    errands.read = () => lateRead.future;
    realtime.watches.last.events.add(null);
    await tester.pump();
    _identity(null);
    await _pump(tester);
    lateRead.complete(_task(title: 'Private old account task'));
    await _pump(tester);
    expect(find.text('Second account task'), findsNothing);
    expect(find.text('Private old account task'), findsNothing);
    expect(find.text('Sign in again to view this errand.'), findsOneWidget);
    expect(realtime.watches.last.cancellations, 1);
  });

  testWidgets('repository replacement isolates old reads', (tester) async {
    final old = Completer<ServiceRequestRecord?>();
    errands.read = () => old.future;
    await mount(tester);
    final replacement = _Errands()
      ..record = _task(title: 'Replacement repository task');
    state.configureRepositories(_registry(replacement, realtime));
    await tester.pumpWidget(_app(const PasuyoTaskScreen(taskId: 'task-1')));
    await _pump(tester);
    old.complete(_task(title: 'Previous repository task'));
    await _pump(tester);
    expect(find.text('Replacement repository task'), findsOneWidget);
    expect(find.text('Previous repository task'), findsNothing);
    expect(realtime.watches.first.cancellations, 1);
  });

  testWidgets(
    'dispose cancels subscriptions and timers and ignores late reads',
    (tester) async {
      final pending = Completer<ServiceRequestRecord?>();
      errands.read = () => pending.future;
      await mount(tester);
      final reads = errands.reads;
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete(_task());
      await tester.pump(const Duration(seconds: 30));
      expect(realtime.watches.single.cancellations, 1);
      expect(errands.reads, reads);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read errors retain confirmed receipt and realtime recovery reloads',
    (tester) async {
      errands.record = _task(status: PasuyoStatus.delivered, actual: 5025);
      await mount(tester);
      errands.read = () async => throw RepositoryFailure.offline();
      realtime.watches.single.events.addError(RepositoryFailure.offline());
      await _pump(tester);
      expect(find.text('₱295.46'), findsOneWidget);
      expect(find.textContaining('Could not refresh:'), findsOneWidget);
      errands.read = null;
      realtime.watches.single.events.add(null);
      await _pump(tester);
      expect(find.textContaining('Could not refresh:'), findsNothing);
      expect(find.text('₱295.46'), findsOneWidget);
    },
  );

  testWidgets('different task response is not rendered as this errand', (
    tester,
  ) async {
    errands.record = _task(id: 'wrong-task', title: 'Wrong task');
    await mount(tester);
    expect(find.text('Wrong task'), findsNothing);
    expect(
      find.text('The errand service returned a different task.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'hosted identity on seed uses demo controls and honest issue reporting',
    (tester) async {
      state.configureRepositories(_registry(errands, realtime, hosted: false));
      state.activePasuyoTask = null;
      final task = PasuyoTask(
        id: 'task-1',
        customerId: state.db.passenger.id,
        category: PasuyoCategory.groceries,
        title: 'Seeded grocery task',
        items: const ['Milk'],
        pickupBarangay: 'Tandag',
        pickupPurok: '1',
        pickup: 'Grocery pickup',
        dropoffBarangay: 'Tandag',
        dropoffPurok: '2',
        dropoff: 'Customer address',
        budget: 15000,
      );
      state.db.pasuyoTasks.insert(0, task);
      await mount(tester, helper: true);
      await _tap(tester, find.widgetWithText(SbPrimaryButton, 'Accept task'));
      expect(task.status, PasuyoStatus.accepted);
      expect(errands.reads, 0);
      expect(errands.accepts, 0);
      expect(realtime.watches, isEmpty);
      await _tap(tester, find.widgetWithText(SbOutlineButton, 'Report issue'));
      expect(
        find.text(
          'Demo only: issue reporting is not connected. No report or support ticket was sent.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Report sent.'), findsNothing);
    },
  );

  testWidgets(
    'seed feed preserves pending tasks and post preview keeps legacy pricing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      state.configureRepositories(_registry(errands, realtime, hosted: false));
      state.db.pasuyoTasks
        ..clear()
        ..add(
          PasuyoTask(
            id: 'task-1',
            customerId: state.db.passenger.id,
            category: PasuyoCategory.pharmacy,
            title: 'Seed pharmacy template',
            items: const ['Medicine'],
            pickupBarangay: 'Tandag',
            pickupPurok: '1',
            pickup: 'Pharmacy',
            dropoffBarangay: 'Tandag',
            dropoffPurok: '2',
            dropoff: 'Home',
            budget: 15000,
          ),
        );
      await tester.pumpWidget(_app(const PasuyoScreen()));
      await _pump(tester);
      expect(find.text('Seed pharmacy template'), findsOneWidget);
      expect(find.text('History'), findsNothing);
      expect(errands.reads, 0);
      await tester.pumpWidget(_app(const PasuyoPostScreen()));
      await _pump(tester);
      expect(find.text('SurGo service fee (15%)'), findsOneWidget);
      expect(find.text('₱127.50'), findsOneWidget);
      expect(find.text('₱22.50'), findsOneWidget);
      expect(find.text('Platform fee (fixed)'), findsNothing);
      for (final category in PasuyoCategory.values) {
        expect(find.text(category.label), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final helper in [false, true]) {
    testWidgets('demo delivery rating belongs to customer (helper=$helper)', (
      tester,
    ) async {
      state.configureRepositories(_registry(errands, realtime, hosted: false));
      final task = PasuyoTask(
        id: 'task-1',
        customerId: state.db.passenger.id,
        helperId: state.db.earner.id,
        category: PasuyoCategory.groceries,
        title: 'Delivered groceries',
        items: const ['Rice'],
        pickupBarangay: 'Tandag',
        pickupPurok: '1',
        pickup: 'Market',
        dropoffBarangay: 'Tandag',
        dropoffPurok: '2',
        dropoff: 'Home',
        budget: 15000,
        status: PasuyoStatus.delivered,
      );
      state.db.pasuyoTasks
        ..clear()
        ..add(task);
      await tester.binding.setSurfaceSize(const Size(900, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(PasuyoTaskScreen(taskId: task.id, helperMode: helper)),
      );
      await _pump(tester);
      expect(
        find.text('Submit 5-star rating'),
        helper ? findsNothing : findsOneWidget,
      );
      expect(find.text('Report issue'), helper ? findsOneWidget : findsNothing);
      expect(find.text('₱127.50'), findsOneWidget);
      expect(task.rated, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'Back to Home leaves delivered receipt visible until explicit navigation',
    (tester) async {
      errands.record = _task(status: PasuyoStatus.delivered, actual: 5025);
      await tester.binding.setSurfaceSize(const Size(900, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const Scaffold(body: Text('Home dashboard')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const PasuyoScreen()),
        ),
      );
      await _pump(tester);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const PasuyoTaskScreen(taskId: 'task-1'),
          ),
        ),
      );
      await _pump(tester);
      expect(find.text('₱295.46'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await _pump(tester);
      expect(find.text('₱295.46'), findsOneWidget);
      await _tap(tester, find.widgetWithText(SbOutlineButton, 'Back to Home'));
      await tester.pumpAndSettle();
      expect(find.text('Home dashboard'), findsOneWidget);
      expect(find.byType(PasuyoScreen), findsNothing);
      expect(realtime.watches.single.cancellations, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
