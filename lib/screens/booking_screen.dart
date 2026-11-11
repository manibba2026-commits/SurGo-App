import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../repositories/repository_failure.dart';
import '../services/ride_pricing.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/flow_scaffold.dart';
import '../widgets/location_picker.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppState.instance.refreshBookingRoute();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final db = DbService.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SbFlowScaffold(
        title: 'Find rider',
        stateKey: 'booking',
        sheetFraction: 0.6,
        map: SurgoMap(
          height: MediaQuery.sizeOf(context).height,
          borderRadius: BorderRadius.zero,
          fallbackCenter:
              state.bookingPickup ??
              state.bookingDestination ??
              db.mapConfig.defaultCenter,
          initialZoom: db.mapConfig.defaultZoom,
          showUserLocation: false,
          cameraPadding: EdgeInsets.fromLTRB(
            24,
            80,
            24,
            MediaQuery.sizeOf(context).height * 0.6 + 20,
          ),
          routeIsEstimate: state.bookingRouting.route == null,
          route:
              state.bookingRouting.route?.points ??
              [
                if (state.bookingPickup != null &&
                    state.bookingDestination != null) ...[
                  state.bookingPickup!,
                  state.bookingDestination!,
                ],
              ],
          markers: [
            if (state.bookingPickup != null)
              SurgoMapMarker(
                id: 'pickup',
                position: state.bookingPickup!,
                icon: Icons.person_pin_circle_outlined,
                title: 'Pickup',
                subtitle: state.pickupLabel,
              ),
            if (state.bookingDestination != null)
              SurgoMapMarker(
                id: 'destination',
                position: state.bookingDestination!,
                icon: Icons.place_outlined,
                title: 'Destination',
                subtitle: state.destinationLabel,
                color: const Color(0xFFFFB84D),
              ),
          ],
        ),
        sheet: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                children: [
                  const Text(
                    'Where to today?',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  SbField(
                    label: 'Pickup',
                    value: state.pickupLabel,
                    leading: const _Dot(
                      color: AppColors.secondary,
                      square: false,
                    ),
                    onTap: () async {
                      final picked = await showRideLocationPicker(
                        context,
                        title: 'Set pickup location',
                      );
                      if (picked != null) {
                        state.setPickup(
                          picked.label,
                          coordinates: picked.point,
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  SbField(
                    label: 'Destination',
                    value: state.destinationLabel,
                    leading: const _Dot(color: Color(0xFFFFB84D), square: true),
                    onTap: () async {
                      final picked = await showRideLocationPicker(
                        context,
                        title: 'Set destination',
                      );
                      if (picked != null) {
                        state.setDestination(
                          picked.label,
                          coordinates: picked.point,
                        );
                      }
                    },
                  ),
                  if (!state.repositories.isSupabaseBacked) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final place in db.places.take(6))
                          ActionChip(
                            avatar: const Icon(Icons.place_outlined, size: 16),
                            label: Text(place.label),
                            onPressed: () => state.setDestination(place.label),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Choose your vehicle',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  for (final option in state.rideOptions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SbTintedCard(
                        tone: SbTone.ride,
                        wash: false,
                        borderColor: state.selectedRide.name == option.name
                            ? AppColors.primary
                            : AppColors.border,
                        onTap: _submitting
                            ? null
                            : () => state.selectRide(option),
                        child: Row(
                          children: [
                            SbToneIcon(
                              tone: SbTone.brand,
                              icon: option.icon,
                              size: 42,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    option.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${option.capacityLabel} · ${option.etaLabel}',
                                    style: const TextStyle(
                                      color: AppColors.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Text(
                                    '+ ${RidePricing.price(providerFare: option.fare, distance: state.bookingDistance).platformFeeLabel} SurGo fee',
                                    style: const TextStyle(
                                      color: AppColors.primaryLight,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              RidePricing.price(
                                providerFare: option.fare,
                                distance: state.bookingDistance,
                              ).providerFareLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  _priceBreakdown(state),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SbPrimaryButton(
                label: 'Find a Ride',
                foreground: Colors.white,
                icon: Icons.electric_rickshaw_rounded,
                feedback: _submitting
                    ? SbButtonFeedback.loading
                    : SbButtonFeedback.idle,
                onPressed: _submitting || state.bookingRouting.loading
                    ? null
                    : () => _submit(state),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit(AppState state) async {
    setState(() => _submitting = true);
    try {
      if (state.usesHostedRideDispatch) {
        await state.createHostedRideRequest();
      } else {
        state.createRideRequest();
      }
      if (!mounted) return;
      Navigator.pushNamed(context, '/matching');
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
        title: 'Request not sent',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

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
            ],
          ),
          const SizedBox(height: 10),
          if (state.bookingRouting.loading)
            const Text(
              'Finding road route…',
              style: TextStyle(color: AppColors.muted),
            ),
          if (state.bookingRouting.failure != null) ...[
            Text(
              'Road route unavailable. Showing a straight-line estimate. ${state.bookingRouting.failure!.message}',
              style: const TextStyle(color: AppColors.muted),
            ),
            TextButton(
              onPressed: () => state.refreshBookingRoute(retry: true),
              child: const Text('Retry road route'),
            ),
          ],
          if (state.bookingRouting.route != null)
            _PriceRow(
              label: 'Travel ETA',
              value: '${state.bookingTravelMinutes} min',
            ),
          _PriceRow(label: 'Provider fare', value: price.providerFareLabel),
          _PriceRow(
            label: state.bookingRouting.route == null
                ? 'Estimated distance'
                : 'Road distance',
            value: distance.label,
            note: distance.caveat,
          ),
          _PriceRow(label: 'SurGo platform fee', value: price.platformFeeLabel),
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
