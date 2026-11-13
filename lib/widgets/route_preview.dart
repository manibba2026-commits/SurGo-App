import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../theme/app_colors.dart';
import 'surgo_map.dart';

/// A compact, non-interactive map that shows the route for an active booking.
///
/// The full-screen maps use the same [SurgoMap] surface. This wrapper exists so
/// every active card — ride, rental, or Pasuyo — renders the found state the
/// same way: a green line between the two real coordinates, with the same
/// estimate/real-route distinction as the main map.
class SbRoutePreview extends StatelessWidget {
  const SbRoutePreview({
    super.key,
    required this.start,
    required this.end,
    this.route = const [],
    this.height = 136,
    this.startLabel = 'Pickup',
    this.endLabel = 'Drop-off',
    this.active = true,
  });

  final MapPoint start;
  final MapPoint end;

  /// Road geometry from [RideRouting]. When empty, the map draws a straight
  /// line and marks it as an estimate.
  final List<MapPoint> route;
  final double height;
  final String startLabel;
  final String endLabel;

  /// Active bookings are green. Kept configurable so a screen can preview a
  /// request before a provider has actually been found.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.success : AppColors.primary;
    final points = route.length >= 2 ? route : [start, end];
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SurgoMap(
        height: height,
        borderRadius: BorderRadius.circular(14),
        interactive: false,
        showUserLocation: false,
        initialZoom: 13.5,
        cameraPadding: const EdgeInsets.fromLTRB(18, 26, 18, 26),
        route: points,
        routeIsEstimate: route.length < 2,
        routeColor: color,
        markers: [
          SurgoMapMarker(
            id: 'route-start',
            position: start,
            icon: Icons.trip_origin,
            title: startLabel,
            subtitle: 'Pickup point',
            color: color,
          ),
          SurgoMapMarker(
            id: 'route-end',
            position: end,
            icon: Icons.place,
            title: endLabel,
            subtitle: 'Destination',
            color: color,
          ),
        ],
      ),
    );
  }
}
