import 'package:flutter/material.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import 'active_rental_screen.dart';

class RentalDetailScreen extends StatelessWidget {
  final RentalVehicle vehicle;
  const RentalDetailScreen({super.key, required this.vehicle});

  @override
  Widget build(BuildContext context) {
    final total = vehicle.pricePerDay * 2;
    final state = AppState.instance;
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              Container(
                height: 200,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [AppColors.panel3, AppColors.panel2]),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(vehicle.icon, size: 64, color: AppColors.primaryLight.withValues(alpha: 0.8)),
                    ),
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: SafeArea(
                        bottom: false,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            SbIconButton(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                            ListenableBuilder(
                              listenable: state,
                              builder: (context, _) {
                                final isFav = state.isFavoriteVehicleName(vehicle.name);
                                return SbIconButton(
                                  icon: isFav ? Icons.favorite : Icons.favorite_border,
                                  onTap: () => state.toggleFavoriteVehicleByListing(
                                    name: vehicle.name,
                                    type: vehicle.type,
                                    pricePerDay: vehicle.pricePerDay,
                                    ownerName: vehicle.ownerName,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Row(
                        children: List.generate(
                          3,
                          (i) => Container(
                            margin: const EdgeInsets.only(left: 5),
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == 0 ? AppColors.primary : AppColors.borderLight,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(vehicle.name,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                              const SizedBox(height: 2),
                              Text('${vehicle.location}, Tandag City',
                                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('₱${vehicle.pricePerDay}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, color: AppColors.primaryLight, fontSize: 16)),
                            const Text('/ day', style: TextStyle(color: AppColors.muted, fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        SbAvatar(initials: vehicle.ownerInitials),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Owned by ${vehicle.ownerName}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                            Text('⭐ ${vehicle.rating} · Verified owner',
                                style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Row(
                      children: [
                        Expanded(child: SbField(label: 'Pick-up', value: 'Sep 2')),
                        SizedBox(width: 8),
                        Expanded(child: SbField(label: 'Return', value: 'Sep 4')),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '${vehicle.description} ₱${vehicle.depositFee} refundable deposit.',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.7),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: const BoxDecoration(
                  color: AppColors.bg,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('₱$total', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        const Text('2 days total', style: TextStyle(color: AppColors.muted, fontSize: 10.5)),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: state.activeRentalBooking != null
                            ? null
                            : () {
                                state.requestRental(
                                  vehicleName: vehicle.name,
                                  vehicleType: vehicle.type,
                                  icon: vehicle.icon,
                                  ownerName: vehicle.ownerName,
                                  ownerInitials: vehicle.ownerInitials,
                                  pickupLabel: 'Sep 2',
                                  returnLabel: 'Sep 4',
                                  days: 2,
                                  totalFare: total,
                                );
                                showDialog(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    backgroundColor: AppColors.panel,
                                    title: const Text('Rental requested'),
                                    content: Text(
                                      'Your request for the ${vehicle.name} has been sent to ${vehicle.ownerName}. '
                                      'You\'ll see it as pending on your Home tab while they respond.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context); // close dialog
                                          Navigator.pop(context); // close detail screen
                                          Navigator.pop(context); // close rental list
                                        },
                                        child: const Text('Back to Home'),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context); // close dialog
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(builder: (_) => const ActiveRentalScreen()),
                                          );
                                        },
                                        child: const Text('View Request'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                        child: Text(
                          state.activeRentalBooking != null ? 'Rental Already Requested' : 'Request Rental',
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
