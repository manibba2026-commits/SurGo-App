import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/location_picker.dart';
import '../widgets/surfaces.dart';
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
                    _priceBreakdown(state),
                    const SizedBox(height: 14),
                    SbPrimaryButton(
                      label: 'Find Ride · ${state.bookingPrice.customerTotalLabel}',
                      icon: Icons.electric_rickshaw_rounded,
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

  /// The itemised ride price the passenger is agreeing to.
  ///
  /// The distance is a mock estimate (straight line between two seeded places)
  /// because this build has no routing engine; [TripDistance.caveat] says so
  /// next to the number. The platform fee is charged on top of the provider
  /// fare, and the provider keeps the whole fare.
  Widget _priceBreakdown(AppState state) {
    final price = state.bookingPrice;
    final distance = price.distance;
    return SbTintedCard(
      tone: SbTone.ride,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SbToneIcon(
                tone: SbTone.ride,
                icon: Icons.route_outlined,
                size: 32,
                iconSize: 16,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Fare breakdown',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
              ),
              Text(
                '${state.selectedRide.etaMinutes} min away',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _PriceRow(label: 'Provider fare', value: price.providerFareLabel),
          _PriceRow(
            label: 'Estimated distance',
            value: distance.label,
            note: distance.caveat,
          ),
          _PriceRow(
            label: 'SurGo platform fee',
            value: price.platformFeeLabel,
          ),
          const SizedBox(height: 6),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 8),
          _PriceRow(
            label: 'Total customer payment',
            value: price.customerTotalLabel,
            bold: true,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRideOptions(AppState state) {
    return state.rideOptions.map((option) {
      final selected = option.name == state.selectedRide.name;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SbTintedCard(
          tone: selected ? SbTone.ride : SbTone.neutral,
          wash: selected,
          borderColor: selected ? null : AppColors.border,
          onTap: () => state.selectRide(option),
          child: Row(
            children: [
              if (selected)
                const SbToneIcon(
                  tone: SbTone.ride,
                  icon: Icons.electric_rickshaw_rounded,
                  size: 34,
                  iconSize: 17,
                )
              else
                SizedBox(
                  width: 34,
                  height: 34,
                  child: Icon(option.icon,
                      size: 24, color: AppColors.muted),
                ),
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

class _PriceRow extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final bool bold;

  const _PriceRow({
    required this.label,
    required this.value,
    this.note,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                    color: bold ? AppColors.text : AppColors.muted,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: AppColors.muted2,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: bold ? 14 : 12.5,
              fontWeight: FontWeight.w800,
              color: bold ? AppColors.yellow : AppColors.text,
            ),
          ),
        ],
      ),
    );
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
