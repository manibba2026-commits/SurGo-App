import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/services/geoapify_service.dart';

void main() {
  test(
      'autocomplete uses the signed Edge Function contract, not a provider key',
      () async {
    final calls = <Map<String, Object?>>[];
    final service = GeoapifyService(invoke: (name, body) async {
      expect(name, 'geoapify');
      calls.add(body);
      return {
        'places': [
          {
            'id': 'place-1',
            'label': 'City Hall',
            'latitude': 9.08,
            'longitude': 126.2
          },
        ],
      };
    });
    final places = await service.autocomplete('  City  ');
    expect(calls.single, {'action': 'autocomplete', 'text': 'City'});
    expect(places.single.label, 'City Hall');
    expect(places.single.point.latitude, 9.08);
    expect(places.single.point.longitude, 126.2);
  });

  test('short queries never invoke the server', () async {
    final service =
        GeoapifyService(invoke: (_, _) async => fail('unexpected call'));
    expect(await service.autocomplete('a'), isEmpty);
    expect(await service.autocomplete(' '), isEmpty);
  });

  test('nearby places retain explicit latitude and longitude fields', () async {
    final service = GeoapifyService(invoke: (name, body) async {
      expect(name, 'geoapify');
      expect(body, {
        'action': 'places',
        'center': {'latitude': 9.08, 'longitude': 126.2},
        'categories': ['healthcare.pharmacy'],
        'radius': 3000,
      });
      return {'places': <Object>[]};
    });
    expect(
        await service.nearbyPlaces(
            center: const MapPoint(9.08, 126.2),
            category: 'healthcare.pharmacy'),
        isEmpty);
  });

  test('routes use provider distance and duration without inventing geometry',
      () async {
    final service = GeoapifyService(invoke: (name, body) async {
      expect(name, 'geoapify');
      expect(body, {
        'action': 'route',
        'start': {'latitude': 9.08, 'longitude': 126.2},
        'end': {'latitude': 9.09, 'longitude': 126.21},
        'mode': 'motorcycle',
      });
      return {
        'points': [
          {'latitude': 9.08, 'longitude': 126.2},
          {'latitude': 9.09, 'longitude': 126.21},
        ],
        'distanceMeters': 2200,
        'durationSeconds': 330,
      };
    });
    final route = await service.route(
        start: const MapPoint(9.08, 126.2),
        end: const MapPoint(9.09, 126.21),
        mode: 'motorcycle');
    expect(route.points, hasLength(2));
    expect(route.distanceMeters, 2200);
    expect(route.durationSeconds, 330);
  });

  test('malformed and out-of-range place responses are refused', () async {
    for (final value in [
      null,
      {'places': 'invalid'},
      {
        'places': [
          {'id': 'one', 'label': 'Test', 'latitude': 999, 'longitude': 126}
        ]
      },
      {
        'places': [
          {'id': '', 'label': 'Test', 'latitude': 9, 'longitude': 126}
        ]
      },
    ]) {
      final service = GeoapifyService(invoke: (_, _) async => value);
      await expectLater(
          service.autocomplete('City'), throwsA(isA<RepositoryFailure>()));
    }
  });

  test('missing routes are refused rather than replaced with a straight line',
      () async {
    final service = GeoapifyService(
        invoke: (_, _) async => {
              'points': <Object>[],
              'distanceMeters': 0,
              'durationSeconds': 0,
            });
    await expectLater(
        service.route(
            start: const MapPoint(9.08, 126.2),
            end: const MapPoint(9.09, 126.21)),
        throwsA(isA<RepositoryFailure>()));
  });

  test('server failures propagate without a synthetic successful response',
      () async {
    final failure = RepositoryFailure.unavailable();
    final service = GeoapifyService(invoke: (_, _) async => throw failure);
    await expectLater(service.autocomplete('City'), throwsA(same(failure)));
  });
}
