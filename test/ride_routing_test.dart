import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/services/geoapify_service.dart';
import 'package:surgo/services/ride_pricing.dart';

const a = MapPoint(9.07, 126.19);
const b = MapPoint(9.08, 126.20);
const c = MapPoint(9.09, 126.21);

Map<String, dynamic> response(double distance) => {
  'points': [
    {'latitude': a.latitude, 'longitude': a.longitude},
    {'latitude': b.latitude, 'longitude': b.longitude},
    {'latitude': c.latitude, 'longitude': c.longitude},
  ],
  'distanceMeters': distance,
  'durationSeconds': 360,
};

void main() {
  test(
    'road geometry and stats invalidate immediately; late responses ignored',
    () async {
      final pending = <Completer<Object?>>[];
      final routing = RideRouting(
        service: GeoapifyService(
          invoke: (name, body) {
            expect(name, 'geoapify');
            expect(body['mode'], 'drive');
            final completer = Completer<Object?>();
            pending.add(completer);
            return completer.future;
          },
        ),
      );
      addTearDown(routing.dispose);
      routing.sync(start: a, end: b, enabled: true);
      expect(routing.loading, isTrue);
      routing.sync(start: a, end: c, enabled: true);
      expect(pending, hasLength(2));
      pending[1].complete(response(2500));
      await Future<void>.delayed(Duration.zero);
      expect(routing.route!.distanceMeters, 2500);
      expect(routing.route!.points, hasLength(3));
      expect(routing.loading, isFalse);
      pending[0].complete(response(1000));
      await Future<void>.delayed(Duration.zero);
      expect(routing.route!.distanceMeters, 2500);
      routing.sync(start: null, end: c, enabled: true);
      expect(routing.route, isNull);
      expect(routing.loading, isFalse);
    },
  );

  test('mock mode makes no network calls and clears hosted route', () {
    var calls = 0;
    final routing = RideRouting(
      service: GeoapifyService(
        invoke: (_, body) async {
          calls++;
          return response(1000);
        },
      ),
    );
    addTearDown(routing.dispose);
    routing.sync(start: a, end: b, enabled: false);
    expect(calls, 0);
    expect(routing.route, isNull);
    routing.sync(
      start: a,
      end: b,
      enabled: true,
      seed: const GeoRoute(
        points: [a, b],
        distanceMeters: 1500,
        durationSeconds: 120,
      ),
    );
    expect(routing.route!.distanceMeters, 1500);
    expect(calls, 0);
    routing.sync(start: a, end: b, enabled: false);
    expect(routing.route, isNull);
  });

  test('failed routing stays explicit and retry recovers', () async {
    var calls = 0;
    final routing = RideRouting(
      service: GeoapifyService(
        invoke: (_, body) async {
          if (++calls == 1) throw RepositoryFailure.offline();
          return response(2000);
        },
      ),
    );
    addTearDown(routing.dispose);
    routing.sync(start: a, end: b, enabled: true);
    await Future<void>.delayed(Duration.zero);
    expect(routing.failure, isNotNull);
    expect(routing.route, isNull);
    expect(routing.loading, isFalse);
    routing.sync(start: a, end: b, enabled: true);
    expect(calls, 1);
    routing.sync(start: a, end: b, enabled: true, retry: true);
    await Future<void>.delayed(Duration.zero);
    expect(routing.failure, isNull);
    expect(routing.route!.distanceMeters, 2000);
  });

  test('disposal prevents a pending route notifying', () async {
    final pending = Completer<Object?>();
    final routing = RideRouting(
      service: GeoapifyService(invoke: (_, body) => pending.future),
    );
    var updates = 0;
    routing.addListener(() => updates++);
    routing.sync(start: a, end: b, enabled: true);
    routing.dispose();
    pending.complete(response(1000));
    await Future<void>.delayed(Duration.zero);
    expect(updates, 1);
  });

  test('road distance retains honest provenance and additive platform fee', () {
    const distance = TripDistance(
      kilometres: 4,
      source: DistanceSource.roadRoute,
    );
    final price = RidePricing.price(providerFare: 4500, distance: distance);
    expect(distance.label, '4.0 km by road');
    expect(distance.caveat, contains('Geoapify'));
    expect(price.providerFare, 4500);
    expect(price.platformFee, 800);
    expect(price.customerTotal, 5300);
  });
}
