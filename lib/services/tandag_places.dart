import '../data/db_models.dart';

/// One real Tandag destination the picker can offer before the network
/// answers. Coordinates were geocoded against OpenStreetMap; barangay anchors
/// are the centroids used to place providers and rental vehicles on land.
class TandagPlace {
  const TandagPlace({
    required this.id,
    required this.name,
    required this.label,
    required this.barangay,
    required this.point,
    this.kind = TandagPlaceKind.landmark,
  });

  final String id;
  final String name;

  /// The full text handed back to the caller, e.g.
  /// "Tandag City Public Market · Dagocdoc".
  final String label;
  final String barangay;
  final MapPoint point;
  final TandagPlaceKind kind;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        barangay.toLowerCase().contains(q) ||
        label.toLowerCase().contains(q);
  }
}

enum TandagPlaceKind { landmark, barangay, transport, market, health, school, government }

/// The shared Tandag catalogue: 21 barangay anchors plus the establishments a
/// passenger actually names when booking ("Gaisano", "Capitol", "Airport").
class TandagPlaces {
  TandagPlaces._();

  /// City-centre bias for maps and search.
  static const center = MapPoint(9.0785, 126.1985);

  /// Anchors are kept inland of the Tandag coastline (which runs near
  /// longitude 126.20 at the city centre) so simulated providers never sit in
  /// the sea. Names match `public.barangays` exactly.
  static const Map<String, MapPoint> barangayAnchors = {
    'Awasian': MapPoint(9.0912, 126.1810),
    'Bagong Lungsod (Poblacion)': MapPoint(9.0780, 126.1950),
    'Bioto': MapPoint(9.0702, 126.1794),
    'Bongtod Poblacion (East West)': MapPoint(9.0824, 126.1963),
    'Buenavista': MapPoint(9.1160, 126.1580),
    'Dagocdoc (Poblacion)': MapPoint(9.0745, 126.1935),
    'Mabua': MapPoint(9.0702, 126.2010),
    'Mabuhay': MapPoint(9.0046, 126.1263),
    'Maitum': MapPoint(9.0480, 126.1316),
    'Maticdum': MapPoint(9.0285, 126.1523),
    'Pandanon': MapPoint(9.0524, 126.1394),
    'Pangi': MapPoint(9.1020, 126.1539),
    'Quezon': MapPoint(9.0775, 126.1975),
    'Rosario': MapPoint(9.0580, 126.1850),
    'Salvacion': MapPoint(9.1078, 126.1566),
    'San Agustin Norte': MapPoint(9.0943, 126.1611),
    'San Agustin Sur': MapPoint(9.0700, 126.1900),
    'San Antonio': MapPoint(9.1356, 126.1643),
    'San Isidro': MapPoint(9.0330, 126.1680),
    'San Jose': MapPoint(9.0506, 126.1796),
    'Telaje': MapPoint(9.0600, 126.1930),
  };

  static final List<TandagPlace> all = [
    for (final entry in barangayAnchors.entries)
      TandagPlace(
        id: 'barangay-${_slug(entry.key)}',
        name: 'Barangay ${_shortBarangay(entry.key)}',
        label: 'Barangay ${_shortBarangay(entry.key)}, Tandag City',
        barangay: entry.key,
        point: entry.value,
        kind: TandagPlaceKind.barangay,
      ),
    const TandagPlace(
      id: 'plaza',
      name: 'Tandag City Plaza',
      label: 'Tandag City Plaza · Bongtod Poblacion',
      barangay: 'Bongtod Poblacion (East West)',
      point: MapPoint(9.079855, 126.197675),
    ),
    const TandagPlace(
      id: 'market',
      name: 'Tandag City Public Market',
      label: 'Tandag City Public Market · Dagocdoc',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.074659, 126.196658),
      kind: TandagPlaceKind.market,
    ),
    const TandagPlace(
      id: 'gaisano',
      name: 'Gaisano Capital Tandag',
      label: 'Gaisano Capital Tandag · Dagocdoc',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.076029, 126.198528),
      kind: TandagPlaceKind.market,
    ),
    const TandagPlace(
      id: 'city-hall',
      name: 'Tandag City Hall',
      label: 'Tandag City Hall · Dagocdoc',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.073239, 126.168932),
      kind: TandagPlaceKind.government,
    ),
    const TandagPlace(
      id: 'capitol',
      name: 'Surigao del Sur Provincial Capitol',
      label: 'Provincial Capitol · Telaje',
      barangay: 'Telaje',
      point: MapPoint(9.069279, 126.192555),
      kind: TandagPlaceKind.government,
    ),
    const TandagPlace(
      id: 'health-office',
      name: 'Tandag City Health Office',
      label: 'Tandag City Health Office · Dagocdoc',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.078869, 126.197961),
      kind: TandagPlaceKind.health,
    ),
    const TandagPlace(
      id: 'diagnostic-center',
      name: 'Tandag Diagnostic Center',
      label: 'Tandag Diagnostic Center · Draga',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.080546, 126.196138),
      kind: TandagPlaceKind.health,
    ),
    const TandagPlace(
      id: 'hospital',
      name: 'Adela Serra Ty Memorial Medical Center',
      label: 'Adela Serra Ty Memorial Medical Center · Telaje',
      barangay: 'Telaje',
      point: MapPoint(9.068821, 126.190283),
      kind: TandagPlaceKind.health,
    ),
    const TandagPlace(
      id: 'cathedral',
      name: 'San Nicolas de Tolentino Cathedral',
      label: 'San Nicolas de Tolentino Cathedral · Telaje',
      barangay: 'Telaje',
      point: MapPoint(9.044291, 126.212238),
    ),
    const TandagPlace(
      id: 'nemsu',
      name: 'North Eastern Mindanao State University',
      label: 'NEMSU Main Campus · Telaje',
      barangay: 'Telaje',
      point: MapPoint(9.038551, 126.215115),
      kind: TandagPlaceKind.school,
    ),
    const TandagPlace(
      id: 'stc',
      name: 'Saint Theresa College',
      label: 'Saint Theresa College · Dagocdoc',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.079335, 126.197030),
      kind: TandagPlaceKind.school,
    ),
    const TandagPlace(
      id: 'jpelpa',
      name: 'Jacinto P. Elpa National High School',
      label: 'JP Elpa National High School · Telaje',
      barangay: 'Telaje',
      point: MapPoint(9.067444, 126.193348),
      kind: TandagPlaceKind.school,
    ),
    const TandagPlace(
      id: 'central-elementary',
      name: 'Tandag Central Elementary School',
      label: 'Tandag Central Elementary School · Bagong Lungsod',
      barangay: 'Bagong Lungsod (Poblacion)',
      point: MapPoint(9.080089, 126.200527),
      kind: TandagPlaceKind.school,
    ),
    const TandagPlace(
      id: 'gymnasium',
      name: 'Tandag City Gymnasium',
      label: 'Tandag City Gymnasium · Bongtod',
      barangay: 'Bongtod Poblacion (East West)',
      point: MapPoint(9.080910, 126.196260),
    ),
    const TandagPlace(
      id: 'airport',
      name: 'Tandag Airport',
      label: 'Tandag Airport · Dagocdoc',
      barangay: 'Dagocdoc (Poblacion)',
      point: MapPoint(9.073085, 126.171217),
      kind: TandagPlaceKind.transport,
    ),
    const TandagPlace(
      id: 'seaport',
      name: 'Tandag City Sea Port',
      label: 'Tandag City Sea Port · Bongtod',
      barangay: 'Bongtod Poblacion (East West)',
      point: MapPoint(9.084274, 126.197084),
      kind: TandagPlaceKind.transport,
    ),
    const TandagPlace(
      id: 'boulevard',
      name: 'Tandag City Boulevard',
      label: 'Tandag Boulevard · Bongtod',
      barangay: 'Bongtod Poblacion (East West)',
      point: MapPoint(9.081200, 126.199100),
    ),
    const TandagPlace(
      id: 'agriculture',
      name: 'Provincial Agriculture Office',
      label: 'Provincial Agriculture Office · Telaje',
      barangay: 'Telaje',
      point: MapPoint(9.069419, 126.193961),
      kind: TandagPlaceKind.government,
    ),
  ];

  /// Popular destinations shown before the user types anything.
  static List<TandagPlace> get suggestions => [
    for (final id in const [
      'market',
      'plaza',
      'gaisano',
      'capitol',
      'city-hall',
      'hospital',
      'airport',
      'seaport',
    ])
      all.firstWhere((place) => place.id == id),
  ];

  static TandagPlace byId(String id) =>
      all.firstWhere((place) => place.id == id);

  static List<TandagPlace> search(String query, {int limit = 8}) {
    final q = query.trim();
    if (q.isEmpty) return suggestions.take(limit).toList();
    final matches = all.where((place) => place.matches(q)).toList()
      ..sort((a, b) {
        final aStarts = a.name.toLowerCase().startsWith(q.toLowerCase()) ? 0 : 1;
        final bStarts = b.name.toLowerCase().startsWith(q.toLowerCase()) ? 0 : 1;
        if (aStarts != bStarts) return aStarts.compareTo(bStarts);
        return a.name.compareTo(b.name);
      });
    return matches.take(limit).toList();
  }

  /// The barangay whose anchor is closest to [point]. Used to pre-select the
  /// service area after an address search or a dropped pin.
  static String? nearestBarangay(MapPoint point) {
    String? best;
    var bestDistance = double.infinity;
    for (final entry in barangayAnchors.entries) {
      final distance = _distance(point, entry.value);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry.key;
      }
    }
    return best;
  }

  /// The nearest catalogued place, for a readable label when reverse
  /// geocoding is unavailable (offline demo builds).
  static TandagPlace? nearestPlace(MapPoint point) {
    TandagPlace? best;
    var bestDistance = double.infinity;
    for (final place in all) {
      final distance = _distance(point, place.point);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = place;
      }
    }
    return best;
  }

  static double _distance(MapPoint a, MapPoint b) {
    final dLat = a.latitude - b.latitude;
    final dLon = a.longitude - b.longitude;
    return dLat * dLat + dLon * dLon;
  }

  static String _shortBarangay(String name) => name
      .replaceAll(' (Poblacion)', '')
      .replaceAll(' Poblacion (East West)', ' Poblacion');

  static String _slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}
