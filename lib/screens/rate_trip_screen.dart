import 'package:flutter/material.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class RateTripScreen extends StatelessWidget {
  const RateTripScreen({super.key});

  static const compliments = [
    'Safe driving',
    'Clean vehicle',
    'On time',
    'Friendly'
  ];

  Widget _receiptRow(String label, String value, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                  fontSize: bold ? 14 : 12.5,
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              // The trip was settled before this screen opened, so the rider,
              // fare and route come from that receipt rather than from
              // MockData or the booking draft.
              final ride = state.lastCompletedRide;
              final driver = state.lastCompletedRideDriver;
              if (ride == null || driver == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No completed trip to rate yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                );
              }

              final isFavorite = state.isFavoriteRiderName(driver.name);
              final isEarner = state.mode == UserMode.earner;
              final routeParts = ride.route.split('→');
              final pickup = routeParts.first.trim();
              final dropoff = routeParts.length > 1
                  ? routeParts.sublist(1).join('→').trim()
                  : '—';
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SbAvatar(initials: driver.initials, size: 60),
                        Positioned(
                          right: -13,
                          bottom: -13,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => state.toggleFavoriteRiderByDriver(
                              name: driver.name,
                              initials: driver.initials,
                              rating: driver.rating,
                              trips: driver.trips,
                              vehicleType: driver.vehicleType,
                              plate: driver.plate,
                            ),
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: Center(
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppColors.panel,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: AppColors.border, width: 1.5),
                                  ),
                                  child: Icon(
                                    isFavorite
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    size: 14,
                                    color: isFavorite
                                        ? AppColors.primary
                                        : AppColors.muted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                        'How was your trip with ${driver.name.split(' ').first}?',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(
                      '${driver.vehicleType} · provider fare ${Money.format(ride.fare)}',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5),
                    ),
                    const SizedBox(height: 16),
                    SbCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Trip receipt',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              SbTag(ride.status, secondary: true),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ride.date,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _receiptRow('Pick-up', pickup),
                          _receiptRow('Destination', dropoff),
                          _receiptRow('Rider', driver.name),
                          _receiptRow('Payment', 'Cash'),
                          const Divider(height: 20, color: AppColors.border),
                          if (state.lastRideBreakdown != null) ...[
                            _receiptRow(
                              isEarner
                                  ? 'Your payout · 100% fare'
                                  : 'Rider receives · 100% fare',
                              state.lastRideBreakdown!.providerGetsLabel,
                            ),
                            _receiptRow(
                              'SurGo platform fee',
                              state.lastRideBreakdown!.surgoKeepsLabel,
                            ),
                            _receiptRow(
                              isEarner
                                  ? 'Customer pays · Cash'
                                  : 'You paid · Cash',
                              state.lastRideBreakdown!.customerPaysLabel,
                              bold: true,
                            ),
                          ] else
                            _receiptRow(
                              isEarner ? 'Your payout' : 'You paid · Cash',
                              Money.format(ride.fare),
                              bold: true,
                            ),
                          const SizedBox(height: 4),
                          const Text(
                            'Cash changes hands on the trip; SurGo does not hold the money.',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isFavorite
                          ? 'Added to your favorite riders'
                          : 'Tap the heart to save as a favorite rider',
                      style:
                          const TextStyle(color: AppColors.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) {
                        final filled = i < state.tripRating;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 4),
                          child: GestureDetector(
                            onTap: () => state.setTripRating(i + 1),
                            child: Icon(
                              filled
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              size: 34,
                              color: filled
                                  ? AppColors.yellow
                                  : AppColors.borderLight,
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: compliments
                          .map((c) => SbChip(
                                c,
                                active: state.tripCompliments.contains(c),
                                onTap: () => state.toggleCompliment(c),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 26),
                    SbPrimaryButton(
                      label: 'Submit Rating',
                      foreground: Colors.white,
                      onPressed: () {
                        // completeActiveRide already wrote the history row; the
                        // rating updates it in place instead of adding a second.
                        state.rateCompletedRide(state.tripRating);
                        // reset for the next trip
                        state.setTripRating(4);
                        final home = isEarner ? '/earner' : '/home';
                        Navigator.pushNamedAndRemoveUntil(
                          context,
                          home,
                          (route) => route.settings.name == home,
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
