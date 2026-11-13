import 'package:flutter/material.dart';
import '../repositories/backend_rows.dart';
import '../services/money.dart';
import '../services/vehicle_map_locations.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surgo_map.dart';

/// Vehicle Owner Map V1: the signed-in owner's fleet on the shared map.
///
/// A hosted fleet has no standing GPS position, so each vehicle is placed in a
/// stable barangay near the city centre and the sheet says the spot is an
/// approximate pickup area. The seeded demo keeps its authored coordinates.
class VehicleOwnerMapScreen extends StatelessWidget {
  const VehicleOwnerMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    if (state.usesHostedIdentity && state.repositories.isSupabaseBacked) {
      return RepositoryView<List<VehicleRecord>>(
        slot: DomainSlot.ownerFleet,
        empty: (_) => _frame(
          context,
          const [],
          message: 'No vehicles in your fleet yet',
        ),
        data: (context, records) => _frame(
          context,
          [
            for (final record in records)
              () {
                final location = approximateVehicleLocation(
                  record.id,
                  center: state.db.mapConfig.defaultCenter,
                  serviceAreaName: record.serviceAreaName,
                );
                return SurgoMapMarker(
                  id: record.id,
                  position: location.point,
                  icon: surgoMarkerIcon(record.vehicleType.toLowerCase()),
                  title: record.name,
                  subtitle:
                      '${record.vehicleType} · ${record.statusLabel} · ${location.barangay}',
                  details: [
                    MapEntry('Plate', record.plateNumber),
                    MapEntry('Per day', Money.format(record.pricePerDayCentavos)),
                    MapEntry('Rating', '⭐ ${record.rating.toStringAsFixed(1)}'),
                    MapEntry('Rentals', '${record.totalRentals}'),
                    MapEntry('Pickup', location.label),
                  ],
                  faded: !record.isListed,
                  actionLabel: 'Back to fleet',
                  onAction: () => Navigator.pop(context),
                );
              }(),
          ],
          message: '${records.length} vehicles in your fleet',
        ),
      );
    }
    final db = AppState.instance.db;
    final ownerVehicles = db.mapRentalVehicles
        .where((v) => v.ownerId == db.vehicleOwner.id)
        .toList();
    return _frame(
      context,
      [
        for (final v in ownerVehicles)
          SurgoMapMarker(
            id: v.id,
            position: v.position,
            icon: surgoMarkerIcon(v.markerType),
            title: v.name,
            subtitle: '${_titleCase(v.vehicleType)} · ${v.purok}, ${v.barangay}',
            faded: !v.available,
            details: [
              MapEntry('Per day', Money.format(v.pricePerDay)),
              MapEntry('Per hour', Money.format(v.pricePerHour)),
              MapEntry('Rating', '⭐ ${v.rating.toStringAsFixed(1)}'),
              MapEntry('Status', v.available ? 'Available' : 'Currently rented'),
            ],
            actionLabel: 'Manage Vehicle',
            onAction: () => Navigator.pop(context),
          ),
      ],
      message: '${ownerVehicles.length} of your vehicles',
    );
  }

  Widget _frame(
    BuildContext context,
    List<SurgoMapMarker> markers, {
    required String message,
  }) {
    final db = AppState.instance.db;
    return Scaffold(
      body: Stack(
        children: [
          SurgoMap(
            markers: markers,
            fallbackCenter: markers.isEmpty
                ? db.mapConfig.defaultCenter
                : markers.first.position,
            initialZoom: 14,
            height: MediaQuery.of(context).size.height,
            borderRadius: BorderRadius.zero,
            cameraPadding: const EdgeInsets.fromLTRB(20, 80, 20, 40),
          ),
          SbMapOverlay(
            child: SafeArea(
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
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.panel.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          message,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _titleCase(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
