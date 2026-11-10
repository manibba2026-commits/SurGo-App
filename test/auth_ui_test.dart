import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/screens/forgot_password_screen.dart';
import 'package:surgo/screens/login_screen.dart';
import 'package:surgo/screens/otp_screen.dart';
import 'package:surgo/screens/register_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/theme/app_theme.dart';

/// A hosted provider with no network. It reports `isMock = false`, so the login
/// screen offers the demo PIN form and [AppState] takes the hosted-session path.
class _HostedPinAuth implements AuthRepository {
  static const String phone = '+639170000001';
  static const String pin = '246810';

  AuthUser? _user;

  @override
  bool get isMock => false;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<AuthUser?> restoreSession() async => _user;

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async {
    if (normalizePhoneNumber(phone) != _HostedPinAuth.phone ||
        pin != _HostedPinAuth.pin) {
      throw const AuthFailure(
        AuthFailureCode.invalidPin,
        'That phone number and PIN do not match a demo account.',
      );
    }
    return _user = AuthUser(
      id: 'demo-uuid',
      phone: _HostedPinAuth.phone,
      fullName: 'Demo One',
      providers: const {'phone'},
      metadata: const {'surgo_demo': true},
    );
  }

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {
    _user = null;
  }

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    const capabilities = {CapabilityType.passenger};
    return SurgoIdentity(
      userId: user.id,
      phone: user.phone,
      fullName: user.fullName,
      capabilities: capabilities,
      eligibleCapabilities: eligibleCapabilitiesFor(capabilities),
      roles: const {'passenger'},
      providers: user.providers,
      profileExists: true,
      isDemoAccount: true,
    );
  }

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {}

  @override
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) async {}

  @override
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async =>
      _user!;

  @override
  Future<bool> linkGoogleIdentity() async => false;

  @override
  Future<void> requestPhoneLink(String phone) async {}

  @override
  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  }) async {}
}

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
  tearDown(() async {
    await AppState.instance.logout();
    AppState.instance.configureAuth(MockAuthRepository());
  });

  testWidgets('the login form requests a code and opens OTP', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).first, '0917 512 4809');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(find.text('OTP'), findsOneWidget);
    expect(AppState.instance.isSignedIn, isFalse);
  });

  testWidgets('demo PIN sign-in validates, then opens the dashboard',
      (tester) async {
    AppState.instance.configureAuth(_HostedPinAuth());
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Use demo phone + PIN'));
    await tester.tap(find.text('Use demo phone + PIN'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid phone number, for example 0917 000 0001.'),
        findsOneWidget);
    expect(
        find.text('Enter the 6-digit PIN for this account.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '0917 000 0001');
    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(AppState.instance.isSignedIn, isTrue);
    // A demo identity signs in with its own PIN, so no device lock is stacked
    // on top before the dashboard opens.
    expect(AppState.instance.isDemoAccount, isTrue);
    expect(AppState.instance.requiresPin, isFalse);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('demo PIN sign-in reports a mismatched PIN', (tester) async {
    AppState.instance.configureAuth(_HostedPinAuth());
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Use demo phone + PIN'));
    await tester.tap(find.text('Use demo phone + PIN'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '09170000001');
    await tester.enterText(find.byType(TextField).at(1), '000000');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(
      find.text('That phone number and PIN do not match a demo account.'),
      findsOneWidget,
    );
    expect(AppState.instance.isSignedIn, isFalse);
  });

  testWidgets('demo PIN form returns to the phone form', (tester) async {
    AppState.instance.configureAuth(_HostedPinAuth());
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Use demo phone + PIN'));
    await tester.tap(find.text('Use demo phone + PIN'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Use a phone number instead'));
    await tester.tap(find.text('Use a phone number instead'));
    await tester.pumpAndSettle();

    expect(find.text('Send code'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
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
