import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../data/db_models.dart';
import '../services/location_service.dart';
import '../theme/app_colors.dart';

/// Maps a mock-data `vehicle_type` / `marker_type` string to the icon shown
/// inside a SurGo purple pin, per `marker_config` in the Map V1 JSON.
IconData surgoMarkerIcon(String type) {
  switch (type) {
    case 'motorcycle':
      return Icons.two_wheeler;
    case 'tricycle':
      return Icons.electric_rickshaw;
    case 'van':
      return Icons.airport_shuttle;
    case 'multicab':
      return Icons.local_shipping_outlined;
    case 'rental':
      return Icons.directions_car_filled;
    case 'passenger':
      return Icons.person;
    case 'user_location':
      return Icons.my_location;
    default:
      return Icons.place;
  }
}

/// One tappable point on a [SurgoMap].
class SurgoMapMarker {
  final String id;
  final MapPoint position;
  final IconData icon;

  /// Bottom-sheet title, e.g. a rider's name or a vehicle's name.
  final String title;

  /// Short line under the title, e.g. "Motorcycle · Purok 2, Telaje".
  final String subtitle;

  /// Extra label/value rows shown in the info sheet (rating, fare, price,
  /// status, etc.) — kept generic so every marker type can supply whatever
  /// is relevant without needing its own sheet layout.
  final List<MapEntry<String, String>> details;

  /// Optional label + callback for a primary action button in the info
  /// sheet (e.g. "Book this ride", "Rent this vehicle"). Omit for markers
  /// that are informational only.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Slightly dims the marker (used for unavailable riders/vehicles).
  final bool faded;

  const SurgoMapMarker({
    required this.id,
    required this.position,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.details = const [],
    this.actionLabel,
    this.onAction,
    this.faded = false,
  });
}

/// SurGo's shared map surface: real OpenStreetMap tiles via `flutter_map`,
/// the device's live GPS as the "you are here" marker, and any number of
/// fixed mock markers (riders, rental vehicles, passengers) rendered as
/// custom purple filled location-pins with an icon inside.
///
/// This is Map V1: no routing, no ETA, no live tracking — just a real,
/// interactive, pannable/zoomable map with real GPS and tappable mock
/// markers. Used both as a small preview (fixed height, gestures disabled)
/// and as a full-screen live map (see PassengerMapScreen / RiderMapScreen /
/// VehicleOwnerMapScreen).
class SurgoMap extends StatefulWidget {
  final List<SurgoMapMarker> markers;

  /// If true, resolves the device's live GPS position on load and shows a
  /// "you are here" marker + a locate-me button. Falls back to
  /// [fallbackCenter] (Tandag City by default) if permission is denied.
  final bool showUserLocation;

  final MapPoint? fallbackCenter;
  final double initialZoom;

  /// When false, the map is a static, non-interactive preview (used inside
  /// cards) — panning/zooming/tapping markers is disabled.
  final bool interactive;

  final double height;
  final BorderRadius? borderRadius;

  const SurgoMap({
    super.key,
    required this.markers,
    this.showUserLocation = true,
    this.fallbackCenter,
    this.initialZoom = 15,
    this.interactive = true,
    this.height = 260,
    this.borderRadius,
  });

  @override
  State<SurgoMap> createState() => _SurgoMapState();
}

class _SurgoMapState extends State<SurgoMap> {
  final MapController _mapController = MapController();
  MapPoint? _userPosition;
  bool _locating = false;
  bool _deniedOnce = false;

  @override
  void initState() {
    super.initState();
    if (widget.showUserLocation) _resolveUserLocation(recenter: false);
  }

  Future<void> _resolveUserLocation({bool recenter = true}) async {
    setState(() => _locating = true);
    final point = await LocationService.instance.getCurrentLocation();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (point != null) {
        _userPosition = point;
      } else {
        _deniedOnce = true;
      }
    });
    if (point != null && recenter) {
      _mapController.move(ll.LatLng(point.latitude, point.longitude), widget.initialZoom);
    }
  }

  MapPoint get _fallback => widget.fallbackCenter ?? const MapPoint(9.0785, 126.1985);

  @override
  Widget build(BuildContext context) {
    final center = _userPosition ?? _fallback;
    final radius = widget.borderRadius ?? BorderRadius.circular(18);

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: ll.LatLng(center.latitude, center.longitude),
                initialZoom: widget.initialZoom,
                interactionOptions: InteractionOptions(
                  flags: widget.interactive
                      ? InteractiveFlag.all
                      : InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.surgo',
                  maxNativeZoom: 19,
                ),
                MarkerLayer(
                  markers: [
                    for (final m in widget.markers)
                      Marker(
                        point: ll.LatLng(m.position.latitude, m.position.longitude),
                        width: 42,
                        height: 48,
                        alignment: Alignment.topCenter,
                        child: GestureDetector(
                          onTap: widget.interactive ? () => _showMarkerSheet(context, m) : null,
                          child: _SurgoPin(icon: m.icon, faded: m.faded),
                        ),
                      ),
                    if (_userPosition != null)
                      Marker(
                        point: ll.LatLng(_userPosition!.latitude, _userPosition!.longitude),
                        width: 26,
                        height: 26,
                        child: const _UserDot(),
                      ),
                  ],
                ),
              ],
            ),
            // Attribution — required by OSM's tile usage policy.
            Positioned(
              left: 8,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '© OpenStreetMap',
                  style: TextStyle(color: Colors.white70, fontSize: 9),
                ),
              ),
            ),
            if (widget.showUserLocation && widget.interactive)
              Positioned(
                right: 10,
                bottom: 10,
                child: _LocateMeButton(
                  locating: _locating,
                  denied: _deniedOnce,
                  onTap: () => _resolveUserLocation(recenter: true),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showMarkerSheet(BuildContext context, SurgoMapMarker m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MarkerInfoSheet(marker: m),
    );
  }
}

/// Custom purple "filled location pin" marker with an icon inside —
/// matches the SurGo brand marker style used across every role's map.
class _SurgoPin extends StatelessWidget {
  final IconData icon;
  final bool faded;
  const _SurgoPin({required this.icon, required this.faded});

  @override
  Widget build(BuildContext context) {
    final color = faded ? AppColors.muted2 : AppColors.primary;
    return Opacity(
      opacity: faded ? 0.55 : 1,
      child: SizedBox(
        width: 42,
        height: 48,
        child: CustomPaint(
          painter: _PinPainter(color: color),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(
              child: Icon(icon, color: Colors.white, size: 18),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinPainter extends CustomPainter {
  final Color color;
  const _PinPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final r = w / 2;
    final center = Offset(r, r);

    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: r))
      ..moveTo(center.dx - r * 0.62, center.dy + r * 0.55)
      ..lineTo(center.dx, size.height)
      ..lineTo(center.dx + r * 0.62, center.dy + r * 0.55)
      ..close();

    canvas.drawShadow(path, Colors.black, 3, true);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawCircle(center, r, Paint()..color = color);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = AppColors.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _PinPainter oldDelegate) => oldDelegate.color != color;
}

/// The device's own live-GPS position — a small blue "you are here" dot,
/// distinct from the purple mock-transport pins.
class _UserDot extends StatelessWidget {
  const _UserDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF4A90E2).withValues(alpha: 0.25),
      ),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF4A90E2),
            border: Border.all(color: Colors.white, width: 2.5),
          ),
        ),
      ),
    );
  }
}

class _LocateMeButton extends StatelessWidget {
  final bool locating;
  final bool denied;
  final VoidCallback onTap;
  const _LocateMeButton({required this.locating, required this.denied, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.panel2,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: locating
            ? null
            : () {
                onTap();
                if (denied) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Location permission is off — enable it in system settings to center on you.'),
                    ),
                  );
                }
              },
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.borderLight),
          ),
          child: locating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryLight),
                )
              : const Icon(Icons.my_location, color: AppColors.primaryLight, size: 20),
        ),
      ),
    );
  }
}

class _MarkerInfoSheet extends StatelessWidget {
  final SurgoMapMarker marker;
  const _MarkerInfoSheet({required this.marker});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(marker.icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(marker.title,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(marker.subtitle,
                          style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            if (marker.details.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.panel2,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    for (final d in marker.details)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(d.key, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                            Text(d.value,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (marker.actionLabel != null && marker.onAction != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    marker.onAction!();
                  },
                  child: Text(marker.actionLabel!,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
