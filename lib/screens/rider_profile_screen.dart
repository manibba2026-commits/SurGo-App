import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import '../widgets/mode_switcher.dart';
import 'account_settings_screen.dart';
import 'emergency_contacts_screen.dart';
import 'rider_earnings_screen.dart';
import 'rider_trips_screen.dart';
import 'vehicle_documents_screen.dart';
import 'wallet_screen.dart';

class RiderProfileScreen extends StatelessWidget {
  final bool embedded;
  const RiderProfileScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final rider = state.db.rider;
        return SafeArea(
          bottom: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(18, embedded ? 4 : 16, 18, 90),
            children: [
              if (embedded) const SbTabHeader(title: 'Profile'),
              Center(
                child: Column(
                  children: [
                    SbAvatar(initials: rider.initials, size: 64),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(rider.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        if (rider.verified) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.verified, size: 16, color: AppColors.secondaryLight),
                        ],
                      ],
                    ),
                    Text('⭐ ${rider.rating} · ${rider.totalTrips} trips · Since ${rider.memberSince}',
                        style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SbCard(
                child: Row(
                  children: [
                    const Icon(Icons.two_wheeler, color: AppColors.secondaryLight, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${rider.vehicleType} · ${rider.vehicleModel}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                          Text('Plate ${rider.vehiclePlate}',
                              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                        ],
                      ),
                    ),
                    SbTag(rider.documentsStatus, secondary: true),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _quickAction(
                      context,
                      icon: Icons.receipt_long,
                      label: 'My Trips',
                      color: AppColors.primaryLight,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RiderTripsScreen())),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _quickAction(
                      context,
                      icon: Icons.bar_chart_rounded,
                      label: 'Earnings',
                      color: AppColors.secondaryLight,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RiderEarningsScreen())),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _quickAction(
                      context,
                      icon: Icons.account_balance_wallet_outlined,
                      label: 'Wallet',
                      color: AppColors.muted,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletScreen(isRider: true))),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _settingsRow(context, 'Vehicle Documents',
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VehicleDocumentsScreen()))),
              const SizedBox(height: 8),
              _settingsRow(context, 'Emergency Contacts',
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EmergencyContactsScreen()))),
              const SizedBox(height: 8),
              _settingsRow(context, 'Account Settings',
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const AccountSettingsScreen(isRider: true)))),
              const SizedBox(height: 20),
              const SbModeSwitcher(),
            ],
          ),
        );
      },
    );
    if (embedded) return body;
    return Scaffold(body: body);
  }

  Widget _quickAction(BuildContext context,
      {required IconData icon, required String label, required Color color, VoidCallback? onTap}) {
    return SbCard(
      padding: const EdgeInsets.symmetric(vertical: 12),
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _settingsRow(BuildContext context, String label, {VoidCallback? onTap}) {
    return SbCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      onTap: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
        ],
      ),
    );
  }
}
