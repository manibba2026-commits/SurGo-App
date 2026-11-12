import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/edge_functions.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/ride_location_repository.dart';
import 'package:surgo/services/location_publisher.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_status.dart';

/// Tandag, so a coordinate that has to look real does.
const double baseLat = 9.1036;
const double baseLng = 126.1354;

/// Roughly 111 metres per 0.001 of latitude.
LocationFix fix({
  double moveLat = 0,
  DateTime? at,
  double? accuracy = 10,
  double lat = baseLat,
  double lng = baseLng,
}) =>
    LocationFix(
      latitude: lat + moveLat,
      longitude: lng,
      readAt: at ?? DateTime.utc(2026, 11, 6, 8),
      accuracyMeters: accuracy,
    );

/// A fix 33 metres north of [origin] — far enough to count as a real move.
LocationFix moved(LocationFix origin) => LocationFix(
      latitude: origin.latitude + 0.0003,
      longitude: origin.longitude,
      readAt: origin.readAt,
      accuracyMeters: origin.accuracyMeters,
    );

class _Rig {
  _Rig({LocationSink? sink, Future<Stream<LocationFix>?> Function()? positions})
      : _sinkOverride = sink,
        _positionsOverride = positions;

  final LocationSink? _sinkOverride;
  final Future<Stream<LocationFix>?> Function()? _positionsOverride;
  final DateTime t0 = DateTime.utc(2026, 11, 6, 8);

  late DateTime now = t0;
  late InMemoryLocationSink memory = InMemoryLocationSink();
  late StreamController<LocationFix> fixes =
      StreamController<LocationFix>.broadcast();

  /// How many times the device was asked for permission / a position stream.
  int asks = 0;
  bool denyPositioning = false;

  LocationSink get sink => _sinkOverride ?? memory;

  late final LocationPublisher publisher = LocationPublisher(
    sink: () => sink,
    positions: () async {
      asks++;
      if (_positionsOverride != null) return _positionsOverride();
      return denyPositioning ? null : fixes.stream;
    },
    clock: () => now,
  );

  /// Applies the app's current situation and lets the permission round trip
  /// finish, so a test never has to know how many microtasks a start takes.
  Future<void> sync({
    bool online = true,
    String? rideId = 'ride-1',
    String? riderId = 'rider-1',
    String? signedIn = 'rider-1',
    RideStatus? status = RideStatus.accepted,
  }) async {
    publisher.sync(
      online: online,
      rideId: rideId,
      riderId: riderId,
      signedInProfileId: signedIn,
      status: status,
    );
    await settle();
  }

  Future<void> send(LocationFix fix) async {
    fixes.add(fix);
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void dispose() {
    publisher.dispose();
    unawaited(fixes.close());
  }
}

/// A sink that refuses the first [failures] publishes.
class _RefusingSink implements LocationSink {
  _RefusingSink(this.failures);

  int failures;
  final List<LocationFix> published = [];

  @override
  Future<void> publish({
    required String rideId,
    required String riderId,
    required LocationFix fix,
  }) async {
    if (failures > 0) {
      failures--;
      throw RepositoryFailure.offline();
    }
    published.add(fix);
  }
}

class _DeferredPositions {
  final List<Completer<Stream<LocationFix>?>> requests = [];

  Future<Stream<LocationFix>?> call() {
    final request = Completer<Stream<LocationFix>?>();
    requests.add(request);
    return request.future;
  }
}

class _PublishCall {
  _PublishCall(this.rideId, this.riderId, this.fix);

  final String rideId;
  final String riderId;
  final LocationFix fix;
  final result = Completer<void>();
}

class _DeferredSink implements LocationSink {
  final List<_PublishCall> calls = [];
  int active = 0;
  int maxActive = 0;

  @override
  Future<void> publish({
    required String rideId,
    required String riderId,
    required LocationFix fix,
  }) async {
    final call = _PublishCall(rideId, riderId, fix);
    calls.add(call);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await call.result.future;
    } finally {
      active--;
    }
  }
}

class _LateStream extends Stream<LocationFix> {
  final _controller = StreamController<LocationFix>();
  void Function(LocationFix)? _onData;
  Function? _onError;
  void Function()? _onDone;

  @override
  StreamSubscription<LocationFix> listen(
    void Function(LocationFix)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    _onError = onError;
    _onDone = onDone;
    return _controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  void emit(LocationFix fix) => _onData?.call(fix);
  void fail() => _onError?.call(StateError('late stream failure'));
  void finish() => _onDone?.call();
  void dispose() => unawaited(_controller.close());
}

/// A sink that records what the app put on the wire.
class _RecordingInvoker implements EdgeInvoker {
  final List<Map<String, Object?>> calls = [];

  @override
  Future<void> invoke(String name, Map<String, Object?> body) async {
    calls.add({'name': name, ...body});
  }
}

void main() {
  // The app-wiring group drives the real AppState singleton, which reads the
  // seed through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('trip gate', () {
    test('only a committed, unfinished trip may share', () {
      for (final status in RideStatus.values) {
        final expected = switch (status) {
          RideStatus.accepted ||
          RideStatus.headingToPickup ||
          RideStatus.arrived ||
          RideStatus.inProgress =>
            true,
          _ => false,
        };
        expect(LocationRules.isSharedTrip(status), expected,
            reason: status.name);
      }
      expect(LocationRules.isSharedTrip(null), isFalse);
    });

    test('a matching request shares nothing, to anyone', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync(status: RideStatus.searching);
      expect(rig.asks, 0);
      expect(rig.publisher.status, LocationShareStatus.off);

      await rig.sync(status: RideStatus.awaitingAcceptance);
      expect(rig.asks, 0, reason: 'a proposed rider is not an assigned one');
    });

    test('sharing starts the moment the rider accepts', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync();
      expect(rig.publisher.status, LocationShareStatus.sharing);
    });

    test('the device only shares when it is the assigned rider', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync(signedIn: 'passenger-1');
      expect(rig.asks, 0, reason: 'a passenger holds no rider trail to write');

      await rig.sync(riderId: 'other-rider');
      expect(rig.asks, 0, reason: 'this trip belongs to somebody else');
    });

    test('going offline, finishing or cancelling stops the share', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync();

      for (final stop in [
        () => rig.sync(online: false),
        () => rig.sync(status: RideStatus.completed),
        () => rig.sync(status: RideStatus.cancelled),
        () => rig.sync(rideId: null, riderId: null, status: null),
      ]) {
        await stop();
        expect(rig.publisher.status, LocationShareStatus.off);
        await rig.send(fix());
        expect(rig.memory.published, isEmpty);
      }
    });
  });

  group('fix validation', () {
    test('rejects coordinates the database would refuse', () {
      final at = DateTime.utc(2026, 11, 6, 8);
      for (final bad in [
        fix(lat: double.nan, at: at),
        fix(lng: double.infinity, at: at),
        fix(lat: 91, at: at),
        fix(lat: -91, at: at),
        fix(lng: 181, at: at),
        fix(lat: 0, lng: 0, at: at),
      ]) {
        expect(LocationRules.isTrustworthy(bad, now: at), isFalse,
            reason: '${bad.latitude},${bad.longitude}');
      }
    });

    test('rejects a fix with no accuracy, a poor one, or an old one', () {
      final at = DateTime.utc(2026, 11, 6, 8);
      expect(LocationRules.isTrustworthy(fix(accuracy: null, at: at), now: at),
          isFalse);
      expect(
          LocationRules.isTrustworthy(
              fix(accuracy: LocationRules.maxAccuracyMeters + 1, at: at),
              now: at),
          isFalse);
      expect(
          LocationRules.isTrustworthy(
              fix(
                  at: at.subtract(
                      LocationRules.maxFixAge + const Duration(seconds: 1))),
              now: at),
          isFalse);
      expect(LocationRules.isTrustworthy(fix(at: at), now: at), isTrue);
    });

    test('an untrustworthy fix is never written', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync();
      await rig.send(fix(accuracy: 5000));
      await rig.send(fix(lat: 200));
      expect(rig.memory.published, isEmpty);
      expect(rig.memory.lastByRide, isEmpty);

      await rig.send(fix());
      expect(rig.memory.published, hasLength(1));
    });
  });

  group('write throttle', () {
    test('a rider who has not moved writes nothing', () {
      final first = fix();
      final nudged = fix(
          moveLat: 0.0001, at: first.readAt.add(const Duration(seconds: 5)));
      expect(
          LocationRules.isWorthWriting(
              fix: first, lastWritten: null, now: first.readAt),
          isTrue);
      expect(
          LocationRules.isWorthWriting(
              fix: nudged, lastWritten: first, now: nudged.readAt),
          isFalse);
      final further = moved(first).copyAt(nudged.readAt);
      expect(
          LocationRules.isWorthWriting(
              fix: further, lastWritten: first, now: further.readAt),
          isTrue);
    });

    test('a long idle still gets one heartbeat', () {
      final first = fix();
      final later = fix(at: first.readAt.add(const Duration(seconds: 31)));
      expect(
          LocationRules.isWorthWriting(
              fix: later, lastWritten: first, now: later.readAt),
          isTrue);
    });

    test('the publisher applies the throttle to real fixes', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync();

      final first = fix(at: rig.now);
      await rig.send(first);
      await rig.send(
          fix(moveLat: 0.0001, at: rig.now.add(const Duration(seconds: 4))));
      expect(rig.memory.published, hasLength(1),
          reason: 'a few metres at pickup is not a move');

      // Same place, but the last row is now old enough to need a heartbeat.
      rig.now = first.readAt.add(const Duration(seconds: 31));
      await rig.send(fix(at: rig.now));
      expect(rig.memory.published, hasLength(2));

      expect(rig.publisher.lastWritten, isNotNull);
      expect(rig.memory.lastByRide['ride-1'], rig.publisher.lastWritten);
    });
  });

  group('connectivity, permission and failure', () {
    test(
        'a denied permission is asked for once per trip, then retried on the next',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.denyPositioning = true;
      await rig.sync();
      expect(rig.publisher.status, LocationShareStatus.unavailable);
      expect(rig.asks, 1);

      await rig.sync();
      await rig.sync(status: RideStatus.headingToPickup);
      expect(rig.asks, 1, reason: 'a prompt already refused is not re-raised');

      await rig.sync(rideId: 'ride-2');
      expect(rig.asks, 2, reason: 'a new trip is a new chance');
    });

    test('a lost connection keeps sharing without inventing a row', () async {
      final refusing = _RefusingSink(2);
      final rig = _Rig(sink: refusing);
      addTearDown(rig.dispose);
      await rig.sync();

      var at = rig.now;
      for (var i = 0; i < 2; i++) {
        at = at.add(const Duration(minutes: 1));
        rig.now = at;
        await rig.send(moved(fix(at: at)));
      }
      expect(rig.publisher.status, LocationShareStatus.sharing,
          reason: 'two failures is a bad signal, not a refused share');

      rig.now = at.add(const Duration(minutes: 1));
      await rig.send(moved(fix(at: rig.now)));
      expect(refusing.published, hasLength(1));
    });

    test('a sink that never accepts is reported and left alone', () async {
      final refusing = _RefusingSink(LocationPublisher.maxPublishFailures);
      final rig = _Rig(sink: refusing);
      addTearDown(rig.dispose);
      await rig.sync();

      var at = rig.now;
      for (var i = 0; i < LocationPublisher.maxPublishFailures; i++) {
        at = at.add(const Duration(minutes: 1));
        rig.now = at;
        await rig.send(moved(fix(at: at)));
      }
      expect(rig.publisher.status, LocationShareStatus.unavailable);

      final asks = rig.asks;
      await rig.sync();
      expect(rig.asks, asks, reason: 'a given-up trip is not retried per tap');
    });

    test('stale is shown while fixes stop and clears when they resume',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.sync();
      final first = fix(at: rig.now);
      await rig.send(first);
      expect(rig.publisher.status, LocationShareStatus.sharing);

      rig.now = first.readAt.add(const Duration(seconds: 46));
      rig.publisher.checkFreshness();
      expect(rig.publisher.status, LocationShareStatus.stale);

      rig.now = first.readAt.add(const Duration(seconds: 60));
      await rig.send(moved(first).copyAt(rig.now));
      expect(rig.publisher.status, LocationShareStatus.sharing);
    });

    test('stale is judged by age, and an accepted trip with no fix is stale',
        () {
      final at = DateTime.utc(2026, 11, 6, 8);
      expect(LocationRules.isStale(newest: null, now: at), isTrue);
      expect(
          LocationRules.isStale(
              newest: fix(at: at.subtract(const Duration(seconds: 20))),
              now: at),
          isFalse);
      expect(
          LocationRules.isStale(
              newest: fix(at: at.subtract(const Duration(minutes: 2))),
              now: at),
          isTrue);
      expect(
          LocationRules.isStale(
              newest: fix(at: at),
              now: at,
              acceptedSecondsAgo: LocationRules.staleAfter.inSeconds + 1),
          isTrue,
          reason:
              'the server can say how old a trail is even if the clock differs');
    });
  });

  group('async sharing lifecycle', () {
    for (final denied in [false, true]) {
      test('stopping pending permission clears the request (denied: $denied)',
          () async {
        final positions = _DeferredPositions();
        final rig = _Rig(positions: positions.call);
        addTearDown(rig.dispose);
        await rig.sync();
        expect(rig.publisher.isSharingRequested, isTrue);

        await rig.sync(online: false);
        rig.publisher.stop();
        expect(rig.publisher.isSharingRequested, isFalse);
        expect(rig.publisher.isPublishing, isFalse);
        expect(rig.publisher.status, LocationShareStatus.off);
        positions.requests[0].complete(denied ? null : rig.fixes.stream);
        await rig.settle();
        expect(rig.fixes.hasListener, isFalse);
        expect(rig.publisher.isSharingRequested, isFalse);
        expect(rig.publisher.status, LocationShareStatus.off);

        await rig.sync();
        expect(rig.asks, 2);
        positions.requests[1].complete(rig.fixes.stream);
        await rig.settle();
        await rig.send(fix());
        expect(rig.memory.published, hasLength(1));
      });

      for (final oldFirst in [false, true]) {
        test('superseded permission cannot change the new start '
            '(denied: $denied, old first: $oldFirst)', () async {
          final positions = _DeferredPositions();
          final rig = _Rig(positions: positions.call);
          addTearDown(rig.dispose);
          await rig.sync();
          await rig.sync(rideId: 'ride-2');
          expect(rig.asks, 2);

          if (!oldFirst) {
            positions.requests[1].complete(rig.fixes.stream);
            await rig.settle();
          }
          positions.requests[0].complete(denied ? null : rig.fixes.stream);
          await rig.settle();
          await rig.sync(rideId: 'ride-2');
          expect(rig.asks, 2, reason: 'the newer permission owns _starting');
          if (oldFirst) {
            expect(rig.fixes.hasListener, isFalse);
            positions.requests[1].complete(rig.fixes.stream);
            await rig.settle();
          }
          await rig.send(fix());
          expect(rig.publisher.status, LocationShareStatus.sharing);
          expect(rig.memory.lastByRide.keys, ['ride-2']);
        });
      }
    }

    test('disposed pending permission cannot subscribe or notify', () async {
      final positions = _DeferredPositions();
      final rig = _Rig(positions: positions.call);
      addTearDown(() => unawaited(rig.fixes.close()));
      await rig.sync();
      var notifications = 0;
      rig.publisher.addListener(() => notifications++);
      rig.publisher.dispose();
      positions.requests.single.complete(rig.fixes.stream);
      await rig.settle();
      expect(rig.publisher.isSharingRequested, isFalse);
      expect(rig.publisher.isPublishing, isFalse);
      expect(rig.publisher.status, LocationShareStatus.off);
      expect(rig.fixes.hasListener, isFalse);
      expect(notifications, 0);
    });

    for (final switchRider in [false, true]) {
      test('switching ${switchRider ? 'rider' : 'trip'} resets the trail',
          () async {
        final sink = _DeferredSink();
        final rig = _Rig(sink: sink);
        addTearDown(rig.dispose);
        await rig.sync();
        await rig.send(fix());
        sink.calls[0].result.complete();
        await rig.settle();
        expect(rig.publisher.lastWritten, isNotNull);

        await rig.sync(
          rideId: switchRider ? 'ride-1' : 'ride-2',
          riderId: switchRider ? 'rider-2' : 'rider-1',
          signedIn: switchRider ? 'rider-2' : 'rider-1',
        );
        expect(rig.asks, 2);
        expect(rig.publisher.lastWritten, isNull);
        await rig.send(fix());
        expect(sink.calls, hasLength(2),
            reason: 'the old trail must not throttle the new share');
        expect(sink.calls[1].rideId, switchRider ? 'ride-1' : 'ride-2');
        expect(sink.calls[1].riderId, switchRider ? 'rider-2' : 'rider-1');
        sink.calls[1].result.complete();
        await rig.settle();
      });
    }

    for (final fails in [false, true]) {
      for (final disposed in [false, true]) {
        test('late write ${fails ? 'failure' : 'success'} after '
            '${disposed ? 'dispose' : 'stop'} stays off', () async {
          final sink = _DeferredSink();
          final rig = _Rig(sink: sink);
          if (disposed) {
            addTearDown(() => unawaited(rig.fixes.close()));
          } else {
            addTearDown(rig.dispose);
          }
          await rig.sync();
          await rig.send(fix());
          await rig.send(moved(fix()));
          expect(sink.calls, hasLength(1));
          var notifications = 0;
          rig.publisher.addListener(() => notifications++);
          if (disposed) {
            rig.publisher.dispose();
          } else {
            rig.publisher.stop();
          }
          final stoppedNotifications = notifications;
          if (fails) {
            sink.calls.single.result.completeError(RepositoryFailure.offline());
          } else {
            sink.calls.single.result.complete();
          }
          await rig.settle();
          rig.publisher.checkFreshness();
          expect(rig.publisher.status, LocationShareStatus.off);
          expect(rig.publisher.isPublishing, isFalse);
          expect(rig.publisher.isSharingRequested, isFalse);
          expect(rig.publisher.lastWritten, isNull);
          expect(sink.calls, hasLength(1), reason: 'queued fixes were cleared');
          expect(notifications, stoppedNotifications);
          expect(rig.fixes.hasListener, isFalse);
        });
      }

      test('old trip write ${fails ? 'failure' : 'success'} cannot affect '
          'the new trip or overlap its writes', () async {
        final sink = _DeferredSink();
        final rig = _Rig(sink: sink);
        addTearDown(rig.dispose);
        await rig.sync();
        for (var i = 0; i < 2; i++) {
          await rig.send(fix());
          sink.calls[i].result.completeError(RepositoryFailure.offline());
          await rig.settle();
        }
        await rig.send(fix());
        await rig.send(moved(fix()));
        await rig.sync(rideId: 'ride-2');
        final newest = fix(moveLat: 0.001);
        await rig.send(newest);
        rig.publisher.checkFreshness();
        expect(sink.calls, hasLength(3));
        expect(sink.active, 1);
        if (fails) {
          sink.calls[2].result.completeError(RepositoryFailure.offline());
        } else {
          sink.calls[2].result.complete();
        }
        await rig.settle();
        expect(sink.calls, hasLength(4));
        expect(sink.calls[3].rideId, 'ride-2');
        expect(sink.calls[3].fix, same(newest));
        expect(rig.publisher.lastWritten, isNull);
        expect(rig.publisher.status, LocationShareStatus.stale);

        for (var i = 3; i < 5; i++) {
          sink.calls[i].result.completeError(RepositoryFailure.offline());
          await rig.settle();
          expect(rig.publisher.isPublishing, isTrue,
              reason: 'old failures do not count against the new trip');
          await rig.send(newest);
        }
        sink.calls[5].result.complete();
        await rig.settle();
        expect(rig.publisher.lastWritten, same(newest));
        expect(rig.publisher.status, LocationShareStatus.sharing);
        expect(sink.maxActive, 1);
      });

      test('stop/restart with the same IDs ignores old write '
          '${fails ? 'failure' : 'success'}', () async {
        final sink = _DeferredSink();
        final rig = _Rig(sink: sink);
        addTearDown(rig.dispose);
        await rig.sync();
        await rig.send(fix());
        rig.publisher.stop();
        await rig.sync();
        final newest = moved(fix());
        await rig.send(newest);
        rig.publisher.checkFreshness();
        expect(sink.calls, hasLength(1));
        if (fails) {
          sink.calls[0].result.completeError(RepositoryFailure.offline());
        } else {
          sink.calls[0].result.complete();
        }
        await rig.settle();
        expect(sink.calls, hasLength(2));
        expect(rig.publisher.lastWritten, isNull);
        expect(rig.publisher.status, LocationShareStatus.stale);
        sink.calls[1].result.complete();
        await rig.settle();
        expect(rig.publisher.lastWritten, same(newest));
        expect(rig.publisher.status, LocationShareStatus.sharing);
        expect(sink.maxActive, 1);
      });
    }

    test('cancelled subscription callbacks cannot publish or pause a new trip',
        () async {
      final oldStream = _LateStream();
      addTearDown(oldStream.dispose);
      var asks = 0;
      late _Rig rig;
      rig = _Rig(positions: () async {
        return asks++ == 0 ? oldStream : rig.fixes.stream;
      });
      addTearDown(rig.dispose);
      await rig.sync();
      await rig.sync(rideId: 'ride-2');
      oldStream.emit(fix());
      oldStream.fail();
      oldStream.finish();
      await rig.settle();
      expect(rig.memory.published, isEmpty);
      expect(rig.publisher.isPublishing, isTrue);
      expect(rig.publisher.status, LocationShareStatus.sharing);
      await rig.send(fix());
      expect(rig.memory.lastByRide.keys, ['ride-2']);
    });

    test('a stream pause clears queued fixes and invalidates an in-flight write',
        () async {
      final sink = _DeferredSink();
      final rig = _Rig(sink: sink);
      addTearDown(rig.dispose);
      await rig.sync();
      await rig.send(fix());
      sink.calls[0].result.complete();
      await rig.settle();
      await rig.send(moved(fix()));
      await rig.send(fix(moveLat: 0.001));
      rig.fixes.addError(StateError('position stream unavailable'));
      await rig.settle();
      expect(rig.publisher.status, LocationShareStatus.unavailable);
      expect(rig.publisher.isPublishing, isFalse);
      expect(rig.publisher.isSharingRequested, isTrue);
      expect(rig.publisher.lastWritten, isNull);
      expect(rig.fixes.hasListener, isFalse);
      sink.calls[1].result.complete();
      await rig.settle();
      rig.now = rig.now.add(const Duration(minutes: 1));
      rig.publisher.checkFreshness();
      await rig.sync();
      expect(rig.asks, 1);
      expect(sink.calls, hasLength(2));
      expect(rig.publisher.status, LocationShareStatus.unavailable);
    });
  });

  group('coalesced writes', () {
    test('overlapping positions keep only the freshest pending fix', () async {
      final sink = _DeferredSink();
      final rig = _Rig(sink: sink);
      addTearDown(rig.dispose);
      await rig.sync();
      await rig.send(fix());
      for (var i = 1; i <= 100; i++) {
        rig.fixes.add(fix(moveLat: i * 0.0003,
            at: rig.t0.add(Duration(milliseconds: i))));
      }
      final newest = fix(moveLat: 0.04,
          at: rig.t0.add(const Duration(milliseconds: 101)));
      await rig.send(newest);
      await rig.send(fix(moveLat: 0.05,
          at: rig.t0.add(const Duration(milliseconds: 50))));
      expect(sink.calls, hasLength(1));
      expect(sink.active, 1);
      sink.calls[0].result.complete();
      await rig.settle();
      expect(sink.calls, hasLength(2));
      expect(sink.calls[1].fix, same(newest));
      sink.calls[1].result.complete();
      await rig.settle();
      await rig.send(fix(moveLat: 0.06));
      expect(sink.calls, hasLength(2), reason: 'older fixes cannot rewind');
      expect(rig.publisher.lastWritten, same(newest));
      expect(sink.maxActive, 1);
    });

    test('pending fixes are revalidated for age before publishing', () async {
      final sink = _DeferredSink();
      final rig = _Rig(sink: sink);
      addTearDown(rig.dispose);
      await rig.sync();
      await rig.send(fix());
      await rig.send(moved(fix()));
      rig.now = rig.now.add(LocationRules.maxFixAge + const Duration(seconds: 1));
      sink.calls[0].result.complete();
      await rig.settle();
      expect(sink.calls, hasLength(1));
      await rig.send(moved(fix(at: rig.now)));
      expect(sink.calls, hasLength(2));
      sink.calls[1].result.complete();
      await rig.settle();
      expect(sink.maxActive, 1);
    });

    test('latest pending fix is throttled against the newly accepted write',
        () async {
      final sink = _DeferredSink();
      final rig = _Rig(sink: sink);
      addTearDown(rig.dispose);
      await rig.sync();
      final first = fix();
      await rig.send(first);
      await rig.send(moved(first));
      await rig.send(fix(moveLat: 0.00001,
          at: rig.now.add(const Duration(seconds: 1))));
      await rig.send(fix(accuracy: 5000,
          at: rig.now.add(const Duration(seconds: 2))));
      sink.calls[0].result.complete();
      await rig.settle();
      expect(sink.calls, hasLength(1),
          reason: 'do not replay an earlier move after the rider returns');
      expect(rig.publisher.lastWritten, same(first));
      await rig.send(moved(first).copyAt(
          rig.now.add(const Duration(seconds: 3))));
      expect(sink.calls, hasLength(2));
      sink.calls[1].result.complete();
      await rig.settle();
    });
  });

  group('edge sink payload', () {
    test('a hosted ride is sent to the publishing function with its own clock',
        () async {
      final invoker = _RecordingInvoker();
      final sink = EdgeLocationSink(invoker);
      final at = DateTime.utc(2026, 11, 6, 8, 30);
      await sink.publish(
        rideId: '3f2a1b0c-4d5e-6f70-8192-a3b4c5d6e7f8',
        riderId: 'rider-1',
        fix: fix(at: at),
      );
      expect(invoker.calls, hasLength(1));
      final call = invoker.calls.single;
      expect(call['name'], EdgeLocationSink.functionName);
      expect(call['latitude'], baseLat);
      expect(call['longitude'], baseLng);
      expect(call['recorded_at'], at.toUtc().toIso8601String());
      expect(call.containsKey('rider_id'), isFalse,
          reason: 'the server decides whose trail this is, not the device');
    });

    test('a prototype ride id never reaches the function', () async {
      final invoker = _RecordingInvoker();
      final sink = EdgeLocationSink(invoker);
      await expectLater(
        sink.publish(rideId: 'ride-1', riderId: 'rider-1', fix: fix()),
        throwsA(isA<RepositoryFailure>()
            .having((f) => f.kind, 'kind', RepositoryFailureKind.unsupported)),
      );
      expect(invoker.calls, isEmpty);
    });
  });

  group('app wiring', () {
    late AppState state;
    RideRequestItem? taken;

    Future<void> settlePublisher() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUpAll(() async {
      state = AppState.instance;
      await state.init();
    });

    setUp(() {
      state.activeRide = null;
      state.riderOnline = true;
    });

    tearDown(() {
      state.activeRide = null;
      state.riderOnline = true;
      final request = taken;
      if (request != null && !state.db.rideRequests.contains(request)) {
        state.db.rideRequests.add(request);
      }
      taken = null;
    });

    /// Accepts a seeded request the way the rider's incoming list does: the
    /// app assigns itself as the rider, then accepts.
    Future<void> acceptTrip() async {
      final request = state.pendingRequests.first;
      taken = request;
      request.riderId = state.db.earner.id;
      state.respondToRequest(request, accepted: true);
      expect(state.activeRide, same(request));
      await settlePublisher();
    }

    test('an accepted prototype trip makes the app ask for the device position',
        () async {
      expect(state.locationPublisher.isSharingRequested, isFalse);

      await acceptTrip();
      expect(state.locationPublisher.isSharingRequested, isTrue,
          reason: 'a committed trip with the device as rider is shareable');
      expect(state.locationPublisher.status, isNot(LocationShareStatus.off),
          reason: 'the app asked; only the device can refuse');
    });

    test('a trip still being matched asks for nothing', () async {
      final request = state.pendingRequests.first;
      taken = request;
      request.riderId = state.db.earner.id;
      request.status = RideStatus.searching;
      state.activeRide = request;
      state.notifyListeners();
      await settlePublisher();

      expect(state.locationPublisher.isSharingRequested, isFalse,
          reason: 'matching riders are not entitled to a live position');
      expect(state.locationPublisher.status, LocationShareStatus.off);
    });

    test('going offline stops the share mid-trip', () async {
      await acceptTrip();
      state.toggleRiderOnline();
      await settlePublisher();
      expect(state.locationPublisher.isSharingRequested, isFalse);
      expect(state.locationPublisher.status, LocationShareStatus.off);
    });

    test('completing the trip stops the share', () async {
      await acceptTrip();
      for (var i = 0; i < 4; i++) {
        state.advanceRide();
      }
      expect(state.activeRide?.status, RideStatus.completed);
      await settlePublisher();
      expect(state.locationPublisher.isSharingRequested, isFalse);
      expect(state.locationPublisher.status, LocationShareStatus.off);
    });

    test('a seeded build publishes to memory, never to a hosted function', () {
      expect(state.repositories.isSupabaseBacked, isFalse);
      expect(state.seedLocations.published, isEmpty,
          reason: 'no test device ever handed the app a GPS fix');
    });
  });
}

extension on LocationFix {
  LocationFix copyAt(DateTime at) => LocationFix(
        latitude: latitude,
        longitude: longitude,
        readAt: at,
        accuracyMeters: accuracyMeters,
        headingDegrees: headingDegrees,
        speedKph: speedKph,
      );
}
