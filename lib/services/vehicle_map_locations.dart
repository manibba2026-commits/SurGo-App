import '../data/db_models.dart';

/// A listing's approximate pickup area.
///
/// The hosted schema stores a vehicle's service area but not a standing
/// position, and a rental is handed over at an agreed spot rather than tracked
/// all day. The map therefore places each listing in a stable spot around the
/// configured service-area centre and labels it as approximate — never as live
/// GPS. The centre comes from the map config or the hosted service area, not a
/// bundled barangay list.
class VehicleMapLocation {
  const VehicleMapLocation({
    required this.point,
    required this.barangay,
  });

  final MapPoint point;
  final String barangay;

  String get label => 'Approx. area · $barangay';
}

/// Stable, repeatable placement: the same vehicle id always lands on the same
/// spot, so pins do not jump between screenshots or rebuilds.
VehicleMapLocation approximateVehicleLocation(
  String vehicleId, {
  required MapPoint center,
  String? serviceAreaName,
}) {
  var hash = 0;
  for (final unit in vehicleId.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  // ±0.0018° is roughly 200 m: enough to separate neighbouring pins while
  // keeping every coordinate near the configured service area.
  final latitude = center.latitude + ((hash >> 5) % 37 - 18) / 10000;
  final longitude = center.longitude + ((hash >> 11) % 37 - 18) / 10000;
  final area = serviceAreaName?.trim();
  return VehicleMapLocation(
    point: MapPoint(latitude, longitude),
    barangay: area == null || area.isEmpty ? 'Service area' : area,
  );
}
