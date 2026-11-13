import '../data/db_models.dart';
import 'tandag_places.dart';

/// A listing's approximate pickup area.
///
/// The hosted schema stores a vehicle's service area but not a standing
/// position, and a rental is handed over at an agreed spot rather than tracked
/// all day. The map therefore places each listing in a stable barangay near
/// the city centre and labels it as approximate — never as live GPS.
class VehicleMapLocation {
  const VehicleMapLocation({
    required this.point,
    required this.barangay,
  });

  final MapPoint point;
  final String barangay;

  String get label => 'Approx. area · $barangay, Tandag City';
}

/// Stable, repeatable placement: the same vehicle id always lands on the same
/// spot, so pins do not jump between screenshots or rebuilds.
VehicleMapLocation approximateVehicleLocation(String vehicleId) {
  const anchors = [
    'Bongtod Poblacion (East West)',
    'Dagocdoc (Poblacion)',
    'Bagong Lungsod (Poblacion)',
    'Telaje',
    'San Agustin Sur',
    'Quezon',
    'San Jose',
    'Bioto',
  ];
  var hash = 0;
  for (final unit in vehicleId.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final anchorName = anchors[hash % anchors.length];
  final anchor = TandagPlaces.barangayAnchors[anchorName]!;
  // ±0.0018° is roughly 200 m: enough to separate neighbouring pins while
  // keeping every coordinate on land and inside the service area.
  final latitude = anchor.latitude + ((hash >> 5) % 37 - 18) / 10000;
  final longitude = anchor.longitude + ((hash >> 11) % 37 - 18) / 10000;
  return VehicleMapLocation(
    point: MapPoint(latitude, longitude),
    barangay: anchorName
        .replaceAll(' (Poblacion)', '')
        .replaceAll(' Poblacion (East West)', ' Poblacion'),
  );
}
