import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/booking_screen.dart';
import 'package:surgo/screens/home_screen.dart';
import 'package:surgo/screens/live_trip_screen.dart';
import 'package:surgo/screens/matching_screen.dart';
import 'package:surgo/screens/rate_trip_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';
import 'package:surgo/theme/app_theme.dart';
import 'package:surgo/widgets/common.dart';
import 'package:surgo/widgets/surgo_map.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;
  final db = DbService.instance;

  setUpAll(() async {
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    await state.init();
  });

  setUp(() {
    state.myRideRequest = null;
    state.rideProposal = null;
    state.activeRide = null;
    state.activeRideBreakdown = null;
    state.lastCompletedRide = null;
    state.lastCompletedRideDriver = null;
    state.lastRideBreakdown = null;
    // Labels alone no longer resolve to a point: the picker supplies the real
    // coordinate, and the booking screen requires both ends before submitting.
    state.setPickup(
      'SM Terminal',
      coordinates: const MapPoint(9.0790, 126.1980),
    );
    state.setDestination(
      'Public Market',
      coordinates: const MapPoint(9.0805, 126.1995),
    );
  });

  test('picked coordinates survive request creation and clear on a new label',
      () {
    state.setPickup('External pickup',
        coordinates: const MapPoint(9.08, 126.2));
    state.setDestination('External destination',
        coordinates: const MapPoint(9.09, 126.21));
    final request = state.createRideRequest();
    expect(request.pickupLatitude, 9.08);
    expect(request.pickupLongitude, 126.2);
    expect(request.dropoffLatitude, 9.09);
    expect(request.dropoffLongitude, 126.21);
    expect(request.distanceKm, greaterThan(0));
    state.setPickup('Unknown pickup');
    expect(state.bookingPickup, isNull);
  });

  testWidgets('ride preview completes at phone width with an additive receipt',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final wallet = db.earnerWalletBalance;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const BookingScreen(),
      routes: {
        '/matching': (_) => const MatchingScreen(),
        '/livetrip': (_) => const LiveTripScreen(),
        '/rate': (_) => const RateTripScreen(),
        '/home': (_) => const Scaffold(body: Text('home complete')),
      },
    ));
    await tester.pump(const Duration(seconds: 2));
    await _tap(tester, 'Find a Ride');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    expect(state.rideProposal, isNotNull);
    await tester.tap(find.text('Preview demo trip'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final request = state.activeRide!;
    expect(request.status, RideStatus.accepted);
    expect(request.pickupLatitude, isNotNull);
    expect(request.dropoffLatitude, isNotNull);
    expect(request.distanceKm, greaterThan(0));
    await _tap(tester, 'Start heading to pickup');
    expect(request.status, RideStatus.headingToPickup);
    await _tap(tester, "I've arrived at pickup");
    expect(request.status, RideStatus.arrived);
    await _tap(tester, 'Start the trip');
    expect(request.status, RideStatus.inProgress);
    expect(db.earnerWalletBalance, wallet);
    await _tap(tester, 'Complete trip');
    expect(request.status, RideStatus.completed);
    expect(db.earnerWalletBalance, wallet + request.fare);
    expect(find.text('Trip receipt'), findsOneWidget);
    expect(find.text('Rider receives · 100% fare'), findsOneWidget);
    expect(
        state.lastRideBreakdown!.customerPays,
        state.lastRideBreakdown!.providerGets +
            state.lastRideBreakdown!.surgoKeeps);
    await _tap(tester, 'Submit Rating');
    expect(find.text('home complete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline address search supports empty results and keyboard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      return tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const BookingScreen()));
    await tester.pump(const Duration(milliseconds: 500));
    final destination = find.byWidgetPredicate(
        (widget) => widget is SbField && widget.label == 'Destination');
    await tester.ensureVisible(destination);
    await tester.tap(destination);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzzzzz');
    await tester.pump();
    expect(
      find.text(
        'Address search needs a hosted account. Drop a pin or use your '
        'current location instead.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'Tandag Diagnostic Center');
    await tester.pump();
    expect(
      find.text(
        'Address search needs a hosted account. Drop a pin or use your '
        'current location instead.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lone destination stays above the sheet on a narrow phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    state.setPickup('Unknown pickup');
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const BookingScreen()));
    await tester.pump(const Duration(seconds: 2));

    expect(state.bookingPickup, isNull);
    final map = tester.widget<SurgoMap>(find.byType(SurgoMap));
    expect(map.fallbackCenter!.latitude, state.bookingDestination!.latitude);
    expect(map.fallbackCenter!.longitude, state.bookingDestination!.longitude);
    final pin = tester.getRect(
        find.byKey(const ValueKey('surgo-marker-destination')));
    expect(pin.top, greaterThanOrEqualTo(80));
    expect(pin.bottom, lessThanOrEqualTo(256));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home service tiles fit a narrow phone without overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (final label in [
      'Find rider',
      'Rent vehicle',
      'Pasuyo',
      'Book for someone'
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 300));
  final button = find.widgetWithText(SbPrimaryButton, label);
  await tester.ensureVisible(button);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}
