import 'package:flutter/material.dart';
import '../data/db_models.dart';
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

class EarnerProfileScreen extends StatelessWidget {
  final bool embedded;
  const EarnerProfileScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final earner = state.db.earner;
        return SafeArea(
          bottom: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(18, embedded ? 4 : 16, 18, 90),
            children: [
              if (embedded) const SbTabHeader(title: 'Profile'),
              Center(
                child: Column(
                  children: [
                    SbAvatar(initials: earner.initials, size: 64),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(earner.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        if (earner.verified) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.verified, size: 16, color: AppColors.secondaryLight),
                        ],
                      ],
                    ),
                    Text('⭐ ${earner.rating} · ${earner.totalTrips} trips · Since ${earner.memberSince}',
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
                          Text('${earner.vehicleType} · ${earner.vehicleModel}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                          Text('Plate ${earner.vehiclePlate}',
                              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                        ],
                      ),
                    ),
                    SbTag(earner.documentsStatus, secondary: true),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _capabilitySection(context, state),
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

  /// The toggle that makes the Earner role mean something: an earner who only
  /// drives sees no errands. Refusals come from the model, not from this screen
  /// - [AppState.setEarnerCapability] returns false when the change would leave
  /// the earner with nothing on, and the snackbar explains that instead of
  /// leaving a switch that looks stuck.
  Widget _capabilitySection(BuildContext context, AppState state) {
    final earner = state.earner;
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.work_outline, color: AppColors.primaryLight, size: 18),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('What I offer',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag('${earner.activeCapabilities.length} on', secondary: true),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Errands and deliveries only appear here when switched on.',
              style: TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 6),
          for (final capability in EarnerCapability.values) ...[
            _capabilityRow(context, state, capability),
            if (capability != EarnerCapability.values.last)
              const Divider(height: 16, color: AppColors.border),
          ],
        ],
      ),
    );
  }

  Widget _capabilityRow(
      BuildContext context, AppState state, EarnerCapability capability) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(capability.label,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(capability.hint,
                  style: const TextStyle(color: AppColors.muted, fontSize: 11)),
            ],
          ),
        ),
        Switch(
          value: state.acceptsCapability(capability),
          activeColor: Colors.white,
          activeTrackColor: AppColors.secondary,
          inactiveTrackColor: AppColors.panel2,
          onChanged: (value) {
            final changed = state.setEarnerCapability(capability, value);
            if (!changed) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Keep at least one on - switch on another before turning off ${capability.label.toLowerCase()}.'),
                ),
              );
            }
          },
        ),
      ],
    );
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
