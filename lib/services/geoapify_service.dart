import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/db_models.dart';
import '../repositories/edge_functions.dart';
import '../repositories/repository_failure.dart';

typedef GeoFunctionCall =
    Future<Object?> Function(String name, Map<String, Object?> body);

class GeoPlace {
  const GeoPlace({required this.id, required this.label, required this.point});

  final String id;
  final String label;
  final MapPoint point;
}

class GeoRoute {
  const GeoRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<MapPoint> points;
  final double distanceMeters;
  final double durationSeconds;
}

class GeoapifyService {
  GeoapifyService({GeoFunctionCall? invoke})
    : _invoke = invoke ?? _invokeHosted;

  final GeoFunctionCall _invoke;

  /// The Tandag pilot area. The deployed function currently biases only to the
  /// Philippines, so suggestions are also clipped here; local barangay and
  /// landmark matches are unaffected.
  static const serviceAreaSouth = 8.95;
  static const serviceAreaNorth = 9.25;
  static const serviceAreaWest = 125.95;
  static const serviceAreaEast = 126.35;

  static Future<Object?> _invokeHosted(
    String name,
    Map<String, Object?> body,
  ) async {
    try {
      final response = await Supabase.instance.client.functions
          .invoke(name, body: body)
          .timeout(const Duration(seconds: 10));
      return response.data;
    } catch (error) {
      throw mapEdgeError(error);
    }
  }

  Future<List<GeoPlace>> autocomplete(String text) async {
    if (text.trim().length < 2) return const [];
    final places = _places(
      await _invoke('geoapify', {
        'action': 'autocomplete',
        'text': text.trim(),
      }),
    );
    return List.unmodifiable(places.where(_insideServiceArea));
  }

  static bool _insideServiceArea(GeoPlace place) {
    final point = place.point;
    return point.latitude >= serviceAreaSouth &&
        point.latitude <= serviceAreaNorth &&
        point.longitude >= serviceAreaWest &&
        point.longitude <= serviceAreaEast;
  }

  Future<List<GeoPlace>> nearbyPlaces({
    required MapPoint center,
    required String category,
  }) async => _places(
    await _invoke('geoapify', {
      'action': 'places',
      'center': _coordinates(center),
      'categories': [category],
      'radius': 3000,
    }),
  );

  /// The street address nearest [point], used when the user drops a pin on
  /// the map instead of typing. Returns null when the provider has no match
  /// for that spot (open water, a new road), so callers can fall back to a
  /// coordinate label.
  Future<GeoPlace?> reverseGeocode(MapPoint point) async {
    final places = _places(
      await _invoke('geoapify', {
        'action': 'reverse',
        'point': _coordinates(point),
      }),
    );
    return places.isEmpty ? null : places.first;
  }

  Future<GeoRoute> route({
    required MapPoint start,
    required MapPoint end,
    String mode = 'drive',
  }) async {
    final data = _record(
      await _invoke('geoapify', {
        'action': 'route',
        'start': _coordinates(start),
        'end': _coordinates(end),
        'mode': mode,
      }),
    );
    final points = data['points'];
    final distance = data['distanceMeters'];
    final duration = data['durationSeconds'];
    if (points is! List ||
        points.length < 2 ||
        distance is! num ||
        !distance.isFinite ||
        distance < 0 ||
        duration is! num ||
        !duration.isFinite ||
        duration < 0) {
      throw RepositoryFailure.invalidData('The route response is incomplete.');
    }
    return GeoRoute(
      points: List.unmodifiable(points.map((point) => _point(_record(point)))),
      distanceMeters: distance.toDouble(),
      durationSeconds: duration.toDouble(),
    );
  }

  static Map<String, Object?> _coordinates(MapPoint point) => {
    'latitude': point.latitude,
    'longitude': point.longitude,
  };

  static List<GeoPlace> _places(Object? value) {
    final rows = _record(value)['places'];
    if (rows is! List) {
      throw RepositoryFailure.invalidData('The place response is incomplete.');
    }
    return List.unmodifiable(
      rows.map((row) {
        final data = _record(row);
        final id = data['id'];
        final label = data['label'];
        if (id is! String || id.isEmpty || label is! String || label.isEmpty) {
          throw RepositoryFailure.invalidData(
            'A place response is incomplete.',
          );
        }
        return GeoPlace(id: id, label: label, point: _point(data));
      }),
    );
  }

  static Map<String, dynamic> _record(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw RepositoryFailure.invalidData('The location response is invalid.');
    }
    return value;
  }

  static MapPoint _point(Map<String, dynamic> value) {
    final latitude = value['latitude'];
    final longitude = value['longitude'];
    if (latitude is! num ||
        longitude is! num ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      throw RepositoryFailure.invalidData(
        'The location coordinates are invalid.',
      );
    }
    return MapPoint(latitude.toDouble(), longitude.toDouble());
  }
}

class RideRouting extends ChangeNotifier {
  RideRouting({GeoapifyService? service})
    : _service = service ?? GeoapifyService();

  final GeoapifyService _service;
  MapPoint? _start;
  MapPoint? _end;
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;
  GeoRoute? route;
  RepositoryFailure? failure;
  bool loading = false;

  void sync({
    required MapPoint? start,
    required MapPoint? end,
    required bool enabled,
    GeoRoute? seed,
    bool retry = false,
  }) {
    if (_disposed) return;
    if (!retry &&
        _same(_start, start) &&
        _same(_end, end) &&
        _enabled == enabled) {
      return;
    }
    _start = start;
    _end = end;
    _enabled = enabled;
    final generation = ++_generation;
    route = enabled ? seed : null;
    failure = null;
    loading = enabled && start != null && end != null && route == null;
    notifyListeners();
    if (loading) _load(start!, end!, generation);
  }

  Future<void> _load(MapPoint start, MapPoint end, int generation) async {
    try {
      final result = await _service.route(start: start, end: end);
      if (_disposed || generation != _generation) return;
      route = result;
    } on RepositoryFailure catch (error) {
      if (_disposed || generation != _generation) return;
      failure = error;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  static bool _same(MapPoint? a, MapPoint? b) =>
      a?.latitude == b?.latitude && a?.longitude == b?.longitude;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
