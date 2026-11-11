import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/demo_auth.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';

/// A host-backed provider with no network. It reports `isMock = false`, which
/// puts [AppState] on the hosted-session path, and exposes a broadcast stream
/// so a test can deliver the sign-in / refresh / revoke events Supabase would.
class _HostedAuth implements AuthRepository {
  _HostedAuth({
    this.userId = _uuidA,
    this.phone = '+639170009911',
    this.email,
    this.needsOnboarding = false,
    this.demo = false,
    AuthUser? persisted,
  }) : _user = persisted;

  static const String _uuidA = '11111111-1111-1111-1111-111111111111';

  String userId;
  String? phone;
  final String? email;
  bool needsOnboarding;

  /// Marks the identity as one of the provisioned demo accounts, the same
  /// `surgo_demo` marker the provisioning tool writes to app_metadata.
  final bool demo;

  /// When true, [restoreSession] reports no valid session even if an event
  /// payload still carries a user — the revoked / expired refresh-token case.
  bool restoreReturnsNull = false;

  AuthUser? _user;
  final StreamController<AuthUser?> _controller =
      StreamController<AuthUser?>.broadcast();

  AuthUser _makeUser() => AuthUser(
        id: userId,
        phone: phone,
        email: email,
        fullName: 'Hosted Tester',
        providers: const {'google'},
        metadata: {
          if (!needsOnboarding) 'surgo_onboarded': true,
        },
        isDemoAccount: demo,
      );

  /// Delivers the session event a sign-in or relaunch would produce.
  void emitSession() {
    _user = _makeUser();
    _controller.add(_user);
  }

  /// Delivers a stale user payload while [restoreSession] reports null, the
  /// shape of an initialSession emitted before a failed refresh settled.
  void emitStalePayload() => _controller.add(_makeUser());

  void emitSignedOut() {
    _user = null;
    _controller.add(null);
  }

  @override
  bool get isMock => false;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges => _controller.stream;

  @override
  Future<AuthUser?> restoreSession() async => restoreReturnsNull ? null : _user;

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async {
    _user = _makeUser();
    return _user!;
  }

  @override
  Future<bool> signInWithGoogle() async {
    _user = _makeUser();
    return true;
  }

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
      email: user.email,
      fullName: user.fullName,
      capabilities: capabilities,
      eligibleCapabilities: eligibleCapabilitiesFor(capabilities),
      roles: const {'passenger'},
      providers: user.providers,
      profileExists: true,
      needsOnboarding: needsOnboarding,
      isDemoAccount: user.isDemoAccount,
    );
  }

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {
    this.phone = phone;
    needsOnboarding = false;
    _user = _makeUser();
  }

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

/// Lets the unawaited auth-event handler and its queued identity load drain.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  const uuidA = _HostedAuth._uuidA;
  const uuidB = '22222222-2222-2222-2222-222222222222';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await state.init();
  });

  setUp(() async {
    await state.logout();
    await state.pinStore.reset(uuidA);
    await state.pinStore.reset(uuidB);
    state.configureAuth(MockAuthRepository());
  });

  tearDown(() async {
    await state.logout();
    state.configureAuth(MockAuthRepository());
  });

  test('a fresh hosted Google sign-in ends behind the device PIN', () async {
    state.configureAuth(_HostedAuth());

    expect(await state.signInWithGoogle(), isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.usesHostedIdentity, isTrue);
    expect(state.requiresPin, isTrue);
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);

    expect(await state.setPin('123456'), isTrue);
    expect(await state.pinConfiguredForCurrentAccount(), isTrue);

    // The PIN lives under the stable auth uuid, not the regenerated local id.
    expect(state.currentAccount?.id, isNot(uuidA));
    expect(await state.pinStore.verify(uuidA, '123456'), isTrue);

    expect(await state.unlockWithPin('000000'), PinUnlockResult.incorrect);
    expect(state.requiresPin, isTrue);
    expect(await state.unlockWithPin('123456'), PinUnlockResult.success);
    expect(state.requiresPin, isFalse);
  });

  test('a hosted PIN survives a relaunch under the same auth uuid', () async {
    state.configureAuth(_HostedAuth());
    await state.signInWithGoogle();
    await state.setPin('246810');
    await state.unlockWithPin('246810');
    await state.logout();

    // A new provider instance restores the persisted session, exactly as a
    // browser restart does. The local account id is regenerated, but the PIN
    // is keyed by the auth uuid so the returning account still finds it.
    final relaunched = _HostedAuth(persisted: AuthUser(
      id: uuidA,
      phone: '+639170009911',
      fullName: 'Hosted Tester',
      providers: const {'google'},
      metadata: const {'surgo_onboarded': true},
    ));
    state.configureAuth(relaunched);
    relaunched.emitSession();
    await settle();

    expect(state.isSignedIn, isTrue);
    expect(state.currentAccount?.id, isNot(uuidA));
    expect(state.requiresPin, isTrue);
    expect(await state.pinConfiguredForCurrentAccount(), isTrue);
    expect(await state.unlockWithPin('246810'), PinUnlockResult.success);
    expect(state.requiresPin, isFalse);
  });

  test('switching hosted accounts cannot reuse the previous PIN', () async {
    state.configureAuth(_HostedAuth());
    await state.signInWithGoogle();
    await state.setPin('111111');
    await state.logout();

    state.configureAuth(_HostedAuth(userId: uuidB, phone: '+639170009922'));
    await state.signInWithGoogle();
    expect(state.requiresPin, isTrue);
    expect(await state.pinConfiguredForCurrentAccount(), isFalse);
    expect(await state.unlockWithPin('111111'), PinUnlockResult.incorrect);

    expect(await state.setPin('222222'), isTrue);
    expect(await state.pinStore.verify(uuidB, '222222'), isTrue);
    // The first account's lock is untouched on the same device.
    expect(await state.pinStore.verify(uuidA, '111111'), isTrue);
  });

  test('a token refresh for the same account does not relock', () async {
    final auth = _HostedAuth();
    state.configureAuth(auth);
    await state.signInWithGoogle();
    await state.setPin('123456');
    await state.unlockWithPin('123456');
    expect(state.requiresPin, isFalse);

    // Supabase re-emits the same user on token refresh / metadata update. The
    // unlocked run must keep its unlock rather than being locked again.
    auth.emitSession();
    await settle();
    expect(state.isSignedIn, isTrue);
    expect(state.requiresPin, isFalse);
  });

  test('a revoked hosted session fails closed to sign-in', () async {
    final auth = _HostedAuth();
    state.configureAuth(auth);
    await state.signInWithGoogle();
    await state.setPin('123456');
    await state.unlockWithPin('123456');
    expect(state.isSignedIn, isTrue);

    // A stale event payload arrives, but the provider can no longer restore a
    // valid session. The app must not resurrect the revoked account.
    auth.restoreReturnsNull = true;
    auth.emitStalePayload();
    await settle();

    expect(state.isSignedIn, isFalse);
    expect(state.requiresPin, isFalse);
    expect(state.authStatus, AuthStatus.signedOut);
  });

  test('an explicit signed-out event clears the session', () async {
    final auth = _HostedAuth();
    state.configureAuth(auth);
    await state.signInWithGoogle();
    await state.setPin('123456');
    await state.unlockWithPin('123456');
    expect(state.isSignedIn, isTrue);

    auth.emitSignedOut();
    await settle();
    expect(state.isSignedIn, isFalse);
    expect(state.authStatus, AuthStatus.signedOut);
  });

  test('logout clears the session and unlock state, keeps the device PIN',
      () async {
    final auth = _HostedAuth();
    state.configureAuth(auth);
    await state.signInWithGoogle();
    await state.setPin('123456');
    await state.unlockWithPin('123456');

    await state.logout();
    expect(state.isSignedIn, isFalse);
    expect(state.requiresPin, isFalse);
    expect(state.identity, isNull);
    expect(await auth.restoreSession(), isNull);
    // The device-local PIN stays so signing back in asks to unlock, not bypass.
    expect(await state.pinStore.verify(uuidA, '123456'), isTrue);
  });

  test('a new hosted Google account onboards before the PIN', () async {
    state.configureAuth(_HostedAuth(
      phone: null,
      email: 'new-google@example.com',
      needsOnboarding: true,
    ));
    await state.signInWithGoogle();
    expect(state.requiresOnboarding, isTrue);
    expect(state.requiresPin, isTrue);

    final failure = await state.completeOnboarding(
      fullName: 'New Google',
      phone: '+639170009933',
    );
    expect(failure, isNull);
    expect(state.requiresOnboarding, isFalse);
    // Onboarding completes into the PIN, not straight to the dashboard.
    expect(state.requiresPin, isTrue);
    expect(await state.setPin('123456'), isTrue);
    expect(await state.unlockWithPin('123456'), PinUnlockResult.success);
    expect(state.requiresPin, isFalse);
  });

  test('a provisioned demo account signs in without the device PIN', () async {
    state.configureAuth(_HostedAuth(demo: true));

    final failure = await state.signInWithDemoPin(
      phone: '09170000001',
      pin: '246810',
    );
    expect(failure, isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.isDemoAccount, isTrue);
    // The PIN just verified by the server is the only credential; stacking the
    // device lock on top would ask for the same secret twice.
    expect(state.requiresPin, isFalse);

    await state.logout();

    // A relaunch restores the session and reads the same demo marker, so the
    // presenter is not sent to a second lock screen.
    final relaunched = _HostedAuth(
      demo: true,
      persisted: const AuthUser(
        id: uuidA,
        phone: '+639170000001',
        fullName: 'Hosted Tester',
        providers: {'phone'},
        isDemoAccount: true,
      ),
    );
    state.configureAuth(relaunched);
    relaunched.emitSession();
    await settle();

    expect(state.isSignedIn, isTrue);
    expect(state.isDemoAccount, isTrue);
    expect(state.requiresPin, isFalse);
  });
}