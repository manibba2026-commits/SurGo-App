import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:surgo/screens/forgot_password_screen.dart';
import 'package:surgo/screens/login_screen.dart';
import 'package:surgo/screens/register_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/theme/app_theme.dart';

/// Drives the three auth screens through a light harness. Destination routes
/// are stand-ins, so a test asserts navigation happened without building the
/// real (network-tile) shells.
Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: screen,
    routes: {
      '/home': (_) => const Scaffold(body: Text('HOME')),
      '/earner': (_) => const Scaffold(body: Text('HOME')),
      '/owner': (_) => const Scaffold(body: Text('HOME')),
      '/register': (_) => const Scaffold(body: Text('REGISTER')),
      '/login': (_) => const Scaffold(body: Text('LOGIN')),
      '/forgot-password': (_) => const Scaffold(body: Text('FORGOT')),
    },
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => AppState.instance.init());
  setUp(() => AppState.instance.logout());

  testWidgets('signs in a seeded account and opens the dashboard',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).at(0), '+63 917 512 4809');
    await tester.enterText(find.byType(TextField).at(1), 'surgo123');
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
    expect(AppState.instance.isSignedIn, isTrue);
  });

  testWidgets('shows the refusal when the password is wrong', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).at(0), '+63 917 512 4809');
    await tester.enterText(find.byType(TextField).at(1), 'wrong-password');
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();

    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgets('the forgot-password link below the field opens the reset screen',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('FORGOT'), findsOneWidget);
  });

  testWidgets('the sign-up link opens registration', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();

    expect(find.text('REGISTER'), findsOneWidget);
  });

  testWidgets('registration validates before hitting the seed', (tester) async {
    await pumpScreen(tester, const RegisterScreen());
    await tester.ensureVisible(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pump();

    expect(find.text('Please enter your full name.'), findsOneWidget);
  });

  testWidgets('a completed registration opens the dashboard', (tester) async {
    await pumpScreen(tester, const RegisterScreen());
    await tester.enterText(find.byType(TextField).at(0), 'Widget Tester');
    await tester.enterText(find.byType(TextField).at(1), '+63 955 000 0001');
    await tester.enterText(find.byType(TextField).at(2), 'widget.tester@example.com');
    await tester.enterText(find.byType(TextField).at(3), 'secret1');
    await tester.ensureVisible(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
    expect(AppState.instance.db.passenger.name, 'Widget Tester');
  });

  testWidgets('reset refuses an unknown identifier', (tester) async {
    await pumpScreen(tester, const ForgotPasswordScreen());
    await tester.enterText(find.byType(TextField).at(0), 'nobody@nowhere.com');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();

    expect(
      find.text('We could not find an account with that phone or email.'),
      findsOneWidget,
    );
  });

  testWidgets('reset confirms for a seeded identifier', (tester) async {
    await pumpScreen(tester, const ForgotPasswordScreen());
    await tester.enterText(find.byType(TextField).at(0), 'grace.villaflor@email.com');
    await tester.tap(find.text('Send reset link'));
    await tester.pumpAndSettle();

    expect(find.text('Check your inbox'), findsOneWidget);
  });
}
