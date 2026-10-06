import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../services/money.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';

/// Rider-side Map V1: real OpenStreetMap centered on the rider's live GPS,
/// with fixed mock passengers and their incoming ride requests shown as
/// tappable purple pins. Reachable from the Rider Home tab's map icon.
///
/// This is a read-only preview of nearby demand — accepting/declining a
/// real request still happens on the Home tab's request list (Map V1 keeps
/// the two mock datasets — visualization vs. the accept/decline flow —
/// separate rather than faking a link between unrelated mock IDs).
class EarnerMapScreen extends StatelessWidget {
  const EarnerMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final db = DbService.instance;
    final requestsByPassenger = {for (final r in db.mapRideRequests) r.passengerId: r};

    final markers = db.mapPassengers.map((p) {
      final MapRideRequest? req = requestsByPassenger[p.id];
      return SurgoMapMarker(
        id: p.id,
        position: p.position,
        icon: surgoMarkerIcon('passenger'),
        title: p.name,
        subtitle: '${p.purok}, ${p.barangay}',
        details: [
          MapEntry('Rating', '⭐ ${p.rating.toStringAsFixed(1)}'),
          if (req != null) ...[
            MapEntry('Wants', _titleCase(req.preferredVehicleType)),
            MapEntry('Distance', '${req.estimatedDistanceKm.toStringAsFixed(1)} km'),
            MapEntry('Est. fare', Money.format(req.estimatedFare)),
            MapEntry('Drop-off', '${req.destinationPurok}, ${req.destinationBarangay}'),
            MapEntry('Payment', _titleCase(req.paymentMethod)),
          ] else
            const MapEntry('Status', 'No active request'),
        ],
        actionLabel: req != null ? 'View in Requests' : null,
        onAction: req != null ? () => Navigator.pop(context) : null,
      );
    }).toList();

    return Scaffold(
      body: Stack(
        children: [
          SurgoMap(
            markers: markers,
            fallbackCenter: db.mapConfig.defaultCenter,
            initialZoom: db.mapConfig.defaultZoom,
            height: MediaQuery.of(context).size.height,
            borderRadius: BorderRadius.zero,
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(
                children: [
                  SbIconButton(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.panel.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        '${db.mapPassengers.length} nearby passengers',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _titleCase(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
