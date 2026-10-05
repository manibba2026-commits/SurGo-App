import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              const Text('Favorite Riders', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              if (state.favoriteRiders.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Text('No favorite riders yet', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                )
              else
                ...state.favoriteRiders.map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SbCard(
                        child: Row(
                          children: [
                            SbAvatar(initials: r.initials),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                  Text('⭐ ${r.rating} · ${r.trips} trips · ${r.vehicleType}',
                                      style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.favorite, color: AppColors.primary, size: 18),
                              onPressed: () => state.removeFavoriteRider(r),
                            ),
                          ],
                        ),
                      ),
                    )),
              const SizedBox(height: 12),
              const Text('Favorite Rental Vehicles', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              if (state.favoriteVehicles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('No favorite vehicles yet', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                )
              else
                ...state.favoriteVehicles.map((v) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SbCard(
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.panel2,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: const Icon(Icons.airport_shuttle, size: 18, color: AppColors.secondaryLight),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(v.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                  Text('₱${v.pricePerDay}/day · Owned by ${v.ownerName}',
                                      style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.favorite, color: AppColors.primary, size: 18),
                              onPressed: () => state.removeFavoriteVehicle(v),
                            ),
                          ],
                        ),
                      ),
                    )),
            ],
          );
        },
      ),
    );
  }
}
