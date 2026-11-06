import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:surgo/screens/forgot_password_screen.dart';
import 'package:surgo/screens/login_screen.dart';
import 'package:surgo/screens/otp_screen.dart';
import 'package:surgo/screens/register_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/theme/app_theme.dart';

/// Drives the auth screens through a light harness. Destination routes are
/// stand-ins, so a test asserts navigation happened without building the real
/// shells. The in-memory provider accepts `123456` as the code.
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
      '/otp': (_) => const Scaffold(body: Text('OTP')),
    },
  ));
  await tester.pumpAndSettle();
}

Future<void> pumpOtp(
  WidgetTester tester, {
  required String phone,
  String mode = 'login',
  String? name,
}) async {
  await AppState.instance.sendPhoneOtp(
    phone: phone,
    createUser: mode == 'register',
  );
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    initialRoute: '/otp',
    // Build only the OTP page: the default initial-route stack would also
    // mount '/' and leave two OTP screens sharing one pending request.
    onGenerateInitialRoutes: (_) => [
      MaterialPageRoute(
        settings: RouteSettings(
          name: '/otp',
          arguments: {
            'phone': phone,
            'mode': mode,
            if (name != null) 'name': name,
          },
        ),
        builder: (_) => const OtpScreen(),
      ),
    ],
    routes: {
      '/home': (_) => const Scaffold(body: Text('HOME')),
      '/earner': (_) => const Scaffold(body: Text('HOME')),
      '/owner': (_) => const Scaffold(body: Text('HOME')),
    },
  ));
  await tester.pumpAndSettle();
}

Future<void> enterCode(WidgetTester tester, String code) async {
  final fields = find.byType(TextField);
  for (var i = 0; i < code.length; i++) {
    await tester.enterText(fields.at(i), code[i]);
  }
  // The screen verifies 150 ms after the last digit so it can paint the code.
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => AppState.instance.init());
  setUp(() => AppState.instance.logout());

  testWidgets('the login form requests a code and opens OTP', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).first, '0917 512 4809');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(find.text('OTP'), findsOneWidget);
    expect(AppState.instance.isSignedIn, isFalse);
  });

  testWidgets('an unknown number is refused at the login screen',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).first, '0999 000 0000');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'We could not find a SurGo account with that number. Sign up first.'),
      findsOneWidget,
    );
    expect(find.text('OTP'), findsNothing);
  });

  testWidgets('the recovery link opens the passwordless recovery screen',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.tap(find.text('Trouble signing in?'));
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

  testWidgets('Google sign-in opens the dashboard', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    expect(AppState.instance.isSignedIn, isTrue);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('registration validates before requesting a code',
      (tester) async {
    await pumpScreen(tester, const RegisterScreen());
    await tester.ensureVisible(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pump();

    expect(find.text('Please enter your full name.'), findsOneWidget);
  });

  testWidgets('registration sends the name and phone to OTP', (tester) async {
    await pumpScreen(tester, const RegisterScreen());
    await tester.enterText(find.byType(TextField).at(0), 'Widget Tester');
    await tester.enterText(find.byType(TextField).at(1), '0955 000 0001');
    await tester.ensureVisible(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();

    expect(find.text('OTP'), findsOneWidget);
  });

  testWidgets('recovery refuses an unknown number', (tester) async {
    await pumpScreen(tester, const ForgotPasswordScreen());
    await tester.enterText(find.byType(TextField).at(0), '0999 000 0000');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'We could not find a SurGo account with that number. Sign up first.'),
      findsOneWidget,
    );
  });

  testWidgets('recovery sends a code for a seeded number', (tester) async {
    await pumpScreen(tester, const ForgotPasswordScreen());
    await tester.enterText(find.byType(TextField).at(0), '0917 220 4411');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(find.text('OTP'), findsOneWidget);
  });

  testWidgets('a correct code signs in and opens the dashboard',
      (tester) async {
    await pumpOtp(tester, phone: '+639175124809');
    await enterCode(tester, '123456');

    expect(find.text('HOME'), findsOneWidget);
    expect(AppState.instance.currentAccount?.id, 'ACC001');
  });

  testWidgets('a wrong code stays on OTP with an explanation', (tester) async {
    await pumpOtp(tester, phone: '+639175124809');
    await enterCode(tester, '000000');

    expect(find.text('HOME'), findsNothing);
    expect(
      find.text('That code is incorrect or has expired. Request a new one.'),
      findsOneWidget,
    );
    expect(AppState.instance.isSignedIn, isFalse);
  });
}
