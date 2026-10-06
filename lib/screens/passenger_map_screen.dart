import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../services/money.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';

/// Passenger-side Map V1: real OpenStreetMap centered on the user's live
/// GPS, with fixed mock riders (motorcycles/tricycles) and rental vehicles
/// shown as tappable purple pins. Reachable from the passenger Home tab's
/// map icon.
class PassengerMapScreen extends StatefulWidget {
  const PassengerMapScreen({super.key});

  @override
  State<PassengerMapScreen> createState() => _PassengerMapScreenState();
}

class _PassengerMapScreenState extends State<PassengerMapScreen> {
  String filter = 'All'; // All, Riders, Rentals

  @override
  Widget build(BuildContext context) {
    final db = DbService.instance;

    final riderMarkers = filter == 'Rentals'
        ? const <SurgoMapMarker>[]
        : db.mapRiders.map((r) => SurgoMapMarker(
              id: r.id,
              position: r.position,
              icon: surgoMarkerIcon(r.markerType),
              title: r.name,
              subtitle:
                  '${_titleCase(r.vehicleType)} · ${r.purok}, ${r.barangay}',
              faded: !r.available,
              details: [
                MapEntry('Vehicle', r.vehicleModel),
                MapEntry('Rating', '⭐ ${r.rating.toStringAsFixed(1)}'),
                MapEntry('Est. fare', Money.format(r.estimatedFare)),
                MapEntry('Status', r.available ? 'Available' : 'Offline'),
              ],
              actionLabel: r.available ? 'Book a Ride' : null,
              onAction: r.available
                  ? () => Navigator.pushNamed(context, '/booking')
                  : null,
            ));

    final rentalMarkers = filter == 'Riders'
        ? const <SurgoMapMarker>[]
        : db.mapRentalVehicles.map((v) => SurgoMapMarker(
              id: v.id,
              position: v.position,
              icon: surgoMarkerIcon(v.markerType),
              title: v.name,
              subtitle:
                  '${_titleCase(v.vehicleType)} · ${v.purok}, ${v.barangay}',
              faded: !v.available,
              details: [
                MapEntry('Per day', Money.format(v.pricePerDay)),
                MapEntry('Per hour', Money.format(v.pricePerHour)),
                MapEntry('Rating', '⭐ ${v.rating.toStringAsFixed(1)}'),
                MapEntry('Status', v.available ? 'Available' : 'Rented out'),
              ],
              actionLabel: v.available ? 'View Rentals' : null,
              onAction: v.available
                  ? () => Navigator.pushNamed(context, '/rental')
                  : null,
            ));

    final markers = [...riderMarkers, ...rentalMarkers];

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
                  SbIconButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: AppColors.panel.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            _filterChip('All'),
                            _filterChip('Riders'),
                            _filterChip('Rentals'),
                          ],
                        ),
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

  Widget _filterChip(String label) {
    final selected = filter == label;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => filter = label),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.onAccent : AppColors.muted,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }
}

String _titleCase(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
