import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';

/// Exercises the auth bridge without a network: the in-memory provider stands
/// in for Supabase Auth, and the seed supplies the profiles and roles. Passwords
/// do not exist anywhere in this path.
void main() {
  late AppState state;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    state = AppState.instance;
    await state.init();
  });

  setUp(() async {
    await state.logout();
  });

  Future<AuthFailure?> signIn(String rawPhone) async {
    final phone = normalizePhoneNumber(rawPhone)!;
    final request = await state.sendPhoneOtp(phone: phone);
    if (request != null) return request;
    return state.verifyPhoneOtp(
      phone: phone,
      token: MockAuthRepository.defaultOtpCode,
    );
  }

  test('signs in a seeded phone with a one-time code', () async {
    expect(await signIn('+63 917 512 4809'), isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.authStatus, AuthStatus.signedIn);
    expect(state.currentAccount?.id, 'ACC001');
    expect(state.identity?.hasPhoneIdentity, isTrue);
  });

  test('refuses an unknown number instead of creating an account', () async {
    final failure = await state.sendPhoneOtp(
      phone: normalizePhoneNumber('+63 999 000 0000')!,
    );
    expect(failure?.code, AuthFailureCode.noAccount);
    expect(state.isSignedIn, isFalse);
  });

  test('refuses a wrong code and stays signed out', () async {
    final phone = normalizePhoneNumber('+63 917 512 4809')!;
    expect(await state.sendPhoneOtp(phone: phone), isNull);
    final failure = await state.verifyPhoneOtp(phone: phone, token: '000000');
    expect(failure?.code, AuthFailureCode.invalidCode);
    expect(state.isSignedIn, isFalse);
  });

  test('a multi-role account can act as every role', () async {
    await signIn('+63 917 512 4809');
    expect(state.availableModes,
        [UserMode.passenger, UserMode.earner, UserMode.vehicleOwner]);
    expect(state.mode, UserMode.passenger);

    state.switchToMode(UserMode.vehicleOwner);
    expect(state.mode, UserMode.vehicleOwner);
  });

  test('an account cannot switch to a role it lacks', () async {
    await signIn('+63 926 771 3390'); // ACC006, passenger + earner
    expect(state.availableModes, [UserMode.passenger, UserMode.earner]);

    state.switchToMode(UserMode.vehicleOwner);
    expect(state.mode, UserMode.passenger);

    state.switchToMode(UserMode.earner);
    expect(state.mode, UserMode.earner);
  });

  test('approval gates a mode; eligibility alone does not', () async {
    await signIn('+63 917 220 4411'); // ACC002, owner but not earner
    expect(state.availableModes, [UserMode.passenger, UserMode.vehicleOwner]);
    expect(state.authorizedFor(CapabilityType.vehicleOwner), isTrue);
    expect(state.authorizedFor(CapabilityType.earner), isFalse);
    expect(state.canApplyFor(CapabilityType.earner), isTrue);

    state.switchToMode(UserMode.earner);
    expect(state.mode, UserMode.passenger);
  });

  test('signing in swaps the wallet and profile the screens read', () async {
    expect(state.db.passenger.id, 'P001');

    await signIn('+63 917 220 4411');
    expect(state.db.passenger.id, 'P002');
    expect(state.db.passengerWalletBalance, 124000);
    expect(state.db.passengerTransactions, isNotEmpty);

    await state.logout();
    expect(state.db.passenger.id, 'P001');
    expect(state.db.passengerWalletBalance, 85000);
    expect(state.authStatus, AuthStatus.signedOut);
  });

  test('registration creates and signs into a fresh passenger account',
      () async {
    final phone = normalizePhoneNumber('+63 900 000 0000')!;
    expect(
      await state.sendPhoneOtp(
        phone: phone,
        fullName: 'Test User',
        createUser: true,
      ),
      isNull,
    );
    expect(
      await state.verifyPhoneOtp(
        phone: phone,
        token: MockAuthRepository.defaultOtpCode,
      ),
      isNull,
    );

    expect(state.isSignedIn, isTrue);
    expect(state.db.passenger.id, isNot('P001'));
    expect(state.db.passenger.name, 'Test User');
    expect(state.availableModes, [UserMode.passenger]);

    // The same Supabase user maps back to the same demo record.
    final accountId = state.currentAccount?.id;
    await state.logout();
    await signIn(phone);
    expect(state.currentAccount?.id, accountId);
  });

  test('Google signs in and can be linked to the phone account', () async {
    final failure = await state.signInWithGoogle();
    expect(failure, isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.identity?.hasGoogleIdentity, isTrue);
    expect(state.db.passenger.id, 'P001');
  });

  test('Facebook signs in through the same hosted identity path', () async {
    final failure = await state.signInWithFacebook();
    expect(failure, isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.identity?.providers, contains('facebook'));
  });

  test('email signs into the seeded account that owns the address', () async {
    final failure = await state.signInWithEmail(
      email: 'jr.derigay@email.com',
      password: 'surgo-demo',
    );
    expect(failure, isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.currentAccount?.id, 'ACC001');
    expect(state.identity?.email, 'jr.derigay@email.com');
  });

  test('email sign-up creates a fresh passenger account', () async {
    final failure = await state.signUpWithEmail(
      email: 'email.tester@surgo.test',
      password: 'surgo-demo',
      fullName: 'Email Tester',
    );
    expect(failure, isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.db.passenger.name, 'Email Tester');
    expect(state.availableModes, [UserMode.passenger]);
  });

  test('linking Google adds the identity to the session', () async {
    await signIn('+63 917 512 4809');
    expect(state.identity?.hasGoogleIdentity, isFalse);

    expect(await state.linkGoogleIdentity(), isNull);
    expect(state.identity?.hasGoogleIdentity, isTrue);
    expect(state.identity?.hasPhoneIdentity, isTrue);
  });

  test('a second phone identity can be linked after Google sign-in', () async {
    await state.signInWithGoogle();
    final phone = normalizePhoneNumber('+63 900 111 2222')!;

    expect(await state.requestPhoneLink(phone), isNull);
    expect(
      await state.verifyPhoneLink(
        phone: phone,
        token: MockAuthRepository.defaultOtpCode,
      ),
      isNull,
    );
    expect(state.identity?.hasPhoneIdentity, isTrue);
    expect(state.identity?.phone, phone);
  });

  test('logout clears the local session cache', () async {
    await signIn('+63 917 512 4809');
    await state.logout();
    expect(state.isSignedIn, isFalse);
    expect(state.identity, isNull);
    expect(state.availableModes, UserMode.values);
  });

  test('normalizes the phone shapes people type', () {
    expect(normalizePhoneNumber('0917 512 4809'), '+639175124809');
    expect(normalizePhoneNumber('+63 917 512 4809'), '+639175124809');
    expect(normalizePhoneNumber('639175124809'), '+639175124809');
    expect(normalizePhoneNumber('9175124809'), '+639175124809');
    expect(normalizePhoneNumber('00 63 917 512 4809'), '+639175124809');
    expect(normalizePhoneNumber('nope'), isNull);
  });

  test('rejects non-PH, duplicated or wrong-length numbers', () {
    // Only the PH country code is accepted.
    expect(normalizePhoneNumber('+1 415 555 0100'), isNull);
    // Landlines and duplicated code/zero prefixes must not slip through.
    expect(normalizePhoneNumber('+63 02 8123 4567'), isNull);
    expect(normalizePhoneNumber('+63 0917 123 4567'), isNull);
    expect(normalizePhoneNumber('0063 63 917 123 4567'), isNull);
    // 10-digit local and 11-digit national numbers are both short.
    expect(normalizePhoneNumber('0917 123 456'), isNull);
    expect(normalizePhoneNumber('+63 917 123 45678'), isNull);
    expect(normalizePhoneNumber(''), isNull);
  });

  test('maps provider errors to user-facing failures', () {
    final expired = AuthFailure.from(
      const AuthException('Token has expired or is invalid'),
    );
    expect(expired.code, AuthFailureCode.invalidCode);

    final limited = AuthFailure.from(
      const AuthException(
          'For security purposes, you can only request this after 60 seconds'),
    );
    expect(limited.code, AuthFailureCode.rateLimited);

    final disabled = AuthFailure.from(
      const AuthException('Phone provider is not enabled'),
    );
    expect(disabled.code, AuthFailureCode.providerUnavailable);
  });

  test('known email provider failures retain their safe codes and messages', () {
    const cases = [
      (
        'Invalid email',
        AuthFailureCode.invalidEmail,
        'Enter a valid email address.',
      ),
      (
        'Email not confirmed',
        AuthFailureCode.emailNotConfirmed,
        'Confirm your email address before signing in.',
      ),
      (
        'User already registered',
        AuthFailureCode.emailInUse,
        'An account with that email already exists. Sign in instead.',
      ),
      (
        'Invalid login credentials',
        AuthFailureCode.invalidCredentials,
        'That email and password do not match a SurGo account.',
      ),
      (
        'Password should be at least 6 characters',
        AuthFailureCode.weakPassword,
        'Use a password with at least 8 characters.',
      ),
    ];
    for (final (providerMessage, code, message) in cases) {
      final failure = AuthFailure.from(AuthException(providerMessage));
      expect(failure.code, code);
      expect(failure.message, message);
    }
  });

  test('unknown provider failures discard sensitive diagnostics', () {
    const sentinel = 'SENSITIVE_PROVIDER_SENTINEL';
    final failure = AuthFailure.from(
      const AuthException('Internal diagnostic: $sentinel'),
    );

    expect(failure.code, AuthFailureCode.unknown);
    expect(failure.message,
        'Something went wrong signing you in. Please try again.');
    expect(failure.message, isNot(contains(sentinel)));
    expect(failure.toString(), isNot(contains(sentinel)));
  });
}
