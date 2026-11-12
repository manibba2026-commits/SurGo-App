import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/main.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/booking_screen.dart';
import 'package:surgo/screens/passenger_shell.dart';
import 'package:surgo/screens/rider_shell.dart';
import 'package:surgo/screens/splash_screen.dart';
import 'package:surgo/screens/vehicle_owner_shell.dart';
import 'package:surgo/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    await state.init();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
  });

  tearDown(() async => state.logout());

  for (final route in ['/home', '/earner', '/owner', '/booking', '/matching']) {
    testWidgets('cold route $route starts behind bootstrap', (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = route;
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );
      await tester.pumpWidget(const SurGoApp());
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.byType(PassengerShell), findsNothing);
      expect(find.byType(EarnerShell), findsNothing);
      expect(find.byType(VehicleOwnerShell), findsNothing);
      expect(find.byType(BookingScreen), findsNothing);
      expect(tester.takeException(), isNull);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1700));
      expect(tester.takeException(), isNull);
    });
  }
}
