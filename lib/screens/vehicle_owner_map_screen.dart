import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';

/// Vehicle Owner Map V1: real OpenStreetMap centered on the owner's live
/// GPS, showing their listed rental vehicles as tappable purple pins.
/// Reachable from the Vehicle Owner Home tab's map icon.
class VehicleOwnerMapScreen extends StatelessWidget {
  const VehicleOwnerMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final db = DbService.instance;
    final ownerVehicles =
        db.mapRentalVehicles.where((v) => v.ownerId == db.vehicleOwner.id).toList();

    final markers = ownerVehicles
        .map((v) => SurgoMapMarker(
              id: v.id,
              position: v.position,
              icon: surgoMarkerIcon(v.markerType),
              title: v.name,
              subtitle: '${_titleCase(v.vehicleType)} · ${v.purok}, ${v.barangay}',
              faded: !v.available,
              details: [
                MapEntry('Per day', '₱${v.pricePerDay}'),
                MapEntry('Per hour', '₱${v.pricePerHour}'),
                MapEntry('Rating', '⭐ ${v.rating.toStringAsFixed(1)}'),
                MapEntry('Status', v.available ? 'Available' : 'Currently rented'),
              ],
              actionLabel: 'Manage Vehicle',
              onAction: () => Navigator.pop(context),
            ))
        .toList();

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
                        '${ownerVehicles.length} of your vehicles',
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
