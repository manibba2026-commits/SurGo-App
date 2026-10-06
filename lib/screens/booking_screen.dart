import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/location_picker.dart';
import '../widgets/surgo_map.dart';

class BookingScreen extends StatelessWidget {
  const BookingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final db = DbService.instance;
    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return Column(
            children: [
              Stack(
                children: [
                  SurgoMap(
                    height: MediaQuery.of(context).size.height * 0.36,
                    borderRadius: BorderRadius.zero,
                    fallbackCenter: db.mapConfig.defaultCenter,
                    initialZoom: db.mapConfig.defaultZoom,
                    markers: const [],
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: SafeArea(
                      bottom: false,
                      child: SbIconButton(
                        icon: Icons.arrow_back,
                        onTap: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  children: [
                    SbField(
                      label: 'Pickup',
                      value: state.pickupLabel,
                      leading: const _Dot(color: AppColors.secondary, square: false),
                      onTap: () async {
                        final picked = await showLocationPicker(context, title: 'Set pickup location');
                        if (picked != null) state.setPickup(picked);
                      },
                    ),
                    const SizedBox(height: 8),
                    SbField(
                      label: 'Destination',
                      value: state.destinationLabel,
                      leading: const _Dot(color: AppColors.primary, square: true),
                      onTap: () async {
                        final picked = await showLocationPicker(context, title: 'Set destination');
                        if (picked != null) state.setDestination(picked);
                      },
                    ),
                    const SizedBox(height: 20),
                    const Text('Choose a vehicle',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppColors.muted)),
                    const SizedBox(height: 10),
                    ..._buildRideOptions(state),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Est. distance '
                          '${state.estimatedDistanceKm.toStringAsFixed(1)} km',
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12)),
                        Text(
                            'Est. time ${state.selectedRide.etaMinutes} min',
                            style: const TextStyle(
                                color: AppColors.muted, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SbPrimaryButton(
                      label: 'Find Ride · ${Money.format(state.selectedRide.fare)}',
                      // Creates the request first, then matches it. Navigating on
                      // its own would leave the matching screen with nothing to
                      // match against, and no trace of the trip afterwards.
                      onPressed: () {
                        state.createRideRequest();
                        Navigator.pushNamed(context, '/matching');
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildRideOptions(AppState state) {
    return state.rideOptions.map((option) {
      final selected = option.name == state.selectedRide.name;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SbCard(
          borderColor: selected ? AppColors.primary : null,
          onTap: () => state.selectRide(option),
          child: Row(
            children: [
              Icon(option.icon,
                  size: 26, color: selected ? AppColors.primaryLight : AppColors.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.name,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    Text('${option.etaLabel} · ${option.capacityLabel}',
                        style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                  ],
                ),
              ),
              Text(Money.format(option.fare), style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      );
    }).toList();
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final bool square;
  const _Dot({required this.color, required this.square});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square ? BorderRadius.circular(2) : null,
      ),
    );
  }
}
