import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';

/// A host-backed auth provider with no network. It reports `isMock = false`,
/// which is what puts [AppState] on the hosted-session path.
class _HostedFakeAuth implements AuthRepository {
  _HostedFakeAuth({
    required this.phone,
    this.email,
    this.needsOnboarding = false,
    this.id = 'hosted-user',
    this.fullName = 'Hosted Tester',
    this.capabilities = const {CapabilityType.passenger},
  });

  String? phone;
  final String? email;
  bool needsOnboarding;
  final String id;
  final String fullName;
  final Set<CapabilityType> capabilities;
  bool _signedInWithDemoPin = false;
  AuthUser? _user;

  AuthUser _currentUser() => AuthUser(
        id: id,
        phone: phone,
        email: email,
        fullName: fullName,
        providers: _signedInWithDemoPin ? const {'phone'} : const {'google'},
        metadata: needsOnboarding
            ? const {}
            : const {'surgo_onboarded': true},
        isDemoAccount: _signedInWithDemoPin,
      );

  @override
  bool get isMock => false;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<AuthUser?> restoreSession() async => _user;

  @override
  Future<bool> signInWithGoogle() async {
    _signedInWithDemoPin = false;
    _user = _currentUser();
    return true;
  }

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async {
    _signedInWithDemoPin = true;
    _user = _currentUser();
    return _user!;
  }

  @override
  Future<void> signOut() async {
    _user = null;
  }

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    final caps = capabilities;
    return SurgoIdentity(
      userId: user.id,
      phone: user.phone,
      email: user.email,
      fullName: user.fullName,
      capabilities: caps,
      eligibleCapabilities: eligibleCapabilitiesFor(caps),
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
    _user = _currentUser();
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;

  setUpAll(() => state.init());

  setUp(() async {
    await state.logout();
  });

  tearDown(() async {
    await state.logout();
    state.configureAuth(MockAuthRepository());
  });

  test('a hosted session never borrows a seeded account by phone', () async {
    state.configureAuth(_HostedFakeAuth(phone: '+639175124809'));

    final failure = await state.signInWithGoogle();
    expect(failure, isNull);
    expect(state.isSignedIn, isTrue);
    expect(state.usesHostedIdentity, isTrue);

    // The number matches the primary seed persona, but the auth user id does
    // not, so the session must get its own account.
    expect(state.currentAccount?.id, isNot('ACC001'));
    expect(state.db.hasIsolatedSession, isTrue);
  });

  test('hosted sessions see no shared seed history or requests', () async {
    state.configureAuth(_HostedFakeAuth(phone: '+639170009911'));
    await state.signInWithGoogle();

    expect(state.rideHistory, isEmpty);
    expect(state.pasuyoTasks, isEmpty);
    expect(state.paymentMethods, isEmpty);
    expect(state.savedPlaces, isEmpty);
    expect(state.db.ownerVehicles, isEmpty);
    expect(state.ownerBookingRequests, isEmpty);
    expect(state.db.vehicleDocuments, isEmpty);

    await state.logout();
    expect(state.db.hasIsolatedSession, isFalse);
    expect(state.rideHistory, isNotEmpty);
    expect(state.pasuyoTasks, isNotEmpty);
  });

  test('a Google account without a phone waits for onboarding', () async {
    state.configureAuth(_HostedFakeAuth(
      phone: null,
      email: 'new-google@example.com',
      needsOnboarding: true,
    ));
    await state.signInWithGoogle();

    expect(state.requiresOnboarding, isTrue);

    final failure = await state.completeOnboarding(
      fullName: 'New Google',
      phone: '+639170009912',
    );
    expect(failure, isNull);
    expect(state.requiresOnboarding, isFalse);
  });

  test('switching demo accounts replaces the account and its view', () async {
    state.configureAuth(_HostedFakeAuth(
      id: 'demo-a',
      fullName: 'Demo A',
      phone: '+639170000001',
      email: 'demo.a@surgo-demo.test',
    ));
    final first = await state.signInWithDemoPin(
      phone: '+639170000001',
      pin: '246810',
    );
    expect(first, isNull);
    expect(state.currentAccount?.authUserId, 'demo-a');
    expect(state.db.hasIsolatedSession, isTrue);
    expect(state.rideHistory, isEmpty);
    final accountAId = state.currentAccount!.id;

    await state.logout();
    expect(state.currentAccount, isNull);
    expect(state.db.hasIsolatedSession, isFalse);

    state.configureAuth(_HostedFakeAuth(
      id: 'demo-b',
      fullName: 'Demo B',
      phone: '+639170000002',
      email: 'demo.b@surgo-demo.test',
      capabilities: const {
        CapabilityType.passenger,
        CapabilityType.earner,
      },
    ));
    final second = await state.signInWithDemoPin(
      phone: '+639170000002',
      pin: '246810',
    );
    expect(second, isNull);

    // A different auth user must be a different app account, with none of the
    // seed rows and only the roles the provider returned.
    expect(state.currentAccount?.authUserId, 'demo-b');
    expect(state.currentAccount?.id, isNot(accountAId));
    expect(state.currentAccount?.name, 'Demo B');
    expect(state.rideHistory, isEmpty);
    expect(state.pasuyoTasks, isEmpty);
    expect(state.db.hasIsolatedSession, isTrue);
    expect(state.availableModes, contains(UserMode.earner));
    expect(state.availableModes, isNot(contains(UserMode.vehicleOwner)));
  });

  test('signing in again after logout restores the same demo account',
      () async {
    final account = _HostedFakeAuth(
      id: 'demo-a',
      fullName: 'Demo A',
      phone: '+639170000001',
      email: 'demo.a@surgo-demo.test',
    );
    state.configureAuth(account);
    await state.signInWithDemoPin(
      phone: '+639170000001',
      pin: '246810',
    );
    expect(state.currentAccount?.authUserId, 'demo-a');

    await state.logout();
    expect(state.currentAccount, isNull);
    expect(state.rideHistory, isNotEmpty);

    state.configureAuth(account);
    await state.signInWithDemoPin(
      phone: '+639170000001',
      pin: '246810',
    );
    expect(state.currentAccount?.authUserId, 'demo-a');
    expect(state.db.hasIsolatedSession, isTrue);
    expect(state.rideHistory, isEmpty);
  });
}
