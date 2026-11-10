import 'dart:convert';

import 'package:crypto/crypto.dart';
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
/// sign-in, a persisted session, the per-account device PIN and logout. The
/// persisted session is seeded before the app boots, which is what a relaunch
/// sees.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;
  var bootChecked = false;

  const demoAccountIds = ['ACC002', 'ACC003', 'ACC006', 'ACC007'];

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

  Future<void> clearPins() async {
    for (final id in demoAccountIds) {
      await state.pinStore.reset(id);
    }
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
    await clearPins();
  });

  test('a persisted session restores the role and starts locked', () async {
    expect(state.isSignedIn, isTrue);
    expect(state.currentAccount?.id, 'ACC006');
    expect(state.availableModes, [UserMode.passenger, UserMode.earner]);
    expect(state.mode, UserMode.earner);
    expect(state.requiresPin, isTrue);
    bootChecked = true;

    // A restored account that never chose a PIN must create one; there is no
    // shared default that could unlock it.
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);
    expect(
      await state.unlockWithPin(DemoAuthConfig.defaultPin),
      PinUnlockResult.incorrect,
    );
    expect(await state.setPin(DemoAuthConfig.defaultPin), isTrue);
    expect(await state.pinConfiguredForCurrentAccount(), isTrue);

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
    expect(state.requiresPin, isTrue);
  });

  test('Google sign-in also ends behind the device PIN', () async {
    expect(await state.signInWithGoogle(), isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.requiresPin, isTrue);
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);

    final id = state.currentAccount!.id;
    expect(await state.setPin('135790'), isTrue);
    expect(await state.pinStore.verify(id, '135790'), isTrue);
    expect(await state.unlockWithPin('135790'), PinUnlockResult.success);
    expect(state.requiresPin, isFalse);
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

  test('the saved PIN is salted and hashed, never stored in clear text',
      () async {
    await signIn('ACC003');
    expect(await state.setPin('246810'), isTrue);

    final id = state.currentAccount!.id;
    final preferences = await SharedPreferences.getInstance();
    final salt = preferences.getString(DemoPinStore.saltKeyFor(id));
    final hash = preferences.getString(DemoPinStore.hashKeyFor(id));
    expect(salt, isNotNull);
    expect(hash, isNotNull);
    expect(hash, isNot(contains('246810')));
    expect(preferences.getString(DemoPinStore.legacyHashKey), isNull);
  });

  test('a PIN belongs to one account and cannot unlock another', () async {
    await signIn('ACC003');
    expect(await state.setPin('111111'), isTrue);
    await state.logout();

    await signIn('ACC002');
    // The new account has no PIN of its own: the old account's code is not a
    // fallback and is treated as incorrect.
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);
    expect(await state.unlockWithPin('111111'), PinUnlockResult.incorrect);

    expect(await state.setPin('222222'), isTrue);
    expect(await state.pinStore.verify('ACC002', '222222'), isTrue);
    expect(await state.pinStore.verify('ACC003', '222222'), isFalse);
    expect(await state.pinStore.verify('ACC003', '111111'), isTrue);
  });

  test('a legacy device PIN is adopted once by the first account', () async {
    final preferences = await SharedPreferences.getInstance();
    const salt = 'legacy-salt';
    await preferences.setString(DemoPinStore.legacySaltKey, salt);
    await preferences.setString(
      DemoPinStore.legacyHashKey,
      sha256.convert(utf8.encode('$salt:123456')).toString(),
    );

    await signIn('ACC003');
    expect(await state.pinConfiguredForCurrentAccount(), isTrue);
    expect(await state.unlockWithPin('123456'), PinUnlockResult.success);
    expect(preferences.getString(DemoPinStore.legacySaltKey), isNull);
    expect(preferences.getString(DemoPinStore.legacyHashKey), isNull);

    await state.logout();
    await signIn('ACC002');
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);
    expect(await state.unlockWithPin('123456'), PinUnlockResult.incorrect);
  });

  test('changing the PIN replaces the accepted value for that account only',
      () async {
    await signIn('ACC003');
    expect(await state.setPin(DemoAuthConfig.defaultPin), isTrue);

    expect(
      await state.changePin(
        currentPin: DemoAuthConfig.defaultPin,
        newPin: '654321',
      ),
      PinChangeResult.success,
    );
    expect(await state.pinStore.verify('ACC003', '123456'), isFalse);
    expect(await state.pinStore.verify('ACC003', '654321'), isTrue);

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
    expect(await state.pinStore.verify('ACC002', '654321'), isFalse);
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

  testWidgets('a new account creates, confirms and enters its PIN',
      (tester) async {
    await signIn('ACC003');
    await pumpPinScreen(tester);

    expect(find.text('Create your PIN'), findsOneWidget);
    await enterPin(tester, '246810');
    expect(find.text('Confirm your PIN'), findsOneWidget);

    await enterPin(tester, '246810');
    expect(find.text('PIN created. Enter it to unlock SurGo.'), findsOneWidget);
    expect(await state.pinConfiguredForCurrentAccount(), isTrue);

    await enterPin(tester, '246810');
    expect(find.text('HOME'), findsOneWidget);
    expect(state.requiresPin, isFalse);
  });

  testWidgets('a mismatched confirmation returns to PIN creation',
      (tester) async {
    await signIn('ACC003');
    await pumpPinScreen(tester);

    await enterPin(tester, '111111');
    expect(find.text('Confirm your PIN'), findsOneWidget);
    await enterPin(tester, '222222');

    expect(
      find.text('Those PINs did not match. Create it again.'),
      findsOneWidget,
    );
    expect(find.text('Create your PIN'), findsOneWidget);
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);
  });

  testWidgets('a wrong PIN is refused and the correct PIN opens the dashboard',
      (tester) async {
    await signIn('ACC003');
    expect(await state.setPin(DemoAuthConfig.defaultPin), isTrue);
    await pumpPinScreen(tester);

    expect(find.text('Welcome back, Nena'), findsOneWidget);
    await enterPin(tester, '000000');
    expect(
      find.text('That PIN is incorrect. 4 attempts left.'),
      findsOneWidget,
    );
    expect(find.text('HOME'), findsNothing);
    expect(state.isSignedIn, isTrue);

    await enterPin(tester, DemoAuthConfig.defaultPin);
    expect(find.text('HOME'), findsOneWidget);
    expect(state.requiresPin, isFalse);
  });

  testWidgets('five wrong PINs lock the keypad temporarily', (tester) async {
    await signIn('ACC003');
    expect(await state.setPin(DemoAuthConfig.defaultPin), isTrue);
    await pumpPinScreen(tester);

    for (var attempt = 0; attempt < 5; attempt++) {
      await enterPin(tester, '000000', settle: false);
    }
    await tester.pump();
    expect(
      find.text('Too many incorrect attempts. Try again in 30s.'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.textContaining('Too many incorrect attempts'), findsNothing);
  });

  testWidgets('forgot PIN signs out and leaves other accounts untouched',
      (tester) async {
    await signIn('ACC003');
    expect(await state.setPin(DemoAuthConfig.defaultPin), isTrue);
    await state.pinStore.setPin('ACC002', '222222');
    await pumpPinScreen(tester);

    await tester.tap(find.text('Forgot PIN? Sign in again'));
    await tester.pumpAndSettle();

    expect(find.text('LOGIN'), findsOneWidget);
    expect(state.isSignedIn, isFalse);
    expect(await state.pinStore.verify('ACC003', DemoAuthConfig.defaultPin),
        isFalse);
    expect(await state.pinStore.verify('ACC002', '222222'), isTrue);
  });
}

Future<void> pumpPinScreen(WidgetTester tester) async {
  // The PIN screen holds the brand, indicators, keypad and footer; a phone
  // shaped surface keeps every key visible so taps land on real hit targets.
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: const PinLockScreen(),
    routes: {
      '/home': (_) => const Scaffold(body: Text('HOME')),
      '/login': (_) => const Scaffold(body: Text('LOGIN')),
    },
  ));
  await tester.pumpAndSettle();
}

/// Types a PIN on the on-screen keypad, one key at a time. The screen submits
/// 150 ms after the sixth digit, so each tap advances that delay too.
Future<void> enterPin(
  WidgetTester tester,
  String pin, {
  bool settle = true,
}) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.byKey(ValueKey('pin-key-$digit')));
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (settle) await tester.pumpAndSettle();
}