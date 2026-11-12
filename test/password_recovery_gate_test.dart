import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/demo_auth.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/main.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/booking_screen.dart';
import 'package:surgo/screens/login_screen.dart';
import 'package:surgo/screens/onboarding_screen.dart';
import 'package:surgo/screens/passenger_shell.dart';
import 'package:surgo/screens/pin_lock_screen.dart';
import 'package:surgo/screens/reset_password_screen.dart';
import 'package:surgo/state/app_state.dart';

const _userA = AuthUser(
  id: 'recovery-user-a',
  phone: '+639170009911',
  email: 'recovery-a@surgo.test',
  fullName: 'Recovery Tester',
  providers: {'email'},
  metadata: {'surgo_onboarded': true},
);
const _userB = AuthUser(
  id: 'recovery-user-b',
  phone: '+639170009922',
  email: 'recovery-b@surgo.test',
  fullName: 'Other Tester',
  providers: {'email'},
  metadata: {'surgo_onboarded': true},
);

/// Hosted AppState semantics, but no SDK, persistence, email or network.
class _HostedRecovery extends MockAuthRepository
    implements EmailRecoveryRepository {
  _HostedRecovery({this.needsOnboarding = false});

  AuthUser user = _userA;
  AuthUser? session;
  bool needsOnboarding;
  Future<AuthUser?>? restoredSession;
  Completer<SurgoIdentity>? identityRead;
  Completer<void>? identityReadStarted;
  Completer<void>? passwordUpdate;
  final updates = <String>[];
  final subscriptions = <String>[];
  int restoreCalls = 0;

  late final authEvents = StreamController<AuthUser?>.broadcast(
    sync: true,
    onListen: () => subscriptions.add('auth'),
  );
  late final recoveryEvents = StreamController<bool>.broadcast(
    sync: true,
    onListen: () => subscriptions.add('recovery'),
  );

  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => authEvents.stream;

  @override
  Stream<bool> get passwordRecoveryEvents => recoveryEvents.stream;

  @override
  Future<AuthUser?> restoreSession() {
    restoreCalls++;
    return restoredSession ?? Future<AuthUser?>.value(session);
  }

  @override
  Future<AuthUser> signInWithEmail({
    required String email,
    required String password,
  }) async => session = user;

  SurgoIdentity identityFor(AuthUser user) => SurgoIdentity(
    userId: user.id,
    phone: user.phone,
    email: user.email,
    fullName: user.fullName,
    capabilities: const {CapabilityType.passenger},
    eligibleCapabilities: eligibleCapabilitiesFor(const {
      CapabilityType.passenger,
    }),
    roles: const {'passenger'},
    providers: user.providers,
    profileExists: true,
    needsOnboarding: needsOnboarding,
  );

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    final pending = identityRead;
    if (pending == null) return identityFor(user);
    identityReadStarted!.complete();
    return pending.future;
  }

  // initialSession, signedIn, tokenRefreshed and userUpdated all expose this
  // same AuthUser payload through AuthRepository; none emits recovery=false.
  void emitSession([AuthUser? next]) {
    session = next ?? user;
    authEvents.add(session);
  }

  void emitSignedOut() {
    session = null;
    recoveryEvents.add(false);
    authEvents.add(null);
  }

  @override
  Future<void> signOut() async => emitSignedOut();

  @override
  Future<void> requestPasswordReset(String email) async =>
      throw UnsupportedError('The recovery gate must not send reset emails.');

  @override
  Future<void> updatePassword(String password) async {
    updates.add(password);
    await passwordUpdate?.future;
  }

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {
    needsOnboarding = false;
    user = user.copyWith(fullName: fullName, phone: phone);
    session = user;
  }

  Future<void> close() async {
    final pending = identityRead;
    if (pending != null && !pending.isCompleted) {
      pending.complete(identityFor(user));
    }
    final update = passwordUpdate;
    if (update != null && !update.isCompleted) update.complete();
    await authEvents.close();
    await recoveryEvents.close();
  }
}

final _invalidSession = throwsA(
  isA<AuthFailure>().having(
    (failure) => failure.code,
    'code',
    AuthFailureCode.invalidCredentials,
  ),
);

Future<void> _signIn(AppState state, _HostedRecovery auth) async {
  expect(
    await state.signInWithEmail(
      email: auth.user.email!,
      password: 'offline-test-password',
    ),
    isNull,
  );
  expect(state.ready, isTrue);
  expect(state.isSignedIn, isTrue);
  expect(state.usesHostedIdentity, isTrue);
}

Future<void> _unlock(AppState state) async {
  expect(await state.setPin('246810'), isTrue);
  expect(await state.unlockWithPin('246810'), PinUnlockResult.success);
  expect(state.requiresPin, isFalse);
}

// Bounded frames finish route transitions without waiting for live/pulse
// animations or advancing hosted polling by a long pumpAndSettle timeout.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _app(WidgetTester tester) async {
  // Leave room for the hosted login actions with Flutter's wide test font;
  // these are recovery-gate tests, not responsive-layout tests.
  await tester.binding.setSurfaceSize(const Size(600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const SurGoApp());
  // init() was awaited in setUpAll's real zone. Let the splash's Future.wait
  // observe that already-completed future as well as its fake-clock delay.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 1700));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await _frames(tester);
}

Future<void> _submitPassword(WidgetTester tester) async {
  final fields = find.descendant(
    of: find.byType(ResetPasswordScreen),
    matching: find.byType(TextField),
  );
  // Seed transient controllers to isolate completion/routing from text-input
  // infrastructure, which has its own app-overlay regression below.
  for (final field in tester.widgetList<TextField>(fields)) {
    field.controller!.text = 'new-offline-password';
  }
  await tester.pump();
  await tester.ensureVisible(find.text('Update password'));
  await tester.tap(find.text('Update password'));
  await _frames(tester);
}

void _blocked(Type underlying) {
  expect(find.byType(ResetPasswordScreen), findsOneWidget);
  expect(find.text('Reset your password'), findsOneWidget);
  expect(find.byType(underlying), findsNothing);
  expect(find.byType(underlying, skipOffstage: false), findsOneWidget);
  expect(
    find.byType(underlying, skipOffstage: false).hitTestable(),
    findsNothing,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;
  final providers = <_HostedRecovery>[];

  _HostedRecovery install({bool needsOnboarding = false}) {
    final auth = _HostedRecovery(needsOnboarding: needsOnboarding);
    providers.add(auth);
    state.configureAuth(auth);
    return auth;
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    await state.init();
    expect(state.ready, isTrue);
  });

  setUp(() async {
    await state.logout();
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    // Stop session-owned polling before returning the singleton to seed mode.
    await state.logout();
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    for (final provider in providers) {
      await provider.close();
    }
    providers.clear();
  });

  test('recovery is optional and subscribes before auth callbacks', () {
    expect(state.emailRecovery, isNull);
    final epoch = state.recoveryEpoch;
    final auth = install();
    expect(state.emailRecovery, same(auth));
    expect(auth.subscriptions, ['recovery', 'auth']);
    expect(state.passwordRecoveryRequired, isFalse);
    expect(state.recoveryEpoch, greaterThan(epoch));

    final configuredEpoch = state.recoveryEpoch;
    auth.recoveryEvents.add(true);
    expect(state.passwordRecoveryRequired, isTrue);
    expect(state.recoveryEpoch, configuredEpoch + 1);
    auth.recoveryEvents.add(true);
    expect(state.recoveryEpoch, configuredEpoch + 2);
  });

  testWidgets('reset blocks login before a delayed recovered identity lands', (
    tester,
  ) async {
    final auth = install();
    await _app(tester);
    expect(find.byType(LoginScreen), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final login = tester.state(find.byType(LoginScreen));

    auth.identityRead = Completer<SurgoIdentity>();
    auth.identityReadStarted = Completer<void>();
    auth.recoveryEvents.add(true);
    auth.emitSession();
    await tester.pump();
    expect(auth.identityReadStarted!.isCompleted, isTrue);
    _blocked(LoginScreen);
    expect(state.isSignedIn, isFalse);
    expect(
      tester.state(find.byType(LoginScreen, skipOffstage: false)),
      same(login),
    );
    final epoch = state.recoveryEpoch;
    final resetState = tester.state(find.byType(ResetPasswordScreen));
    expect(
      tester.state<NavigatorState>(
        find.byType(Navigator, skipOffstage: false).first,
      ),
      same(navigator),
    );

    auth.identityRead!.complete(auth.identityFor(_userA));
    auth.identityRead = null;
    await _frames(tester);
    expect(state.identity?.userId, _userA.id);
    expect(state.passwordRecoveryRequired, isTrue);
    expect(state.recoveryEpoch, greaterThan(epoch));
    expect(
      tester.state(find.byType(ResetPasswordScreen)),
      isNot(same(resetState)),
    );
    // Login's existing auth listener routes to PIN behind the recovery gate;
    // that route must remain inaccessible until recovery completes.
    _blocked(PinLockScreen);
    expect(state.requiresPin, isTrue);
    expect(
      tester.state<NavigatorState>(
        find.byType(Navigator, skipOffstage: false).first,
      ),
      same(navigator),
    );
    expect(find.byType(PassengerShell), findsNothing);
  });

  testWidgets(
    'reset retains and blocks the unlocked dashboard across auth events',
    (tester) async {
      final auth = install();
      await _signIn(state, auth);
      await _unlock(state);
      await _app(tester);
      expect(find.byType(PassengerShell), findsOneWidget);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final dashboard = tester.widget<PassengerShell>(
        find.byType(PassengerShell),
      );

      auth.recoveryEvents.add(true);
      await _frames(tester);
      _blocked(PassengerShell);
      final epoch = state.recoveryEpoch;
      for (final event in [
        'initialSession',
        'signedIn',
        'tokenRefreshed',
        'userUpdated',
      ]) {
        auth.emitSession();
        await _frames(tester);
        expect(state.passwordRecoveryRequired, isTrue, reason: event);
        expect(state.recoveryEpoch, epoch, reason: event);
        _blocked(PassengerShell);
      }
      expect(
        state.requiresPin,
        isFalse,
      ); // The recovery latch does the blocking.
      expect(
        tester.state<NavigatorState>(
          find.byType(Navigator, skipOffstage: false).first,
        ),
        same(navigator),
      );
      expect(
        tester.widget<PassengerShell>(
          find.byType(PassengerShell, skipOffstage: false),
        ),
        same(dashboard),
      );
      expect(find.text('Where to today?').hitTestable(), findsNothing);
      expect(find.byType(BookingScreen), findsNothing);
    },
  );

  testWidgets('recovery password fields can be edited in the app overlay', (
    tester,
  ) async {
    final auth = install();
    await _app(tester);
    auth.recoveryEvents.add(true);
    await _frames(tester);
    _blocked(LoginScreen);
    final fields = find.descendant(
      of: find.byType(ResetPasswordScreen),
      matching: find.byType(TextField),
    );
    // A normal keyboard edit creates a selection overlay. Fail here with the
    // integration cause rather than cascading EditableText focus assertions.
    expect(
      Overlay.maybeOf(tester.element(fields.first)),
      isNotNull,
      reason:
          'The reset fields need an Overlay ancestor outside the offstage navigator.',
    );
    await tester.enterText(fields.first, 'new-offline-password');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'successful update re-locks an existing PIN instead of unlocking home',
    (tester) async {
      final auth = install();
      await _signIn(state, auth);
      await _unlock(state);
      await _app(tester);
      auth.passwordUpdate = Completer<void>();
      auth.recoveryEvents.add(true);
      await _frames(tester);
      await _submitPassword(tester);
      expect(auth.updates, ['new-offline-password']);
      _blocked(PassengerShell);

      final restoreCalls = auth.restoreCalls;
      auth.passwordUpdate!.complete();
      await _frames(tester);
      expect(auth.restoreCalls, greaterThan(restoreCalls));
      expect(state.passwordRecoveryRequired, isFalse);
      expect(state.requiresPin, isTrue);
      expect(await state.pinConfiguredForCurrentAccount(), isTrue);
      expect(find.byType(ResetPasswordScreen), findsNothing);
      expect(find.byType(PinLockScreen), findsOneWidget);
      expect(find.byType(PassengerShell, skipOffstage: false), findsNothing);
      expect(await state.pinStore.verify(_userA.id, '246810'), isTrue);
      expect(await state.unlockWithPin('000000'), PinUnlockResult.incorrect);
      expect(state.requiresPin, isTrue);

      // Only entering the existing device PIN through the real screen opens home.
      for (final digit in '246810'.split('')) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 200));
      await _frames(tester);
      expect(state.requiresPin, isFalse);
      expect(find.byType(PassengerShell), findsOneWidget);
      expect(auth.updates, hasLength(1));
    },
  );

  testWidgets(
    'successful update routes incomplete account through onboarding and PIN',
    (tester) async {
      final auth = install(needsOnboarding: true);
      await _signIn(state, auth);
      await _app(tester);
      expect(find.byType(OnboardingScreen), findsOneWidget);
      auth.recoveryEvents.add(true);
      await _frames(tester);
      _blocked(OnboardingScreen);
      await _submitPassword(tester);

      expect(state.passwordRecoveryRequired, isFalse);
      expect(state.requiresOnboarding, isTrue);
      expect(state.requiresPin, isTrue);
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(PinLockScreen), findsNothing);
      expect(find.byType(PassengerShell, skipOffstage: false), findsNothing);

      await tester.enterText(find.byType(TextField).at(0), 'Recovery Tester');
      await tester.enterText(find.byType(TextField).at(1), '09170009911');
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await _frames(tester);
      expect(state.requiresOnboarding, isFalse);
      expect(state.requiresPin, isTrue);
      expect(find.byType(PinLockScreen), findsOneWidget);
      expect(find.byType(PassengerShell), findsNothing);
    },
  );

  for (final explicitLogout in [false, true]) {
    testWidgets(
      '${explicitLogout ? 'logout' : 'provider sign-out'} removes recovery',
      (tester) async {
        final auth = install();
        await _signIn(state, auth);
        await _unlock(state);
        await _app(tester);
        auth.recoveryEvents.add(true);
        await _frames(tester);
        final epoch = state.recoveryEpoch;
        final oldCompletion = tester
            .widget<ResetPasswordScreen>(find.byType(ResetPasswordScreen))
            .onCompleted;

        if (explicitLogout) {
          await state.logout();
        } else {
          auth.emitSignedOut();
        }
        await _frames(tester);
        expect(state.passwordRecoveryRequired, isFalse);
        expect(state.recoveryEpoch, greaterThan(epoch));
        expect(state.isSignedIn, isFalse);
        expect(state.identity, isNull);
        expect(state.authStatus, AuthStatus.signedOut);
        expect(find.byType(ResetPasswordScreen), findsNothing);
        await expectLater(oldCompletion(), _invalidSession);

        // A stale auth payload cannot revive a provider session that is gone.
        auth.authEvents.add(_userA);
        await _frames(tester);
        expect(state.isSignedIn, isFalse);
        expect(state.passwordRecoveryRequired, isFalse);
        expect(find.byType(ResetPasswordScreen), findsNothing);
      },
    );
  }

  testWidgets(
    'provider replacement removes overlay and ignores old recovery/auth events',
    (tester) async {
      final old = install();
      await _signIn(state, old);
      await _unlock(state);
      await _app(tester);
      old.recoveryEvents.add(true);
      await _frames(tester);
      final epoch = state.recoveryEpoch;
      final oldCompletion = tester
          .widget<ResetPasswordScreen>(find.byType(ResetPasswordScreen))
          .onCompleted;

      final replacement = install();
      replacement.user = _userB;
      await _signIn(state, replacement);
      await _frames(tester);
      expect(state.emailRecovery, same(replacement));
      expect(state.passwordRecoveryRequired, isFalse);
      expect(state.recoveryEpoch, greaterThan(epoch));
      expect(find.byType(ResetPasswordScreen), findsNothing);
      final replacementEpoch = state.recoveryEpoch;
      old.recoveryEvents.add(true);
      old.emitSession();
      await _frames(tester);
      expect(state.identity?.userId, _userB.id);
      expect(state.passwordRecoveryRequired, isFalse);
      expect(state.recoveryEpoch, replacementEpoch);
      await expectLater(oldCompletion(), _invalidSession);

      // The new provider still owns a working gate.
      replacement.recoveryEvents.add(true);
      await _frames(tester);
      expect(find.byType(ResetPasswordScreen), findsOneWidget);
      expect(state.passwordRecoveryRequired, isTrue);
    },
  );

  for (final expired in [true, false]) {
    testWidgets(
      'completion with ${expired ? 'expired session' : 'wrong SDK user'} stays blocked',
      (tester) async {
        final auth = install();
        await _signIn(state, auth);
        await _unlock(state);
        await _app(tester);
        auth.recoveryEvents.add(true);
        await _frames(tester);
        auth.restoredSession = Future<AuthUser?>.value(expired ? null : _userB);
        await _submitPassword(tester);
        expect(auth.updates, ['new-offline-password']);
        expect(state.passwordRecoveryRequired, isTrue);
        expect(state.identity?.userId, _userA.id);
        _blocked(PassengerShell);
        expect(find.byType(PinLockScreen), findsNothing);
        expect(
          find.text(
            'Your password was updated, but recovery could not finish. Try again.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Continue'));
        await _frames(tester);
        expect(state.passwordRecoveryRequired, isTrue);
        expect(auth.updates, hasLength(1));
        _blocked(PassengerShell);
      },
    );
  }

  test(
    'completion rejects wrong capability, epoch and identity before restoring',
    () async {
      final auth = install();
      await _signIn(state, auth);
      auth.recoveryEvents.add(true);
      final epoch = state.recoveryEpoch;
      final other = _HostedRecovery();
      providers.add(other);
      final restoreCalls = auth.restoreCalls;
      for (final arguments
          in <
            ({EmailRecoveryRepository repository, int epoch, String? userId})
          >[
            (repository: other, epoch: epoch, userId: _userA.id),
            (repository: auth, epoch: epoch - 1, userId: _userA.id),
            (repository: auth, epoch: epoch, userId: _userB.id),
            (repository: auth, epoch: epoch, userId: null),
          ]) {
        await expectLater(
          state.completePasswordRecovery(
            repository: arguments.repository,
            epoch: arguments.epoch,
            userId: arguments.userId,
          ),
          _invalidSession,
        );
        expect(state.passwordRecoveryRequired, isTrue);
      }
      expect(auth.restoreCalls, restoreCalls);
    },
  );

  test(
    'identity changes invalidate the recovery epoch without clearing its latch',
    () async {
      final auth = install();
      await _signIn(state, auth);
      auth.recoveryEvents.add(true);
      final epoch = state.recoveryEpoch;
      auth.user = _userB;
      await _signIn(state, auth);
      expect(state.identity?.userId, _userB.id);
      expect(state.recoveryEpoch, greaterThan(epoch));
      expect(state.passwordRecoveryRequired, isTrue);
      await expectLater(
        state.completePasswordRecovery(
          repository: auth,
          epoch: epoch,
          userId: _userA.id,
        ),
        _invalidSession,
      );
      expect(state.passwordRecoveryRequired, isTrue);
    },
  );

  for (final change in ['reset event', 'logout', 'provider replacement']) {
    test(
      'pending completion cannot clear a newer recovery after $change',
      () async {
        final auth = install();
        await _signIn(state, auth);
        auth.recoveryEvents.add(true);
        final restored = Completer<AuthUser?>();
        auth.restoredSession = restored.future;
        final completion = state.completePasswordRecovery(
          repository: auth,
          epoch: state.recoveryEpoch,
          userId: _userA.id,
        );
        final rejected = expectLater(completion, _invalidSession);

        if (change == 'logout') {
          await state.logout();
          auth.restoredSession = null;
          await _signIn(
            state,
            auth,
          ); // Same uuid, but a different session revision.
          auth.recoveryEvents.add(true);
        } else if (change == 'provider replacement') {
          final replacement = install();
          await _signIn(state, replacement);
          replacement.recoveryEvents.add(true);
        } else {
          auth.recoveryEvents.add(true);
        }
        final newEpoch = state.recoveryEpoch;
        restored.complete(_userA);
        await rejected;
        expect(state.passwordRecoveryRequired, isTrue);
        expect(state.recoveryEpoch, newEpoch);
      },
    );
  }

  for (final replaceProvider in [false, true]) {
    test(
      'late identity read after ${replaceProvider ? 'provider replacement' : 'sign-out'} is ignored',
      () async {
        final old = install();
        await _signIn(state, old);
        old.recoveryEvents.add(true);
        final pending = Completer<SurgoIdentity>();
        old.identityRead = pending;
        old.identityReadStarted = Completer<void>();
        old.emitSession(_userB);
        await old.identityReadStarted!.future;

        if (replaceProvider) {
          install();
        } else {
          await state.logout();
        }
        final epoch = state.recoveryEpoch;
        pending.complete(old.identityFor(_userB));
        old.identityRead = null;
        // Drain the unawaited auth callback and its queued identity future.
        await Future<void>.delayed(Duration.zero);
        expect(state.passwordRecoveryRequired, isFalse);
        expect(state.recoveryEpoch, epoch);
        if (replaceProvider) {
          // configureAuth retains the current identity, but the old provider's
          // pending read must not replace it with user B after the switch.
          expect(state.identity?.userId, _userA.id);
          expect(state.currentAccount?.authUserId, _userA.id);
          final replacement = providers.last;
          replacement.user = _userB;
          await _signIn(state, replacement);
          expect(state.identity?.userId, _userB.id);
        } else {
          expect(state.isSignedIn, isFalse);
          expect(state.currentAccount, isNull);
          expect(state.identity, isNull);
          expect(state.authStatus, AuthStatus.signedOut);
          expect(state.requiresPin, isFalse);
        }
      },
    );
  }
}
