import 'dart:math' as math;

import '../data/db_models.dart';

/// Great-circle distance between two [MapPoint]s, in kilometres.
///
/// Uses the haversine formula on a spherical earth, which is accurate to well
/// under a percent over the few kilometres a city ride covers.
double haversineKm(MapPoint a, MapPoint b) {
  const earthRadiusKm = 6371.0;

  final lat1 = _radians(a.latitude);
  final lat2 = _radians(b.latitude);
  final dLat = _radians(b.latitude - a.latitude);
  final dLon = _radians(b.longitude - a.longitude);

  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);

  // 2 * R * asin(sqrt(h)): clamped because floating point can push h a hair
  // above 1 for antipodal points, which would make asin return NaN.
  final clamped = h.clamp(0.0, 1.0);
  return 2 * earthRadiusKm * math.asin(math.sqrt(clamped));
}

double _radians(double degrees) => degrees * math.pi / 180.0;