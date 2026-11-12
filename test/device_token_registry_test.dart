import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/repositories/edge_functions.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/services/device_token_registry.dart';
import 'package:surgo/services/push_transport.dart';

class _Transport implements PushTransport {
  bool supported = true;
  String? currentToken = 'token-a';
  Future<String?> Function()? lookup;
  int tokenReads = 0;
  int refreshReads = 0;
  final refreshes = StreamController<String>.broadcast(sync: true);

  @override
  bool get isSupported => supported;
  @override
  Future<PushPermission> requestPermission() async => PushPermission.granted;
  @override
  Future<String?> token() {
    tokenReads++;
    return lookup?.call() ?? Future<String?>.value(currentToken);
  }

  @override
  Stream<String> get tokenRefreshes {
    refreshReads++;
    return refreshes.stream;
  }

  @override
  Stream<PushMessage> get messages => const Stream<PushMessage>.empty();
}

class _Call {
  _Call(this.name, Map<String, Object?> body) : body = Map.of(body);
  final String name;
  final Map<String, Object?> body;
  final result = Completer<void>();
}

class _Invoker implements EdgeInvoker {
  bool deferred = false;
  Object? error;
  final List<_Call> calls = [];
  int active = 0;
  int maxActive = 0;

  @override
  Future<void> invoke(String name, Map<String, Object?> body) async {
    final call = _Call(name, body);
    calls.add(call);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (deferred) await call.result.future;
      if (error != null) throw error!;
    } finally {
      active--;
    }
  }
}

class _Rig {
  final transport = _Transport();
  final invoker = _Invoker();
  late final registry = DeviceTokenRegistry(
    transport: transport,
    invoker: () => invoker,
    platform: () => 'android',
  );

  Future<void> dispose() async {
    invoker.deferred = false;
    await registry.stop();
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
    'public constructor; concurrent starts share lookup and rotation watch',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final token = Completer<String?>();
      rig.transport.lookup = () => token.future;
      final first = rig.registry.start();
      final second = rig.registry.start();
      expect(identical(first, second), isTrue);
      await _settle();
      expect(rig.transport.tokenReads, 1);
      expect(rig.transport.refreshReads, 1);
      token.complete('token-a');
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(rig.registry.registeredToken, 'token-a');
      expect(rig.invoker.calls.single.name, DeviceTokenRegistry.functionName);
      expect(rig.invoker.calls.single.body, {
        'token': 'token-a',
        'platform': 'android',
        'active': true,
      });
    },
  );

  test(
    'register remains usable as a single write without a rotation watch',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      expect(await rig.registry.register(), isTrue);
      expect(rig.transport.refreshes.hasListener, isFalse);
      expect(rig.registry.registeredToken, 'token-a');
    },
  );

  test(
    'rotation uses the emitted token and detaches the last issued token',
    () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.registry.start();
      rig.transport.refreshes.add('token-b');
      await _settle();
      expect(rig.registry.registeredToken, 'token-b');
      expect(
        rig.transport.tokenReads,
        1,
        reason: 'the transport lookup may still hold the old token',
      );
      rig.transport.currentToken = null;
      await rig.registry.stop();
      expect(rig.invoker.calls.map((call) => call.body), [
        {'token': 'token-a', 'platform': 'android', 'active': true},
        {'token': 'token-b', 'platform': 'android', 'active': true},
        {'token': 'token-b', 'platform': 'android', 'active': false},
      ]);
      expect(rig.registry.registeredToken, isNull);
      rig.transport.refreshes.add('token-c');
      await _settle();
      expect(rig.invoker.calls, hasLength(3));
    },
  );

  test('a rotation supersedes a slow initial token lookup', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final token = Completer<String?>();
    rig.transport.lookup = () => token.future;
    final start = rig.registry.start();
    await _settle();
    rig.transport.refreshes.add('token-b');
    await _settle();
    token.complete('token-a');
    expect(await start, isFalse);
    expect(rig.registry.registeredToken, 'token-b');
    expect(rig.invoker.calls.single.body['token'], 'token-b');
  });

  test('stop before startup executes does not subscribe or write', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final start = rig.registry.start();
    await rig.registry.stop();
    expect(await start, isFalse);
    expect(rig.transport.tokenReads, 0);
    expect(rig.transport.refreshes.hasListener, isFalse);
    expect(rig.invoker.calls, isEmpty);
  });

  for (final watch in [false, true]) {
    test('stop invalidates pending lookup (watch: $watch)', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final token = Completer<String?>();
      rig.transport.lookup = () => token.future;
      final registration = watch
          ? rig.registry.start()
          : rig.registry.register();
      await _settle();
      await rig.registry.stop();
      expect(rig.registry.registeredToken, isNull);
      expect(rig.transport.refreshes.hasListener, isFalse);
      token.complete('late-token');
      expect(await registration, isFalse);
      expect(rig.invoker.calls, isEmpty);
    });
  }

  test('old lookup errors cannot overwrite a restarted generation', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final token = Completer<String?>();
    rig.transport.lookup = () => token.future;
    final old = rig.registry.start();
    await _settle();
    await rig.registry.stop();
    rig.transport.lookup = null;
    rig.transport.currentToken = 'new-token';
    expect(await rig.registry.start(), isTrue);
    token.completeError(StateError('secret old lookup'));
    expect(await old, isFalse);
    expect(rig.registry.registeredToken, 'new-token');
    expect(rig.registry.lastFailure, isNull);
    expect(rig.transport.refreshes.hasListener, isTrue);
  });

  for (final fails in [false, true]) {
    test('stop orders detach after issued write (failure: $fails)', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.invoker.deferred = true;
      final start = rig.registry.start();
      await _settle();
      rig.transport.refreshes.add('queued-token');
      final stop = rig.registry.stop();
      expect(rig.registry.registeredToken, isNull);
      await _settle();
      expect(rig.invoker.calls, hasLength(1));
      if (fails) {
        rig.invoker.calls.first.result.completeError(
          StateError('secret write'),
        );
      } else {
        rig.invoker.calls.first.result.complete();
      }
      expect(await start, isFalse);
      await _settle();
      expect(rig.invoker.calls, hasLength(2));
      expect(rig.invoker.calls.last.body, {
        'token': 'token-a',
        'platform': 'android',
        'active': false,
      });
      expect(rig.registry.registeredToken, isNull);
      rig.invoker.calls.last.result.complete();
      await stop;
      expect(rig.invoker.maxActive, 1);
      expect(rig.registry.registeredToken, isNull);
      expect(rig.transport.refreshes.hasListener, isFalse);
    });
  }

  test('rotation writes and detach never overlap', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await rig.registry.start();
    rig.invoker.deferred = true;
    rig.transport.refreshes.add('token-b');
    await _settle();
    expect(rig.registry.registeredToken, isNull);
    final stop = rig.registry.stop();
    await _settle();
    expect(rig.invoker.calls, hasLength(2));
    rig.invoker.calls[1].result.complete();
    await _settle();
    expect(rig.invoker.calls[2].body['token'], 'token-b');
    expect(rig.invoker.calls[2].body['active'], isFalse);
    rig.invoker.calls[2].result.complete();
    await stop;
    expect(rig.invoker.maxActive, 1);
    expect(rig.registry.registeredToken, isNull);
  });

  test('restart waits behind old issued write and its detach', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.invoker.deferred = true;
    final old = rig.registry.start();
    await _settle();
    final stop = rig.registry.stop();
    rig.transport.currentToken = 'token-b';
    final next = rig.registry.start();
    await _settle();
    expect(rig.invoker.calls, hasLength(1));
    rig.invoker.calls[0].result.complete();
    expect(await old, isFalse);
    await _settle();
    expect(rig.invoker.calls[1].body['active'], isFalse);
    expect(rig.registry.registeredToken, isNull);
    rig.invoker.calls[1].result.complete();
    await stop;
    await _settle();
    expect(rig.invoker.calls[2].body, {
      'token': 'token-b',
      'platform': 'android',
      'active': true,
    });
    rig.invoker.calls[2].result.complete();
    expect(await next, isTrue);
    expect(rig.registry.registeredToken, 'token-b');
    expect(rig.invoker.maxActive, 1);
  });

  for (final error in <Object>[
    StateError('secret token / profile'),
    const RepositoryFailure(
      RepositoryFailureKind.invalidData,
      'secret token',
      cause: 'secret payload',
    ),
  ]) {
    test(
      'token lookup exceptions are sanitized (${error.runtimeType})',
      () async {
        final rig = _Rig();
        addTearDown(rig.dispose);
        rig.transport.lookup = () => throw error;
        expect(await rig.registry.start(), isFalse);
        _expectSafe(rig.registry.lastFailure);
        expect(rig.invoker.calls, isEmpty);
        rig.transport.lookup = null;
        expect(await rig.registry.start(), isTrue);
        expect(rig.registry.lastFailure, isNull);
      },
    );

    test('invoker exceptions are sanitized (${error.runtimeType})', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.invoker.error = error;
      expect(await rig.registry.start(), isFalse);
      _expectSafe(rig.registry.lastFailure);
      expect(rig.registry.registeredToken, isNull);
      await rig.registry.stop();
      _expectSafe(rig.registry.lastFailure);
      expect(rig.invoker.calls.last.body['active'], isFalse);
    });
  }

  test('invoker factory errors are sanitized', () async {
    final transport = _Transport();
    addTearDown(transport.refreshes.close);
    final registry = DeviceTokenRegistry(
      transport: transport,
      invoker: () => throw StateError('secret credentials'),
      platform: () => 'ios',
    );
    addTearDown(registry.stop);
    expect(await registry.start(), isFalse);
    _expectSafe(registry.lastFailure);
    await registry.stop();
    _expectSafe(registry.lastFailure);
  });

  test('rotation stream errors are sanitized and do not escape', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await rig.registry.start();
    rig.transport.refreshes.addError(StateError('secret stream'));
    _expectSafe(rig.registry.lastFailure);
    rig.transport.refreshes.add('token-b');
    await _settle();
    expect(rig.registry.lastFailure, isNull);
    expect(rig.registry.registeredToken, 'token-b');
  });

  test('null and empty tokens are ordinary absence, not failures', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    for (final token in <String?>[null, '']) {
      rig.transport.currentToken = token;
      expect(await rig.registry.register(), isFalse);
      expect(rig.registry.lastFailure, isNull);
    }
    expect(rig.invoker.calls, isEmpty);
  });

  test(
    'unsupported transport and platform perform no token or edge writes',
    () async {
      for (final unsupportedTransport in [true, false]) {
        final transport = _Transport()..supported = !unsupportedTransport;
        final invoker = _Invoker();
        final registry = DeviceTokenRegistry(
          transport: transport,
          invoker: () => invoker,
          platform: () => null,
        );
        expect(await registry.start(), isFalse);
        expect(await registry.register(), isFalse);
        await registry.stop();
        transport.refreshes.add('token-b');
        await _settle();
        expect(transport.tokenReads, 0);
        expect(invoker.calls, isEmpty);
        expect(registry.lastFailure, isNull);
        await transport.refreshes.close();
      }
    },
  );

  test('platform enum mapping is preserved', () {
    expect(pushPlatformName(TargetPlatform.android), 'android');
    expect(pushPlatformName(TargetPlatform.iOS), 'ios');
    expect(pushPlatformName(TargetPlatform.macOS), 'ios');
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      expect(pushPlatformName(platform), isNull);
    }
  });
}
