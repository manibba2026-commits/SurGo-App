import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/screens/email_login_screen.dart';
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
      isDemoAccount: true,
    );
  }

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<bool> signInWithFacebook() async => false;

  @override
  Future<AuthUser> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      throw UnimplementedError();

  @override
  Future<AuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async =>
      throw UnimplementedError();

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
      isDemoAccount: user.isDemoAccount,
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

class _HostedRegressionAuth extends _HostedPinAuth {
  final emailPasswords = <String>[];
  final signupPasswords = <String>[];
  final otpRequests = <({String phone, String? name, bool createUser})>[];
  final linkRequests = <String>[];
  Object? emailError;
  Future<AuthUser>? verificationResult;
  int verificationCalls = 0;

  static const user = AuthUser(
    id: 'regression-user',
    phone: _HostedPinAuth.phone,
    email: 'existing@surgo.test',
    fullName: 'Existing User',
    providers: {'email', 'phone'},
  );

  @override
  Future<AuthUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    emailPasswords.add(password);
    final error = emailError;
    if (error != null) throw error;
    return _user = user;
  }

  @override
  Future<AuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async {
    signupPasswords.add(password);
    return null;
  }

  @override
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) async {
    otpRequests.add((phone: phone, name: fullName, createUser: createUser));
  }

  @override
  Future<void> requestPhoneLink(String phone) async {
    linkRequests.add(phone);
  }

  @override
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    verificationCalls++;
    return verificationResult ?? Future.value(user);
  }

  @override
  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  }) async {
    verificationCalls++;
  }
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
      '/pin': (_) => const Scaffold(body: Text('PIN')),
      '/register': (_) => const Scaffold(body: Text('REGISTER')),
      '/login': (_) => const Scaffold(body: Text('LOGIN')),
      '/forgot-password': (_) => const Scaffold(body: Text('FORGOT')),
      '/email-login': (_) => const EmailLoginScreen(),
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
  if (mode == 'linkPhone') {
    await AppState.instance.requestPhoneLink(phone);
  } else {
    await AppState.instance.sendPhoneOtp(
      phone: phone,
      createUser: mode == 'register',
    );
  }
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
    await tester.ensureVisible(find.text('Login'));
    await tester.tap(find.text('Login'));
    await tester.pumpAndSettle();

    expect(find.text('OTP'), findsOneWidget);
    expect(AppState.instance.isSignedIn, isFalse);
  });

  testWidgets('phone login and alternative methods follow the required order',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());

    final phone = find.text('Phone Number');
    final email = find.text('Login with Email');
    final trouble = find.text('Trouble signing in?');
    final login = find.text('Login');
    final divider = find.text('OR');
    final google = find.text('Continue with Google');
    final facebook = find.text('Continue with Facebook');
    final demo = find.text('Continue with Demo');
    final signUp = find.text('Sign up');

    expect(phone, findsOneWidget);
    expect(email, findsOneWidget);
    expect(trouble, findsOneWidget);
    expect(login, findsOneWidget);
    expect(divider, findsOneWidget);
    expect(google, findsOneWidget);
    expect(facebook, findsOneWidget);
    expect(demo, findsOneWidget);
    expect(signUp, findsOneWidget);

    final phoneY = tester.getTopLeft(phone).dy;
    final emailY = tester.getTopLeft(email).dy;
    final troubleY = tester.getTopLeft(trouble).dy;
    final loginY = tester.getTopLeft(login).dy;
    final dividerY = tester.getTopLeft(divider).dy;
    final googleY = tester.getTopLeft(google).dy;
    final facebookY = tester.getTopLeft(facebook).dy;
    final demoY = tester.getTopLeft(demo).dy;
    final signUpY = tester.getTopLeft(signUp).dy;

    expect(emailY, greaterThan(phoneY));
    expect(troubleY, closeTo(emailY, 2));
    expect(
      tester.getTopLeft(trouble).dx,
      greaterThan(tester.getTopLeft(email).dx),
    );
    expect(loginY, greaterThan(emailY));
    expect(dividerY, greaterThan(loginY));
    expect(googleY, greaterThan(dividerY));
    expect(facebookY, greaterThan(googleY));
    expect(demoY, greaterThan(facebookY));
    expect(signUpY, greaterThan(demoY));
  });

  testWidgets('Facebook sign-in opens the dashboard', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Continue with Facebook'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Facebook'));
    await tester.pumpAndSettle();

    expect(AppState.instance.isSignedIn, isTrue);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('Login with Email opens the email sign-in and sign-up screen',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Login with Email'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Login with Email'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in with email'), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
  });

  testWidgets('email sign-in validates its fields and opens the dashboard',
      (tester) async {
    await pumpScreen(tester, const EmailLoginScreen());
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'not-an-email');
    await tester.enterText(find.byType(TextField).at(1), 'short');
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(
      find.text('Use a password with at least 8 characters.'),
      findsNothing,
    );

    await tester.enterText(
        find.byType(TextField).at(0), 'jr.derigay@email.com');
    await tester.enterText(find.byType(TextField).at(1), 'surgo-demo');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(AppState.instance.isSignedIn, isTrue);
    expect(AppState.instance.currentAccount?.id, 'ACC001');
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('email sign-up creates an account and opens the dashboard',
      (tester) async {
    await pumpScreen(tester, const EmailLoginScreen());
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'Email Tester');
    await tester.enterText(find.byType(TextField).at(1), 'new.user@email.com');
    await tester.enterText(find.byType(TextField).at(2), 'surgo-demo');
    await tester.enterText(find.byType(TextField).at(3), 'surgo-demo');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(AppState.instance.isSignedIn, isTrue);
    expect(AppState.instance.currentAccount?.name, 'Email Tester');
    expect(find.text('HOME'), findsOneWidget);
  });

  for (final password in ['secret', 'secret7']) {
    testWidgets('existing email sign-in accepts ${password.length} characters',
        (tester) async {
      final auth = _HostedRegressionAuth();
      AppState.instance.configureAuth(auth);
      await pumpScreen(tester, const EmailLoginScreen());
      await tester.enterText(
          find.byType(TextField).at(0), 'existing@surgo.test');
      await tester.enterText(find.byType(TextField).at(1), password);
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(auth.emailPasswords, [password]);
      expect(AppState.instance.isSignedIn, isTrue);
      expect(find.text('PIN'), findsOneWidget);
      expect(find.text('Use a password with at least 8 characters.'),
          findsNothing);
    });

    testWidgets('email sign-up rejects ${password.length} characters, accepts 8',
        (tester) async {
      final auth = _HostedRegressionAuth();
      AppState.instance.configureAuth(auth);
      await pumpScreen(tester, const EmailLoginScreen());
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Signup Tester');
      await tester.enterText(find.byType(TextField).at(1), 'signup@surgo.test');
      await tester.enterText(find.byType(TextField).at(2), password);
      await tester.enterText(find.byType(TextField).at(3), password);
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(auth.signupPasswords, isEmpty);
      expect(find.text('Use a password with at least 8 characters.'),
          findsOneWidget);

      await tester.enterText(find.byType(TextField).at(2), 'secret78');
      await tester.enterText(find.byType(TextField).at(3), 'secret78');
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(auth.signupPasswords, ['secret78']);
      expect(find.text('Use a password with at least 8 characters.'),
          findsNothing);
      expect(AppState.instance.isSignedIn, isFalse);
    });
  }

  testWidgets('unknown provider errors do not expose sensitive text in UI',
      (tester) async {
    const sentinel = 'SENSITIVE_PROVIDER_SENTINEL';
    final auth = _HostedRegressionAuth()
      ..emailError = const AuthException('Internal diagnostic: $sentinel');
    AppState.instance.configureAuth(auth);
    await pumpScreen(tester, const EmailLoginScreen());
    await tester.enterText(find.byType(TextField).at(0), 'existing@surgo.test');
    await tester.enterText(find.byType(TextField).at(1), 'secret78');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(auth.emailPasswords, ['secret78']);
    expect(find.textContaining(sentinel, findRichText: true), findsNothing);
    expect(find.text('Something went wrong signing you in. Please try again.'),
        findsOneWidget);
    expect(AppState.instance.authError?.code, AuthFailureCode.unknown);
    expect(AppState.instance.isSignedIn, isFalse);
  });

  testWidgets('demo PIN sign-in validates, then opens the dashboard',
      (tester) async {
    AppState.instance.configureAuth(_HostedPinAuth());
    await pumpScreen(tester, const LoginScreen());
    await tester.ensureVisible(find.text('Continue with Demo'));
    await tester.tap(find.text('Continue with Demo'));
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
    await tester.ensureVisible(find.text('Continue with Demo'));
    await tester.tap(find.text('Continue with Demo'));
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
    await tester.ensureVisible(find.text('Continue with Demo'));
    await tester.tap(find.text('Continue with Demo'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Use a phone number instead'));
    await tester.tap(find.text('Use a phone number instead'));
    await tester.pumpAndSettle();

    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
  });

  testWidgets('an unknown number is refused at the login screen',
      (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).first, '0999 000 0000');
    await tester.ensureVisible(find.text('Login'));
    await tester.tap(find.text('Login'));
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
    await tester.ensureVisible(find.text('Trouble signing in?'));
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

  testWidgets('phone-link resend keeps the current session and phone',
      (tester) async {
    const phone = '+639001112222';
    final auth = _HostedRegressionAuth();
    AppState.instance.configureAuth(auth);
    await AppState.instance.signInWithEmail(
      email: 'existing@surgo.test',
      password: 'secret',
    );
    final userId = AppState.instance.identity?.userId;
    await pumpOtp(tester, phone: phone, mode: 'linkPhone');
    await tester.pump(const Duration(seconds: 42));
    await tester.tap(find.text('Resend code'));
    await tester.pumpAndSettle();

    expect(auth.linkRequests, [phone, phone]);
    expect(auth.otpRequests, isEmpty);
    expect(AppState.instance.identity?.userId, userId);
    expect(AppState.instance.isSignedIn, isTrue);
    expect(find.text('Resend in 0:42'), findsOneWidget);
    expect(find.text('A new code is on its way.'), findsOneWidget);
  });

  for (final mode in ['login', 'register', 'recovery']) {
    testWidgets('$mode resend retains the ordinary OTP request', (tester) async {
      const phone = '+639175124809';
      final auth = _HostedRegressionAuth();
      AppState.instance.configureAuth(auth);
      await pumpOtp(tester, phone: phone, mode: mode, name: 'OTP Tester');
      await tester.pump(const Duration(seconds: 42));
      await tester.tap(find.text('Resend code'));
      await tester.pumpAndSettle();

      expect(auth.otpRequests, hasLength(2));
      expect(auth.otpRequests.last,
          (phone: phone, name: 'OTP Tester', createUser: mode == 'register'));
      expect(auth.linkRequests, isEmpty);
      expect(find.text('Resend in 0:42'), findsOneWidget);
    });
  }

  testWidgets('demo OTP resend still verifies with the preview code',
      (tester) async {
    await pumpOtp(tester, phone: '+639175124809');
    await tester.pump(const Duration(seconds: 42));
    await tester.tap(find.text('Resend code'));
    await tester.pumpAndSettle();

    expect(find.text('Preview code: ${MockAuthRepository.defaultOtpCode}'),
        findsOneWidget);
    await enterCode(tester, MockAuthRepository.defaultOtpCode);
    expect(find.text('HOME'), findsOneWidget);
    expect(AppState.instance.currentAccount?.id, 'ACC001');
  });

  for (final mode in ['login', 'linkPhone']) {
    testWidgets('disposed $mode OTP skips delayed verification', (tester) async {
      final auth = _HostedRegressionAuth();
      AppState.instance.configureAuth(auth);
      await pumpOtp(tester, phone: '+639175124809', mode: mode);
      final fields = find.byType(TextField);
      for (var i = 0; i < 6; i++) {
        await tester.enterText(fields.at(i), '$i');
      }
      await tester.pumpWidget(const MaterialApp(
        key: ValueKey('disposed-otp'),
        home: Text('DISPOSED'),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(auth.verificationCalls, 0);
      expect(find.text('DISPOSED'), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(AppState.instance.isSignedIn, isFalse);
    });
  }

  testWidgets('verification finishing after disposal does not navigate',
      (tester) async {
    final completion = Completer<AuthUser>();
    final auth = _HostedRegressionAuth()
      ..verificationResult = completion.future;
    AppState.instance.configureAuth(auth);
    await pumpOtp(tester, phone: '+639175124809');
    final fields = find.byType(TextField);
    for (var i = 0; i < 6; i++) {
      await tester.enterText(fields.at(i), '$i');
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(auth.verificationCalls, 1);

    await tester.pumpWidget(const MaterialApp(
      key: ValueKey('disposed-otp'),
      home: Text('DISPOSED'),
    ));
    completion.complete(_HostedRegressionAuth.user);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('DISPOSED'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
    expect(AppState.instance.isSignedIn, isTrue);
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
