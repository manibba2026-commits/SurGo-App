import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../data/db_models.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';

/// Full detail view for the passenger's current rental request/active
/// rental — pushed from the pending/active card on the Home tab. Reflects
/// [AppState.activeRentalBooking] live, so if the 10s simulated owner
/// approval fires while this screen is open it flips from Pending to
/// Active in place.
class ActiveRentalScreen extends StatelessWidget {
  const ActiveRentalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final db = DbService.instance;
    // When opened from Vehicle Owner mode, the specific booking is passed directly.
    final ownerArg =
        ModalRoute.of(context)?.settings.arguments as OwnerBookingRequest?;

    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          // If no owner arg was passed, fall back to the passenger's active booking simulation.
          final passengerBooking = state.activeRentalBooking;

          if (ownerArg == null && passengerBooking == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(context)) Navigator.pop(context);
            });
            return const SizedBox.shrink();
          }

          final isOwnerMode = ownerArg != null;
          final isPending = isOwnerMode
              ? ownerArg.status == 'Pending'
              : passengerBooking!.status == 'Pending';

          final statusString =
              isOwnerMode ? ownerArg.status : passengerBooking!.status;
          const iconData = Icons.electric_rickshaw;

          final vehicleName = isOwnerMode
              ? ownerArg.vehicleName
              : passengerBooking!.vehicleName;
          final avatarInitials = isOwnerMode
              ? ownerArg.renterInitials
              : passengerBooking!.ownerInitials;
          final targetName =
              isOwnerMode ? ownerArg.renterName : passengerBooking!.ownerName;
          final namePrefix = isOwnerMode ? 'Rented to' : 'Owned by';
          final pickup =
              isOwnerMode ? ownerArg.startDate : passengerBooking!.pickupLabel;
          final dropoff =
              isOwnerMode ? ownerArg.endDate : passengerBooking!.returnLabel;
          final totalFare =
              isOwnerMode ? ownerArg.totalFare : passengerBooking!.totalFare;

          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 18, 0),
                  child: Row(
                    children: [
                      SbIconButton(
                          icon: Icons.arrow_back,
                          onTap: () => Navigator.pop(context)),
                      const SizedBox(width: 10),
                      const Text('Your Rental',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 200,
                  child: Stack(
                    children: [
                      SurgoMap(
                        height: 200,
                        fallbackCenter: db.mapConfig.defaultCenter,
                        initialZoom: db.mapConfig.defaultZoom,
                        markers: const [],
                        interactive: false,
                        borderRadius: BorderRadius.zero,
                      ),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                if (isPending)
                                  SizedBox(
                                    width: 84,
                                    height: 84,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      valueColor: const AlwaysStoppedAnimation(
                                          AppColors.primary),
                                      backgroundColor: AppColors.panel2,
                                    ),
                                  ),
                                Container(
                                  width: 64,
                                  height: 64,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppColors.panel,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isPending
                                          ? AppColors.primary
                                          : AppColors.secondary,
                                      width: 2,
                                    ),
                                  ),
                                  child: Icon(iconData,
                                      size: 28, color: AppColors.primaryLight),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.panel.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isPending
                                    ? 'Waiting for owner approval…'
                                    : 'Rental is active',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                    child: Column(
                      children: [
                        SbCard(
                          borderColor: (isPending
                                  ? AppColors.primary
                                  : AppColors.secondary)
                              .withValues(alpha: 0.3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  SbTag(statusString, secondary: !isPending),
                                  Text(
                                      isOwnerMode
                                          ? 'Vehicle'
                                          : passengerBooking!.vehicleType,
                                      style: const TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 11.5)),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  SbAvatar(initials: avatarInitials),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(vehicleName,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 14)),
                                        Text('$namePrefix $targetName',
                                            style: const TextStyle(
                                                color: AppColors.muted,
                                                fontSize: 11.5)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                      child: SbField(
                                          label: 'Pick-up', value: pickup)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: SbField(
                                          label: 'Return', value: dropoff)),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                      isOwnerMode
                                          ? 'Total price'
                                          : '${passengerBooking!.days} day${passengerBooking.days > 1 ? 's' : ''} total',
                                      style: const TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 12)),
                                  Text(Money.format(totalFare),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primaryLight,
                                          fontSize: 15)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isOwnerMode
                              ? 'This rental is active. The renter has your vehicle until the return date.'
                              : (isPending
                                  ? '$targetName has been notified of your request. This usually takes a few minutes — we\'ll update this screen the moment it\'s approved.'
                                  : 'Your rental is active. Ride safe, and tap "Return Vehicle" once you bring it back to the owner.'),
                          style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                              height: 1.6),
                        ),
                        const SizedBox(height: 18),
                        if (isOwnerMode)
                          const SizedBox
                              .shrink() // Owners don't complete rentals here, they see it on their end / or mark returned elsewhere.
                        else if (isPending)
                          SbOutlineButton(
                            label: 'Cancel Request',
                            icon: Icons.close,
                            onPressed: () {
                              state.cancelRentalBooking();
                              Navigator.pop(context);
                            },
                          )
                        else
                          SbPrimaryButton(
                            label: 'Return Vehicle',
                            icon: Icons.check_circle_outline,
                            onPressed: () {
                              state.completeActiveRental();
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        '$vehicleName returned — thanks for riding with SurGo!')),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
