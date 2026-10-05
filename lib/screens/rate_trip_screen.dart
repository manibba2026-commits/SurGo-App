import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class RateTripScreen extends StatelessWidget {
  const RateTripScreen({super.key});

  static const compliments = ['Safe driving', 'Clean vehicle', 'On time', 'Friendly'];

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final driver = MockData.matchedDriver;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final isFavorite = state.isFavoriteRiderName(driver.name);
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SbAvatar(initials: driver.initials, size: 60),
                        Positioned(
                          right: -6,
                          bottom: -6,
                          child: GestureDetector(
                            onTap: () => state.toggleFavoriteRiderByDriver(
                              name: driver.name,
                              initials: driver.initials,
                              rating: driver.rating,
                              trips: driver.trips,
                              vehicleType: driver.vehicleType,
                              plate: driver.plate,
                            ),
                            child: Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.panel,
                                shape: BoxShape.circle,
                                border: Border.all(color: AppColors.border, width: 1.5),
                              ),
                              child: Icon(
                                isFavorite ? Icons.favorite : Icons.favorite_border,
                                size: 14,
                                color: isFavorite ? AppColors.primary : AppColors.muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('How was your trip with ${driver.name.split(' ').first}?',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(
                      isFavorite ? 'Added to your favorite riders' : 'Tap the heart to save as a favorite rider',
                      style: const TextStyle(color: AppColors.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) {
                        final filled = i < state.tripRating;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: GestureDetector(
                            onTap: () => state.setTripRating(i + 1),
                            child: Icon(
                              filled ? Icons.star_rounded : Icons.star_border_rounded,
                              size: 34,
                              color: filled ? AppColors.yellow : AppColors.borderLight,
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
                      onPressed: () {
                        state.addRideToHistory(RideHistoryItem(
                          id: 'rh${DateTime.now().microsecondsSinceEpoch}',
                          route: '${state.pickupLabel} → ${state.destinationLabel}',
                          date: 'Just now',
                          fare: state.selectedRide.fare,
                          status: 'Completed',
                          vehicleType: driver.vehicleType,
                          driverName: driver.name,
                          rating: state.tripRating,
                        ));
                        // reset for the next trip
                        state.setTripRating(4);
                        Navigator.pushNamedAndRemoveUntil(
                          context,
                          '/home',
                          (route) => route.settings.name == '/home',
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
