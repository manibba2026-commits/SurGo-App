import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/repositories/edge_functions.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/services/device_token_registry.dart';
import 'package:surgo/services/push_service.dart';
import 'package:surgo/services/push_transport.dart';

class _Transport implements PushTransport {
  bool supported = true;
  int permissionRequests = 0;
  int tokenReads = 0;
  int messageReads = 0;
  Future<PushPermission> Function()? permission;
  Future<String?> Function()? lookup;
  final arrivals = StreamController<PushMessage>.broadcast(sync: true);
  final refreshes = StreamController<String>.broadcast(sync: true);

  @override
  bool get isSupported => supported;
  @override
  Future<PushPermission> requestPermission() {
    permissionRequests++;
    return permission?.call() ??
        Future<PushPermission>.value(PushPermission.granted);
  }

  @override
  Future<String?> token() {
    tokenReads++;
    return lookup?.call() ?? Future<String?>.value('token-a');
  }

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;
  @override
  Stream<PushMessage> get messages {
    messageReads++;
    return arrivals.stream;
  }
}

class _Call {
  _Call(Map<String, Object?> body) : body = Map.of(body);
  final Map<String, Object?> body;
  final result = Completer<void>();
}

class _Invoker implements EdgeInvoker {
  bool deferred = false;
  Object? error;
  final List<_Call> calls = [];

  @override
  Future<void> invoke(String name, Map<String, Object?> body) async {
    expect(name, DeviceTokenRegistry.functionName);
    final call = _Call(body);
    calls.add(call);
    if (deferred) await call.result.future;
    if (error != null) throw error!;
  }
}

class _Rig {
  _Rig({bool supported = true}) {
    transport.supported = supported;
    registry = DeviceTokenRegistry(
      transport: transport,
      invoker: () => invoker,
      platform: () => 'android',
    );
    service = PushService(
      transport: transport,
      registry: registry,
      homeRoute: () => '/rider_home',
      navigate: (route) {
        routes.add(route);
        afterNavigate?.call();
      },
      showInForeground: foreground.add,
      canNavigate: () => unlocked,
    );
  }

  final transport = _Transport();
  final invoker = _Invoker();
  late final DeviceTokenRegistry registry;
  late final PushService service;
  bool unlocked = true;
  void Function()? afterNavigate;
  final List<String> routes = [];
  final List<PushMessage> foreground = [];

  void tap([String link = 'trip']) => transport.arrivals.add(
    PushMessage(wasOpened: true, data: {'link': link}),
  );

  Future<void> dispose() async {
    invoker.deferred = false;
    await service.dispose();
    await transport.arrivals.close();
    await transport.refreshes.close();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void _expectSafe(RepositoryFailure? failure) {
  expect(failure, isNotNull);
  expect(failure!.kind, RepositoryFailureKind.unavailable);
  expect(failure.message, RepositoryFailure.unavailable().message);
  expect(failure.cause, isNull);
  expect(failure.toString(), isNot(contains('secret')));
}

void main() {
  test(
    'subscribes on construction and retains a cold tap before sign-in',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      expect(rig.transport.arrivals.hasListener, isTrue);
      expect(rig.transport.permissionRequests, 0);
      rig.tap();
      expect(rig.service.pendingRoute, '/livetrip');
      expect(rig.routes, isEmpty);
      rig.service.flushPending();
      expect(rig.routes, isEmpty);
      await rig.service.onSignedIn();
      expect(rig.routes, ['/livetrip']);
      expect(rig.service.pendingRoute, isNull);
      expect(rig.transport.messageReads, 1);
    },
  );

  test(
    'taps during pending permission and registration are not lost',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final permission = Completer<PushPermission>();
      rig.transport.permission = () => permission.future;
      rig.invoker.deferred = true;
      final start = rig.service.onSignedIn();
      await _settle();
      rig.tap('chat');
      expect(rig.routes, ['/ride_chat']);
      permission.complete(PushPermission.granted);
      await _settle();
      expect(rig.invoker.calls, hasLength(1));
      rig.tap('rental');
      expect(rig.routes, ['/ride_chat', '/active_rental']);
      rig.invoker.calls.single.result.complete();
      await start;
      expect(rig.transport.messageReads, 1);
    },
  );

  test(
    'sign-out retains stream, queues taps and hides foreground messages',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      const arrival = PushMessage(title: 'private');
      rig.transport.arrivals.add(arrival);
      expect(rig.foreground, isEmpty);
      await rig.service.onSignedIn();
      rig.transport.arrivals.add(arrival);
      expect(rig.foreground, [arrival]);
      expect(rig.routes, isEmpty);
      await rig.service.onSignedOut();
      expect(rig.transport.arrivals.hasListener, isTrue);
      expect(rig.transport.refreshes.hasListener, isFalse);
      rig.transport.arrivals.add(arrival);
      rig.tap('verification');
      expect(rig.foreground, [arrival]);
      expect(rig.routes, isEmpty);
      expect(rig.service.pendingRoute, '/profile');
      await rig.service.onSignedIn();
      expect(rig.routes, ['/profile']);
      expect(rig.transport.messageReads, 1);
    },
  );

  for (final gate in ['PIN', 'onboarding', 'recovery']) {
    test('$gate gate holds taps until explicit flush', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.unlocked = false;
      rig.tap('trip');
      await rig.service.onSignedIn();
      rig.tap('chat');
      expect(rig.routes, isEmpty);
      expect(rig.service.pendingRoute, '/livetrip');
      rig.service.flushPending();
      expect(rig.routes, isEmpty);
      rig.unlocked = true;
      expect(
        rig.routes,
        isEmpty,
        reason: 'opening a gate alone does not flush',
      );
      rig.service.flushPending();
      rig.service.flushPending();
      expect(rig.routes, ['/livetrip', '/ride_chat']);
      expect(rig.service.pendingRoute, isNull);
      expect(rig.transport.permissionRequests, 1);
    });
  }

  test(
    'flush rechecks gate after every navigation and while signed out',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.unlocked = false;
      rig.tap('trip');
      rig.tap('chat');
      await rig.service.onSignedIn();
      rig.afterNavigate = () => rig.unlocked = false;
      rig.unlocked = true;
      rig.service.flushPending();
      expect(rig.routes, ['/livetrip']);
      expect(rig.service.pendingRoute, '/ride_chat');
      await rig.service.onSignedOut();
      rig.unlocked = true;
      rig.service.flushPending();
      expect(rig.routes, ['/livetrip']);
      rig.afterNavigate = null;
      await rig.service.onSignedIn();
      expect(rig.routes, ['/livetrip', '/ride_chat']);
    },
  );

  for (final error in <Object>[
    StateError('secret device data'),
    const RepositoryFailure(
      RepositoryFailureKind.invalidData,
      'secret data',
      cause: 'secret payload',
    ),
  ]) {
    test(
      'permission failure is safe and retryable (${error.runtimeType})',
      () async {
        final rig = _Rig();
        addTearDown(rig.dispose);
        rig.transport.permission = () => throw error;
        rig.tap();
        await rig.service.onSignedIn();
        _expectSafe(rig.service.lastFailure);
        expect(
          rig.routes,
          ['/livetrip'],
          reason: 'push failure must not block the authenticated session',
        );
        expect(rig.invoker.calls, isEmpty);
        rig.transport.permission = null;
        await rig.service.onSignedIn();
        expect(rig.transport.permissionRequests, 2);
        expect(rig.registry.registeredToken, 'token-a');
        expect(rig.service.lastFailure, isNull);
        await rig.service.onSignedIn();
        expect(rig.transport.permissionRequests, 2);
      },
    );
  }

  test('denied permission does not prevent token registration', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.transport.permission = () async => PushPermission.denied;
    await rig.service.onSignedIn();
    expect(rig.registry.registeredToken, 'token-a');
    expect(rig.service.lastFailure, isNull);
  });

  test(
    'registration failures never reject sign-in and can be retried',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.invoker.error = StateError('secret backend payload');
      await rig.service.onSignedIn();
      _expectSafe(rig.service.lastFailure);
      rig.tap();
      expect(rig.routes, ['/livetrip']);
      rig.invoker.error = null;
      await rig.service.onSignedIn();
      expect(rig.registry.registeredToken, 'token-a');
      expect(rig.service.lastFailure, isNull);
    },
  );

  test(
    'concurrent sign-ins coalesce; sign-out invalidates late permission',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final permission = Completer<PushPermission>();
      rig.transport.permission = () => permission.future;
      final first = rig.service.onSignedIn();
      final second = rig.service.onSignedIn();
      expect(identical(first, second), isTrue);
      await _settle();
      await rig.service.onSignedOut();
      rig.tap('chat');
      permission.complete(PushPermission.granted);
      await first;
      await second;
      expect(rig.transport.permissionRequests, 1);
      expect(rig.invoker.calls, isEmpty);
      expect(rig.transport.refreshes.hasListener, isFalse);
      expect(rig.routes, isEmpty);
      rig.transport.permission = null;
      await rig.service.onSignedIn();
      expect(rig.registry.registeredToken, 'token-a');
      expect(rig.routes, ['/ride_chat']);
    },
  );

  for (final oldFirst in [false, true]) {
    test(
      'old permission cannot change new startup (old first: $oldFirst)',
      () async {
        final rig = _Rig();
        addTearDown(rig.dispose);
        final oldPermission = Completer<PushPermission>();
        final newPermission = Completer<PushPermission>();
        rig.transport.permission = () => oldPermission.future;
        final old = rig.service.onSignedIn();
        await _settle();
        await rig.service.onSignedOut();
        rig.transport.permission = () => newPermission.future;
        final next = rig.service.onSignedIn();
        await _settle();
        if (!oldFirst) {
          newPermission.complete(PushPermission.granted);
          await next;
        }
        oldPermission.completeError(StateError('secret old permission'));
        await old;
        final coalesced = rig.service.onSignedIn();
        if (oldFirst) {
          expect(identical(coalesced, next), isTrue);
          newPermission.complete(PushPermission.granted);
        }
        await next;
        await coalesced;
        expect(rig.transport.permissionRequests, 2);
        expect(rig.invoker.calls, hasLength(1));
        expect(rig.registry.registeredToken, 'token-a');
        expect(rig.service.lastFailure, isNull);
      },
    );
  }

  test('sign-out during token lookup prevents late registration', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final token = Completer<String?>();
    rig.transport.lookup = () => token.future;
    final start = rig.service.onSignedIn();
    await _settle();
    expect(rig.transport.tokenReads, 1);
    await rig.service.onSignedOut();
    token.complete('late-token');
    await start;
    expect(rig.invoker.calls, isEmpty);
    expect(rig.registry.registeredToken, isNull);
    expect(rig.transport.refreshes.hasListener, isFalse);
    rig.tap();
    expect(rig.routes, isEmpty);
  });

  test(
    'dispose invalidates pending permission and permanently stops messages',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final permission = Completer<PushPermission>();
      rig.transport.permission = () => permission.future;
      final start = rig.service.onSignedIn();
      await _settle();
      rig.unlocked = false;
      rig.tap();
      final disposal = rig.service.dispose();
      expect(identical(rig.service.dispose(), disposal), isTrue);
      await disposal;
      permission.complete(PushPermission.granted);
      await start;
      rig.tap('chat');
      rig.transport.arrivals.add(const PushMessage());
      rig.unlocked = true;
      rig.service.flushPending();
      await rig.service.onSignedIn();
      await rig.service.onSignedOut();
      expect(rig.transport.arrivals.hasListener, isFalse);
      expect(rig.transport.refreshes.hasListener, isFalse);
      expect(rig.transport.permissionRequests, 1);
      expect(rig.invoker.calls, isEmpty);
      expect(rig.routes, isEmpty);
      expect(rig.foreground, isEmpty);
      expect(rig.service.pendingRoute, isNull);
    },
  );

  test(
    'dispose detaches a completed registration and stops rotation',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.service.onSignedIn();
      await rig.service.dispose();
      expect(rig.invoker.calls.map((call) => call.body['active']), [
        true,
        false,
      ]);
      expect(rig.registry.registeredToken, isNull);
      expect(rig.transport.refreshes.hasListener, isFalse);
      rig.transport.refreshes.add('late-token');
      await _settle();
      expect(rig.invoker.calls, hasLength(2));
    },
  );

  test('dispose during issued registration waits for ordered detach', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.invoker.deferred = true;
    final start = rig.service.onSignedIn();
    await _settle();
    final disposal = rig.service.dispose();
    await _settle();
    expect(rig.invoker.calls, hasLength(1));
    expect(rig.registry.registeredToken, isNull);
    rig.invoker.calls[0].result.complete();
    await start;
    await _settle();
    expect(rig.invoker.calls[1].body['active'], isFalse);
    expect(rig.registry.registeredToken, isNull);
    rig.invoker.calls[1].result.complete();
    await disposal;
    expect(rig.transport.arrivals.hasListener, isFalse);
    expect(rig.transport.refreshes.hasListener, isFalse);
  });

  test(
    'message stream errors are sanitized without breaking subscription',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.transport.arrivals.addError(StateError('secret message error'));
      _expectSafe(rig.service.lastFailure);
      rig.tap();
      await rig.service.onSignedIn();
      expect(rig.routes, ['/livetrip']);
    },
  );

  test('navigation callback failure cannot interrupt sign-in', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.afterNavigate = () => throw StateError('secret navigation failure');
    rig.tap();
    await rig.service.onSignedIn();
    expect(rig.registry.registeredToken, 'token-a');
    expect(rig.routes, ['/livetrip']);
  });

  test('unsupported transport never subscribes, requests or writes', () async {
    final rig = _Rig(supported: false);
    addTearDown(rig.dispose);
    rig.tap();
    await rig.service.onSignedIn();
    rig.service.flushPending();
    await rig.service.onSignedOut();
    await rig.service.dispose();
    expect(rig.transport.messageReads, 0);
    expect(rig.transport.arrivals.hasListener, isFalse);
    expect(rig.transport.permissionRequests, 0);
    expect(rig.transport.tokenReads, 0);
    expect(rig.invoker.calls, isEmpty);
    expect(rig.routes, isEmpty);
    expect(rig.foreground, isEmpty);
    expect(rig.service.lastFailure, isNull);
  });
}
