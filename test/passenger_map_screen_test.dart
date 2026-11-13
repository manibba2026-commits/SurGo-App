import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/screens/passenger_map_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/widgets/surgo_map.dart';

class _HostedAuth extends MockAuthRepository {
  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();
}

class _Rides extends MockRideRepository {
  List<RiderCandidateRecord> candidates = const [];
  bool deferred = false;
  Object? failure;
  int calls = 0;
  final pending = <Completer<List<RiderCandidateRecord>>>[];

  @override
  Future<List<RiderCandidateRecord>> findAvailableRiders({
    String? serviceAreaId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? excludeProfileId,
    int limit = 20,
  }) {
    calls++;
    if (deferred) {
      final read = Completer<List<RiderCandidateRecord>>();
      pending.add(read);
      return read.future;
    }
    if (failure != null) return Future.error(failure!);
    return Future.value(candidates);
  }
}

const _real = RiderCandidateRecord(
  profileId: 'real-rider',
  fullName: 'Device Rider',
  latitude: 9.0785,
  longitude: 126.1985,
);
const _demo = RiderCandidateRecord(
  profileId: 'demo-rider',
  fullName: 'Demo Rider',
  latitude: 9.0795,
  longitude: 126.1995,
  isSimulated: true,
);
const _unlocated = RiderCandidateRecord(
  profileId: 'unlocated-rider',
  fullName: 'Unlocated Rider',
);

RepositoryRegistry _registry(_Rides rides, {bool hosted = true}) {
  final mock = RepositoryRegistry.mock();
  return RepositoryRegistry(
    profiles: mock.profiles,
    catalog: mock.catalog,
    vehicles: mock.vehicles,
    rides: rides,
    rentals: mock.rentals,
    pasuyo: mock.pasuyo,
    notifications: mock.notifications,
    wallet: mock.wallet,
    verifications: mock.verifications,
    attachments: mock.attachments,
    isSupabaseBacked: hosted,
  );
}

void _account({String profile = 'passenger-1', String account = 'account-1'}) {
  final state = AppState.instance;
  state.identity = SurgoIdentity(
    userId: profile,
    fullName: 'Test Passenger',
    capabilities: const {CapabilityType.passenger},
    eligibleCapabilities: const {},
    roles: const {'passenger'},
    providers: const {'phone'},
  );
  state.currentAccount = Account(
    id: account,
    authUserId: profile,
    passengerId: profile,
    name: 'Test Passenger',
    phone: '',
    email: '',
  );
  state.authStatus = AuthStatus.signedIn;
}

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: const PassengerMapScreen(),
      routes: {
        '/rental': (_) =>
            const Scaffold(body: Text('Rental catalogue fixture')),
        '/booking': (_) => const Scaffold(body: Text('Booking fixture')),
      },
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

List<SurgoMapMarker> _markers(WidgetTester tester) =>
    tester.widget<SurgoMap>(find.byType(SurgoMap)).markers;

List<SurgoMapMarker> _riderMarkers(WidgetTester tester) => _markers(
  tester,
).where((marker) => !marker.id.startsWith('rental-')).toList();

List<SurgoMapMarker> _rentalMarkers(WidgetTester tester) => _markers(
  tester,
).where((marker) => marker.id.startsWith('rental-')).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;
  final db = DbService.instance;
  const locationChannel = MethodChannel('flutter.baseflow.com/geolocator');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Rides rides;

  setUpAll(() async => db.load());

  setUp(() {
    messenger.setMockMethodCallHandler(locationChannel, (call) async {
      expect(call.method, 'isLocationServiceEnabled');
      return false;
    });
    rides = _Rides();
    state.configureAuth(_HostedAuth());
    state.configureRepositories(_registry(rides));
    state.mode = UserMode.passenger;
    state.riderOnline = false;
    _account();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(locationChannel, null);
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    state.currentAccount = null;
    state.identity = null;
    state.authStatus = AuthStatus.signedOut;
    state.mode = UserMode.passenger;
  });

  for (final mode in [
    (name: 'mock identity and seeded data', identity: false, data: false),
    (name: 'hosted identity and seeded data', identity: true, data: false),
    (name: 'mock identity and hosted data', identity: false, data: true),
  ]) {
    testWidgets('${mode.name} keeps the local map without discovery reads', (
      tester,
    ) async {
      if (!mode.identity) state.configureAuth(MockAuthRepository());
      state.configureRepositories(_registry(rides, hosted: mode.data));
      expect(state.usesHostedRideDispatch, isFalse);
      await _open(tester);
      expect(rides.calls, 0);
      expect(_markers(tester).map((marker) => marker.id), [
        ...db.mapRiders.map((rider) => rider.id),
        ...db.mapRentalVehicles.map((vehicle) => vehicle.id),
      ]);
      expect(find.byIcon(Icons.refresh), findsNothing);
      await tester.tap(find.text('Rentals'));
      await tester.pump();
      expect(
        _markers(tester).map((marker) => marker.id),
        db.mapRentalVehicles.map((vehicle) => vehicle.id),
      );
      await tester.pump(const Duration(seconds: 60));
      expect(rides.calls, 0);
    });
  }

  for (final hosted in [false, true]) {
    testWidgets('map clears safe-area controls at 320px (hosted=$hosted)', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      state.configureRepositories(_registry(rides, hosted: hosted));
      rides.candidates = const [_real];
      await _open(tester);
      final map = tester.widget<SurgoMap>(find.byType(SurgoMap));
      expect(map.cameraPadding.top, 84);
      expect(map.cameraPadding.bottom, hosted ? 142 : 16);
      expect(
        tester.getTopLeft(find.text('Offline map preview')).dy,
        greaterThan(tester.getBottomLeft(find.text('All')).dy),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hosted map excludes seeded pins and links to rental catalogue', (
    tester,
  ) async {
    rides.candidates = const [_real, _demo];
    await _open(tester);
    expect(state.usesHostedRideDispatch, isTrue);
    expect(rides.calls, 1);
    expect(_riderMarkers(tester).map((marker) => marker.id), [
      'real-rider',
      'demo-rider',
    ]);
    expect(_rentalMarkers(tester), isEmpty);
    await tester.tap(find.text('Rentals'));
    await tester.pumpAndSettle();
    expect(_riderMarkers(tester), isEmpty);
    expect(_rentalMarkers(tester), isNotEmpty);
    expect(
      find.textContaining('rental vehicles · pin locations'),
      findsOneWidget,
    );
    expect(find.textContaining('riders online'), findsNothing);
    await tester.tap(find.text('View Rentals'));
    await tester.pumpAndSettle();
    expect(find.text('Rental catalogue fixture'), findsOneWidget);
  });

  for (final fixture in [
    (candidates: <RiderCandidateRecord>[], label: 'No riders online'),
    (candidates: [_real], label: '1 rider online · 1 device-reported location'),
    (candidates: [_demo], label: '1 rider online · 1 simulated demo location'),
    (
      candidates: [_real, _demo],
      label:
          '2 riders online · 1 device-reported location · 1 simulated demo location',
    ),
    (
      candidates: [_real, _demo, _unlocated],
      label:
          '3 riders online · 1 device-reported location · 1 simulated demo location · 1 without location',
    ),
    (candidates: [_unlocated], label: '1 rider online · 1 without location'),
  ]) {
    testWidgets('honest discovery status: ${fixture.label}', (tester) async {
      rides.candidates = fixture.candidates;
      await _open(tester);
      expect(find.text(fixture.label), findsOneWidget);
      final markers = _markers(tester);
      expect(
        markers.length,
        fixture.candidates.where((rider) => rider.hasPosition).length,
      );
      for (final marker in markers) {
        final rider = fixture.candidates.firstWhere(
          (candidate) => candidate.profileId == marker.id,
        );
        expect(
          marker.details.where((entry) => entry.key == 'Position').single.value,
          rider.isSimulated
              ? 'Simulated demo location'
              : 'Reported by rider device',
        );
        expect(marker.actionLabel, 'Book a Ride');
      }
    });
  }

  testWidgets('hosted rider action still opens booking', (tester) async {
    rides.candidates = const [_real];
    await _open(tester);
    _markers(tester).single.onAction!();
    await tester.pumpAndSettle();
    expect(find.text('Booking fixture'), findsOneWidget);
  });

  testWidgets('manual refreshes coalesce with initial and silent reads', (
    tester,
  ) async {
    rides.deferred = true;
    await _open(tester);
    expect(find.text('Refreshing riders…'), findsOneWidget);
    expect(rides.calls, 1);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(rides.calls, 1);
    rides.pending[0].complete(const [_real]);
    await tester.pump();
    expect(
      find.text('1 rider online · 1 device-reported location'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 20));
    expect(rides.calls, 2);
    expect(
      find.text('Refreshing riders…'),
      findsNothing,
      reason: 'silent polling retains the settled display',
    );
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump(const Duration(seconds: 19));
    expect(rides.calls, 2, reason: 'silent reads share the same read lock');
    rides.pending[1].complete(const [_demo]);
    await tester.pump();
    expect(
      find.text('1 rider online · 1 simulated demo location'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(rides.calls, 3);
    rides.pending[2].complete(const []);
    await tester.pump();
    expect(find.text('No riders online'), findsOneWidget);
  });

  testWidgets('discovery timeout releases the lock and retires late results', (
    tester,
  ) async {
    rides.deferred = true;
    await _open(tester);
    await tester.pump(const Duration(seconds: 20));
    expect(
      find.text('Rider discovery timed out. Try refreshing.'),
      findsOneWidget,
    );
    expect(find.text('Refreshing riders…'), findsNothing);
    rides.deferred = false;
    rides.candidates = const [_demo];
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(rides.calls, 2);
    rides.pending.single.complete(const [_real]);
    await tester.pump();
    expect(_markers(tester).single.id, 'demo-rider');
    expect(
      find.text('1 rider online · 1 simulated demo location'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final change in ['profile', 'account', 'registry']) {
    testWidgets('$change changes clear cached pins and retire silent results', (
      tester,
    ) async {
      rides.candidates = const [_real];
      await _open(tester);
      rides.deferred = true;
      await tester.pump(const Duration(seconds: 20));
      expect(rides.calls, 2);
      final replacement = _Rides()..candidates = const [_demo];
      if (change == 'profile') {
        _account(profile: 'passenger-2');
      } else if (change == 'account') {
        _account(account: 'account-2');
      } else {
        state.configureRepositories(_registry(replacement));
      }
      state.notifyListeners();
      await tester.pump();
      expect(_markers(tester), isEmpty);
      expect(find.text('Refreshing riders…'), findsOneWidget);
      expect(rides.calls, 2);
      expect(replacement.calls, 0, reason: 'the old read must drain first');
      rides.deferred = false;
      rides.candidates = const [_demo];
      rides.pending.single.complete(const [_real]);
      await tester.pumpAndSettle();
      expect(_markers(tester).single.id, 'demo-rider');
      expect(
        find.text('1 rider online · 1 simulated demo location'),
        findsOneWidget,
      );
      expect(
        change == 'registry' ? replacement.calls : rides.calls,
        change == 'registry' ? 1 : 3,
      );
    });
  }

  testWidgets('registry swaps without notifications are checked on rebuild', (
    tester,
  ) async {
    rides.deferred = true;
    await _open(tester);
    final replacement = _Rides()..candidates = const [_demo];
    state.configureRepositories(_registry(replacement));
    await tester.pumpWidget(
      MaterialApp(home: const PassengerMapScreen(), theme: ThemeData.dark()),
    );
    expect(_markers(tester), isEmpty);
    rides.pending.single.complete(const [_real]);
    await tester.pump();
    expect(replacement.calls, 1);
    expect(_markers(tester).single.id, 'demo-rider');
  });

  testWidgets('account round trip retires old failures before a fresh read', (
    tester,
  ) async {
    rides.deferred = true;
    await _open(tester);
    _account(profile: 'passenger-2');
    state.notifyListeners();
    _account();
    state.notifyListeners();
    rides.deferred = false;
    rides.candidates = const [_demo];
    rides.pending.single.completeError(RepositoryFailure.permissionDenied());
    await tester.pump();
    expect(rides.calls, 2);
    expect(_markers(tester).single.id, 'demo-rider');
    expect(
      find.text('You do not have permission to read this data.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final change in ['role', 'data mode', 'auth mode', 'sign out']) {
    testWidgets('$change stops polling and retires pending discovery', (
      tester,
    ) async {
      rides.deferred = true;
      await _open(tester);
      if (change == 'role') {
        state.mode = UserMode.earner;
      } else if (change == 'data mode') {
        state.configureRepositories(_registry(rides, hosted: false));
      } else if (change == 'auth mode') {
        state.configureAuth(MockAuthRepository());
      } else {
        state.currentAccount = null;
        state.identity = null;
      }
      state.notifyListeners();
      await tester.pump();
      rides.pending.single.complete(const [_real]);
      await tester.pump(const Duration(seconds: 60));
      expect(rides.calls, 1);
      expect(
        _markers(tester).map((marker) => marker.id),
        isNot(contains('real-rider')),
      );
      if (change == 'role' || change == 'sign out') {
        expect(_markers(tester), isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final failure in [
    RepositoryFailure.permissionDenied(),
    StateError('fixture failure'),
  ]) {
    testWidgets(
      'discovery failure is visible without seeded fallback: $failure',
      (tester) async {
        rides.failure = failure;
        await _open(tester);
        final message = failure is RepositoryFailure
            ? failure.message
            : RepositoryFailure.unavailable().message;
        expect(find.text(message), findsOneWidget);
        expect(_markers(tester), isEmpty);
        rides.failure = null;
        rides.candidates = const [_real];
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pump();
        expect(_markers(tester).single.id, 'real-rider');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'disposal cancels polling and ignores pending reads and sessions',
    (tester) async {
      rides.deferred = true;
      await _open(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      _account(profile: 'passenger-2');
      state.notifyListeners();
      rides.pending.single.completeError(RepositoryFailure.permissionDenied());
      await tester.pump(const Duration(seconds: 60));
      expect(rides.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
