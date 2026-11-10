import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/demo_auth.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/screens/login_screen.dart';
import 'package:surgo/screens/pin_lock_screen.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/theme/app_theme.dart';

/// Exercises the presentation path end to end without Supabase: account-number
/// sign-in, a persisted session, the device PIN and logout. The persisted
/// session is seeded before the app boots, which is what a relaunch sees.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;
  var bootChecked = false;

  Future<void> signIn(String accountNumber) async {
    final account = state.demoAccountFor(accountNumber);
    expect(account, isNotNull);
    expect(await state.sendPhoneOtp(phone: account!.phone), isNull);
    expect(
      await state.verifyPhoneOtp(
        phone: account.phone,
        token: DemoAuthConfig.defaultOtpCode,
      ),
      isNull,
    );
  }

  setUpAll(() async {
    DemoAuthConfig.enabled = true;
    SharedPreferences.setMockInitialValues({
      SharedPreferencesDemoSessionStore.storageKey: jsonEncode({
        'userId': 'mock:phone:+639267713390',
        'phone': '+63 926 771 3390',
        'email': 'bebot.lim@email.com',
        'fullName': 'Bebot Lim',
        'providers': ['phone'],
      }),
    });

    state = AppState.instance;
    state.configureAuth(
      MockAuthRepository(
        sessionStore: SharedPreferencesDemoSessionStore(),
      ),
    );
    await state.init();
  });

  tearDownAll(() {
    DemoAuthConfig.enabled = false;
  });

  setUp(() async {
    if (!bootChecked) return;
    await state.logout();
    await state.pinStore.reset();
  });

  test('a persisted session restores the role and starts locked', () async {
    expect(state.isSignedIn, isTrue);
    expect(state.currentAccount?.id, 'ACC006');
    expect(state.availableModes, [UserMode.passenger, UserMode.earner]);
    expect(state.mode, UserMode.earner);
    expect(state.requiresPin, isTrue);
    bootChecked = true;

    expect(await state.unlockWithPin('000000'), PinUnlockResult.incorrect);
    expect(state.requiresPin, isTrue);

    expect(
      await state.unlockWithPin(DemoAuthConfig.defaultPin),
      PinUnlockResult.success,
    );
    expect(state.requiresPin, isFalse);
  });

  test('signs in with an account number and the default OTP', () async {
    final account = state.demoAccountFor('acc003');
    expect(account?.id, 'ACC003');

    await signIn('ACC003');
    expect(state.isSignedIn, isTrue);
    expect(state.currentAccount?.id, 'ACC003');
    expect(state.currentAccount?.name, 'Nena Villareal');
    expect(state.mode, UserMode.passenger);
  });

  test('the vehicle owner identity lands on the owner dashboard', () async {
    await signIn('ACC002');
    expect(state.currentAccount?.id, 'ACC002');
    expect(state.availableModes, [UserMode.passenger, UserMode.vehicleOwner]);
    expect(state.mode, UserMode.vehicleOwner);
    expect(state.db.vehicleOwner.id, 'VOW-77214');
  });

  test('the helper identity lands on the earner dashboard with errands',
      () async {
    await signIn('ACC007');
    expect(state.currentAccount?.id, 'ACC007');
    expect(state.mode, UserMode.earner);
    expect(state.acceptsCapability(EarnerCapability.errands), isTrue);
  });

  test('unknown account numbers are refused', () async {
    expect(state.demoAccountFor('ACC999'), isNull);
    expect(state.demoAccountFor(''), isNull);
  });

  test('the session survives a new provider instance', () async {
    await signIn('ACC006');

    final restarted = MockAuthRepository(
      sessionStore: SharedPreferencesDemoSessionStore(),
    );
    final user = await restarted.restoreSession();
    expect(user, isNotNull);
    expect(user!.phone, '+639267713390');

    final identity = await restarted.loadIdentity(user);
    expect(identity.capabilities, contains(CapabilityType.earner));
    expect(identity.capabilities, contains(CapabilityType.passenger));
  });

  test('changing the PIN replaces the accepted value', () async {
    await signIn('ACC003');

    expect(
      await state.changePin(
        currentPin: DemoAuthConfig.defaultPin,
        newPin: '654321',
      ),
      PinChangeResult.success,
    );
    expect(await state.pinStore.verify('123456'), isFalse);
    expect(await state.pinStore.verify('654321'), isTrue);

    expect(
      await state.changePin(currentPin: '000000', newPin: '111111'),
      PinChangeResult.incorrectCurrent,
    );
    expect(
      await state.changePin(currentPin: '654321', newPin: '654321'),
      PinChangeResult.sameAsCurrent,
    );
    expect(
      await state.changePin(currentPin: '654321', newPin: '123'),
      PinChangeResult.invalidNew,
    );
  });

  test('logout clears the persisted session', () async {
    await signIn('ACC003');
    await state.logout();

    expect(state.isSignedIn, isFalse);
    expect(
      await MockAuthRepository(
        sessionStore: SharedPreferencesDemoSessionStore(),
      ).restoreSession(),
      isNull,
    );
  });

  testWidgets('the login form accepts a demo account number', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const LoginScreen(),
      routes: {
        '/otp': (_) => const Scaffold(body: Text('OTP')),
        '/home': (_) => const Scaffold(body: Text('HOME')),
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('DEMO ACCOUNTS'), findsOneWidget);
    await tester.tap(find.text('ACC003'));
    await tester.pump();
    await tester.ensureVisible(find.text('Send code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(find.text('OTP'), findsOneWidget);
    expect(state.isSignedIn, isFalse);
  });

  testWidgets('a wrong PIN is refused and the correct PIN opens the dashboard',
      (tester) async {
    await signIn('ACC003');
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const PinLockScreen(),
      routes: {
        '/home': (_) => const Scaffold(body: Text('HOME')),
        '/login': (_) => const Scaffold(body: Text('LOGIN')),
      },
    ));
    await tester.pumpAndSettle();

    await enterPin(tester, '000000');
    expect(find.text('That PIN is incorrect. Try again.'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
    expect(state.isSignedIn, isTrue);

    await enterPin(tester, DemoAuthConfig.defaultPin);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('forgot PIN signs out and returns to authentication',
      (tester) async {
    await signIn('ACC003');
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const PinLockScreen(),
      routes: {
        '/home': (_) => const Scaffold(body: Text('HOME')),
        '/login': (_) => const Scaffold(body: Text('LOGIN')),
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forgot PIN? Sign in again'));
    await tester.pumpAndSettle();

    expect(find.text('LOGIN'), findsOneWidget);
    expect(state.isSignedIn, isFalse);
    expect(await state.pinStore.verify(DemoAuthConfig.defaultPin), isTrue);
  });
}

Future<void> enterPin(WidgetTester tester, String pin) async {
  final fields = find.byType(TextField);
  for (var i = 0; i < pin.length; i++) {
    await tester.enterText(fields.at(i), pin[i]);
  }
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}
