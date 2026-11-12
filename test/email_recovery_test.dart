import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sdk;
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/auth_repository.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/auth/supabase_auth_repository.dart';
import 'package:surgo/screens/forgot_password_screen.dart';
import 'package:surgo/screens/reset_password_screen.dart';
import 'package:surgo/theme/app_theme.dart';
import 'package:surgo/widgets/auth_widgets.dart';
import 'package:surgo/widgets/common.dart';

const _notice =
    'If an account exists for that email address, '
    'check your email for a password reset link.';
const _sdkUser = sdk.User(
  id: 'offline-recovery-user',
  appMetadata: {},
  userMetadata: {},
  aud: 'authenticated',
  createdAt: '2026-01-01T00:00:00Z',
);

/// No provider, session persistence, email delivery or network is involved.
class _Recovery implements EmailRecoveryRepository {
  final requests = <String>[];
  final updates = <String>[];
  Completer<void> request = Completer<void>();
  Completer<void> update = Completer<void>();

  @override
  Stream<bool> get passwordRecoveryEvents => const Stream.empty();

  @override
  Future<void> requestPasswordReset(String email) {
    requests.add(email);
    return request.future;
  }

  @override
  Future<void> updatePassword(String password) {
    updates.add(password);
    return update.future;
  }
}

/// SDK-shaped doubles: any unintended operation (including token storage or
/// reading currentSession instead of getSession) fails without making a request.
class _SdkAuth implements sdk.GoTrueClient {
  final events = StreamController<sdk.AuthState>.broadcast(sync: true);
  final requests = <({String email, String? redirect})>[];
  final updates = <sdk.UserAttributes>[];
  Completer<void> request = Completer<void>();
  Completer<sdk.UserResponse> update = Completer<sdk.UserResponse>();
  sdk.Session? session;
  Future<sdk.Session?>? sessionResult;
  int sessionChecks = 0;

  @override
  Stream<sdk.AuthState> get onAuthStateChange => events.stream;

  @override
  Future<void> resetPasswordForEmail(
    String email, {
    String? redirectTo,
    String? captchaToken,
  }) {
    requests.add((email: email, redirect: redirectTo));
    return request.future;
  }

  @override
  Future<sdk.Session?> getSession() async {
    sessionChecks++;
    final result = sessionResult;
    if (result != null) return result;
    return session;
  }

  @override
  Future<sdk.UserResponse> updateUser(
    sdk.UserAttributes attributes, {
    String? emailRedirectTo,
  }) {
    updates.add(attributes);
    return update.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected SDK operation: ${invocation.memberName}',
  );
}

class _SdkClient implements sdk.SupabaseClient {
  _SdkClient(this.auth);

  @override
  final sdk.GoTrueClient auth;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected client operation: ${invocation.memberName}',
  );
}

sdk.Session _session({bool expired = false}) =>
    sdk.Session(
        accessToken: 'offline-placeholder-not-a-token',
        tokenType: 'bearer',
        user: _sdkUser,
      )
      ..expiresAt =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          (expired ? -60 : 3600);

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.binding.setSurfaceSize(const Size(430, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: screen,
      routes: {
        '/login': (_) => const Scaffold(body: Text('LOGIN')),
        '/otp': (_) => const Scaffold(body: Text('OTP')),
        '/home': (_) => const Scaffold(body: Text('DASHBOARD')),
      },
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pump();
}

Future<void> _emailMode(WidgetTester tester, _Recovery recovery) async {
  await _pump(tester, ForgotPasswordScreen(recoveryResolver: () => recovery));
  await _tap(tester, 'Use email instead');
  await tester.pumpAndSettle();
}

Future<void> _passwords(
  WidgetTester tester,
  String password, [
  String? confirmation,
]) async {
  await tester.enterText(find.byType(TextField).at(0), password);
  await tester.enterText(
    find.byType(TextField).at(1),
    confirmation ?? password,
  );
}

void main() {
  group('hosted email recovery adapter (fake SDK only)', () {
    late _SdkAuth provider;
    late SupabaseAuthRepository repository;

    setUp(() {
      provider = _SdkAuth();
      repository = SupabaseAuthRepository(client: _SdkClient(provider));
    });
    tearDown(() => provider.events.close());

    test('does not add recovery to existing demo or disabled auth', () {
      expect(MockAuthRepository(), isNot(isA<EmailRecoveryRepository>()));
      expect(
        const DisabledAuthRepository(),
        isNot(isA<EmailRecoveryRepository>()),
      );
      expect(repository, isA<EmailRecoveryRepository>());
    });

    test(
      'only recovery and sign-out emit; refresh/update do not clear recovery',
      () async {
        final events = <bool>[];
        final subscription = repository.passwordRecoveryEvents.listen(
          events.add,
        );
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.initialSession, null),
        );
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.passwordRecovery, null),
        );
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.signedIn, null),
        );
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.tokenRefreshed, null),
        );
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.userUpdated, null),
        );
        expect(events, [true]);
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.signedOut, null),
        );
        expect(events, [true, false]);
        await subscription.cancel();
      },
    );

    test(
      'SDK stream errors are available to the integration error handler',
      () async {
        final errors = <Object>[];
        final events = <bool>[];
        final subscription = repository.passwordRecoveryEvents.listen(
          events.add,
          onError: errors.add,
        );
        provider.events.add(
          const sdk.AuthState(sdk.AuthChangeEvent.passwordRecovery, null),
        );
        final error = StateError('offline');
        provider.events.addError(error);
        expect(events, [true]);
        expect(errors, [error]);
        await subscription.cancel();
      },
    );

    test(
      'requests through the existing redirect and awaits provider completion',
      () async {
        var finished = false;
        final pending = repository.requestPasswordReset('user@surgo.test')
          ..then((_) => finished = true);
        expect(provider.requests, [
          (
            email: 'user@surgo.test',
            redirect: SupabaseAuthRepository.defaultRedirectTo,
          ),
        ]);
        expect(finished, isFalse);
        expect(provider.sessionChecks, 0);
        expect(provider.updates, isEmpty);
        provider.request.complete();
        await pending;
        expect(finished, isTrue);
      },
    );

    test('request provider errors become sanitized AuthFailure', () async {
      final expectation = expectLater(
        repository.requestPasswordReset('user@surgo.test'),
        throwsA(
          isA<AuthFailure>()
              .having(
                (failure) => failure.code,
                'code',
                AuthFailureCode.unknown,
              )
              .having(
                (failure) => failure.message,
                'safe message',
                isNot(contains('SENSITIVE_SENTINEL')),
              ),
        ),
      );
      provider.request.completeError(
        const sdk.AuthException('SENSITIVE_SENTINEL'),
      );
      await expectation;
    });

    for (final expired in [false, true]) {
      test(
        'rejects ${expired ? 'expired' : 'missing'} current session',
        () async {
          provider.session = expired ? _session(expired: true) : null;
          await expectLater(
            repository.updatePassword('new-pass'),
            throwsA(
              isA<AuthFailure>().having(
                (failure) => failure.code,
                'code',
                AuthFailureCode.invalidCredentials,
              ),
            ),
          );
          expect(provider.sessionChecks, 1);
          expect(provider.updates, isEmpty);
        },
      );
    }

    test(
      'validates SDK session before updating exact password attributes',
      () async {
        final sessionReady = Completer<sdk.Session?>();
        provider.sessionResult = sessionReady.future;
        final pending = repository.updatePassword(' new-pass ');
        expect(provider.sessionChecks, 1);
        expect(provider.updates, isEmpty);
        sessionReady.complete(_session());
        await Future<void>.delayed(Duration.zero);
        expect(provider.updates, hasLength(1));
        expect(provider.updates.single.password, ' new-pass ');
        expect(provider.updates.single.email, isNull);
        expect(provider.updates.single.data, isNull);
        provider.update.complete(sdk.UserResponse.fromJson(_sdkUser.toJson()));
        await pending;
      },
    );

    test('session refresh failure never updates a password', () async {
      provider.sessionResult = Future.error(
        const sdk.AuthException('Invalid refresh token SENSITIVE_SENTINEL'),
      );
      await expectLater(
        repository.updatePassword('new-pass'),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.message,
            'safe message',
            isNot(contains('SENSITIVE_SENTINEL')),
          ),
        ),
      );
      expect(provider.updates, isEmpty);
    });

    test('update provider errors become AuthFailure', () async {
      provider.session = _session();
      final expectation = expectLater(
        repository.updatePassword('new-pass'),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.weakPassword,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      provider.update.completeError(
        const sdk.AuthException('Password is too short'),
      );
      await expectation;
    });

    for (final operation in ['request', 'update', 'session']) {
      test('$operation timeout is a network AuthFailure', () {
        fakeAsync((clock) {
          provider.session = _session();
          if (operation == 'session') {
            provider.sessionResult = Completer<sdk.Session?>().future;
          }
          Object? failure;
          final pending = operation == 'request'
              ? repository.requestPasswordReset('user@surgo.test')
              : repository.updatePassword('new-pass');
          pending.catchError((Object error) {
            failure = error;
          });
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 21));
          clock.flushMicrotasks();
          expect(
            failure,
            isA<AuthFailure>().having(
              (failure) => failure.code,
              'code',
              AuthFailureCode.network,
            ),
          );
          if (operation == 'session') expect(provider.updates, isEmpty);
        });
      });
    }
  });

  group('forgot-password email mode', () {
    for (final resolver in <EmailRecoveryRepository? Function()?>[
      null,
      () => null,
      () => throw StateError('unavailable'),
    ]) {
      testWidgets('no capability keeps phone-only recovery', (tester) async {
        await _pump(tester, ForgotPasswordScreen(recoveryResolver: resolver));
        expect(find.text('Phone number'), findsOneWidget);
        expect(find.text('Send code'), findsOneWidget);
        expect(find.text('Use email instead'), findsNothing);
        expect(find.text('Email address'), findsNothing);
      });
    }

    testWidgets(
      'capability keeps phone default and adds reversible email mode',
      (tester) async {
        final recovery = _Recovery();
        await _pump(
          tester,
          ForgotPasswordScreen(recoveryResolver: () => recovery),
        );
        expect(find.text('Phone number'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '09172204411');
        await _tap(tester, 'Use email instead');
        await tester.pumpAndSettle();
        expect(find.text('Email address'), findsOneWidget);
        expect(find.text('Phone number'), findsNothing);
        await _tap(tester, 'Use phone instead');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '09172204411',
        );
        expect(recovery.requests, isEmpty);
        expect(recovery.updates, isEmpty);
      },
    );

    testWidgets('validates empty and malformed email before requesting', (
      tester,
    ) async {
      final recovery = _Recovery();
      await _emailMode(tester, recovery);
      await _tap(tester, 'Send reset link');
      expect(find.text('Enter your email address.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'not-an-email');
      await _tap(tester, 'Send reset link');
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(recovery.requests, isEmpty);
    });

    testWidgets(
      'latches sends and shows generic notice without auth/navigation',
      (tester) async {
        final recovery = _Recovery();
        await _emailMode(tester, recovery);
        await tester.enterText(find.byType(TextField), ' user@surgo.test ');
        await _tap(tester, 'Send reset link');
        // Exercise a queued keyboard submission as well as the disabled button.
        tester.widget<SbAuthField>(find.byType(SbAuthField)).onSubmitted!('');
        await _tap(tester, 'Requesting link…');
        await _tap(tester, 'Use phone instead');
        expect(recovery.requests, ['user@surgo.test']);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(find.text('Email address'), findsOneWidget);
        expect(find.text(_notice), findsNothing);
        recovery.request.complete();
        await tester.pumpAndSettle();
        expect(find.text(_notice), findsOneWidget);
        expect(find.text('OTP'), findsNothing);
        expect(find.text('DASHBOARD'), findsNothing);
        expect(recovery.updates, isEmpty);
        await tester.enterText(find.byType(TextField), 'another@surgo.test');
        await tester.pump();
        expect(find.text(_notice), findsNothing);
      },
    );

    for (final code in [
      AuthFailureCode.noAccount,
      AuthFailureCode.accountUnavailable,
      AuthFailureCode.emailInUse,
      AuthFailureCode.emailNotConfirmed,
      AuthFailureCode.invalidCredentials,
    ]) {
      testWidgets('$code uses the same anti-enumeration notice', (
        tester,
      ) async {
        final recovery = _Recovery();
        await _emailMode(tester, recovery);
        await tester.enterText(find.byType(TextField), 'user@surgo.test');
        await _tap(tester, 'Send reset link');
        recovery.request.completeError(AuthFailure(code, 'ACCOUNT_SENTINEL'));
        await tester.pumpAndSettle();
        expect(find.text(_notice), findsOneWidget);
        expect(find.textContaining('ACCOUNT_SENTINEL'), findsNothing);
      });
    }

    testWidgets(
      'sanitizes unexpected failures, releases latch and permits retry',
      (tester) async {
        final recovery = _Recovery();
        await _emailMode(tester, recovery);
        await tester.enterText(find.byType(TextField), 'user@surgo.test');
        await _tap(tester, 'Send reset link');
        recovery.request.completeError(StateError('SENSITIVE_SENTINEL'));
        await tester.pumpAndSettle();
        expect(find.textContaining('SENSITIVE_SENTINEL'), findsNothing);
        expect(
          find.text(
            'Password recovery could not be requested. Please try again.',
          ),
          findsOneWidget,
        );
        expect(find.text(_notice), findsNothing);
        recovery.request = Completer<void>();
        await _tap(tester, 'Send reset link');
        recovery.request.complete();
        await tester.pumpAndSettle();
        expect(recovery.requests, hasLength(2));
        expect(find.text(_notice), findsOneWidget);
      },
    );

    testWidgets('losing capability cannot pretend a link was requested', (
      tester,
    ) async {
      final recovery = _Recovery();
      EmailRecoveryRepository? available = recovery;
      await _pump(
        tester,
        ForgotPasswordScreen(recoveryResolver: () => available),
      );
      await _tap(tester, 'Use email instead');
      await tester.pumpAndSettle();
      available = null;
      await tester.enterText(find.byType(TextField), 'user@surgo.test');
      await _tap(tester, 'Send reset link');
      await tester.pumpAndSettle();
      expect(recovery.requests, isEmpty);
      expect(find.text(_notice), findsNothing);
      expect(
        find.text(
          'Email recovery is unavailable right now. Please try again later.',
        ),
        findsOneWidget,
      );
    });

    for (final fail in [false, true]) {
      testWidgets(
        'disposed request ignores late ${fail ? 'error' : 'success'}',
        (tester) async {
          final recovery = _Recovery();
          await _emailMode(tester, recovery);
          await tester.enterText(find.byType(TextField), 'user@surgo.test');
          await _tap(tester, 'Send reset link');
          await tester.pumpWidget(const MaterialApp(home: Text('DISPOSED')));
          if (fail) {
            recovery.request.completeError(StateError('late failure'));
          } else {
            recovery.request.complete();
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('DISPOSED'), findsOneWidget);
        },
      );
    }
  });

  group('reset-password screen', () {
    testWidgets(
      'validates nonempty, eight characters and matching confirmation',
      (tester) async {
        final recovery = _Recovery();
        var completed = 0;
        await _pump(
          tester,
          ResetPasswordScreen(
            recoveryResolver: () => recovery,
            onCompleted: () async => completed++,
          ),
        );
        await _tap(tester, 'Update password');
        expect(find.text('Enter your password.'), findsOneWidget);
        await _passwords(tester, '1234567');
        await _tap(tester, 'Update password');
        expect(
          find.text('Use a password with at least 8 characters.'),
          findsOneWidget,
        );
        await _passwords(tester, '12345678', 'different');
        await _tap(tester, 'Update password');
        expect(find.text('The passwords do not match.'), findsOneWidget);
        expect(recovery.updates, isEmpty);
        expect(completed, 0);
      },
    );

    testWidgets(
      'awaits update and completion, preserves exact password, latches',
      (tester) async {
        final recovery = _Recovery();
        final completion = Completer<void>();
        var completed = 0;
        await _pump(
          tester,
          ResetPasswordScreen(
            recoveryResolver: () => recovery,
            onCompleted: () {
              completed++;
              return completion.future;
            },
          ),
        );
        await _passwords(tester, ' pass12 ');
        expect(
          tester.widget<TextField>(find.byType(TextField).first).obscureText,
          isTrue,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField).last).obscureText,
          isTrue,
        );
        await _tap(tester, 'Update password');
        tester.widget<SbAuthField>(find.byType(SbAuthField).last).onSubmitted!(
          '',
        );
        await _tap(tester, 'Updating password…');
        expect(recovery.updates, [' pass12 ']);
        expect(completed, 0);
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          expect(field.enabled, isFalse);
        }
        recovery.update.complete();
        await tester.pumpAndSettle();
        expect(completed, 1);
        expect(
          tester
              .widget<SbPrimaryButton>(find.byType(SbPrimaryButton))
              .onPressed,
          isNull,
        );
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          expect(field.controller!.text, isEmpty);
        }
        completion.complete();
        await tester.pumpAndSettle();
        expect(find.text('Your password has been updated.'), findsOneWidget);
        expect(find.text('DASHBOARD'), findsNothing);
        tester.widget<SbAuthField>(find.byType(SbAuthField).last).onSubmitted!(
          '',
        );
        expect(completed, 1);
        expect(recovery.updates, hasLength(1));
        expect(recovery.requests, isEmpty);
      },
    );

    testWidgets('missing capability reports unavailable without completing', (
      tester,
    ) async {
      var completed = 0;
      await _pump(
        tester,
        ResetPasswordScreen(
          recoveryResolver: () => null,
          onCompleted: () async => completed++,
        ),
      );
      await _passwords(tester, 'new-pass');
      await _tap(tester, 'Update password');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Email recovery is unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Your password has been updated.'), findsNothing);
      expect(completed, 0);
    });

    testWidgets('failed update is safe, does not complete, and can retry', (
      tester,
    ) async {
      final recovery = _Recovery();
      var completed = 0;
      await _pump(
        tester,
        ResetPasswordScreen(
          recoveryResolver: () => recovery,
          onCompleted: () async => completed++,
        ),
      );
      await _passwords(tester, 'new-pass');
      await _tap(tester, 'Update password');
      recovery.update.completeError(
        const sdk.AuthException('SENSITIVE_SENTINEL'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('SENSITIVE_SENTINEL'), findsNothing);
      expect(
        find.text('Your password could not be updated. Please try again.'),
        findsOneWidget,
      );
      expect(completed, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled,
        isTrue,
      );
      recovery.update = Completer<void>();
      await _tap(tester, 'Update password');
      recovery.update.complete();
      await tester.pumpAndSettle();
      expect(recovery.updates, ['new-pass', 'new-pass']);
      expect(completed, 1);
    });

    testWidgets('expired-session error stays on recovery without completion', (
      tester,
    ) async {
      final recovery = _Recovery();
      var completed = 0;
      await _pump(
        tester,
        ResetPasswordScreen(
          recoveryResolver: () => recovery,
          onCompleted: () async => completed++,
        ),
      );
      await _passwords(tester, 'new-pass');
      await _tap(tester, 'Update password');
      recovery.update.completeError(
        const AuthFailure(
          AuthFailureCode.invalidCredentials,
          'Your recovery session has expired. Open a new password reset link.',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Your recovery session has expired. Open a new password reset link.',
        ),
        findsOneWidget,
      );
      expect(completed, 0);
      expect(find.text('DASHBOARD'), findsNothing);
    });

    testWidgets('completion failure retries callback without another update', (
      tester,
    ) async {
      final recovery = _Recovery();
      var completed = 0;
      await _pump(
        tester,
        ResetPasswordScreen(
          recoveryResolver: () => recovery,
          onCompleted: () async {
            if (++completed == 1) throw StateError('SENSITIVE_SENTINEL');
          },
        ),
      );
      await _passwords(tester, 'new-pass');
      await _tap(tester, 'Update password');
      recovery.update.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('SENSITIVE_SENTINEL'), findsNothing);
      expect(
        find.text(
          'Your password was updated, but recovery could not finish. Try again.',
        ),
        findsOneWidget,
      );
      await _tap(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(completed, 2);
      expect(recovery.updates, ['new-pass']);
      expect(find.text('Your password has been updated.'), findsOneWidget);
    });

    for (final fail in [false, true]) {
      testWidgets(
        'disposed update ignores late ${fail ? 'error' : 'success'}',
        (tester) async {
          final recovery = _Recovery();
          var completed = 0;
          await _pump(
            tester,
            ResetPasswordScreen(
              recoveryResolver: () => recovery,
              onCompleted: () async => completed++,
            ),
          );
          await _passwords(tester, 'new-pass');
          await _tap(tester, 'Update password');
          await tester.pumpWidget(const MaterialApp(home: Text('DISPOSED')));
          if (fail) {
            recovery.update.completeError(StateError('late failure'));
          } else {
            recovery.update.complete();
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('DISPOSED'), findsOneWidget);
          expect(completed, 0);
        },
      );
    }
  });
}
