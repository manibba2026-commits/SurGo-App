import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class AccountSettingsScreen extends StatelessWidget {
  final bool isRider;
  const AccountSettingsScreen({super.key, this.isRider = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Account Settings')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final settings = isRider ? state.riderSettings : state.passengerSettings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              const Text('Notifications', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.muted)),
              const SizedBox(height: 8),
              _switchTile(
                'Push Notifications',
                'Ride, rental, and safety alerts',
                settings.pushNotifications,
                (v) => isRider
                    ? state.updateRiderSettings((s) => s.pushNotifications = v)
                    : state.updatePassengerSettings((s) => s.pushNotifications = v),
              ),
              if (!isRider) ...[
                const SizedBox(height: 8),
                _switchTile(
                  'SMS Alerts',
                  'For low-signal barangay areas',
                  settings.smsAlerts,
                  (v) => state.updatePassengerSettings((s) => s.smsAlerts = v),
                ),
              ],
              if (isRider) ...[
                const SizedBox(height: 8),
                _switchTile(
                  'Auto-accept Nearby Requests',
                  'Automatically accept rides under 3 km',
                  settings.autoAcceptNearby,
                  (v) => state.updateRiderSettings((s) => s.autoAcceptNearby = v),
                ),
              ],
              const SizedBox(height: 8),
              _switchTile(
                'Low-Data Mode',
                'Reduce map and image data usage',
                settings.lowDataMode,
                (v) => isRider
                    ? state.updateRiderSettings((s) => s.lowDataMode = v)
                    : state.updatePassengerSettings((s) => s.lowDataMode = v),
              ),
              const SizedBox(height: 20),
              const Text('Preferences', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.muted)),
              const SizedBox(height: 8),
              SbCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Only English is available in this simulation')),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Language', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Row(
                      children: [
                        Text(settings.language, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                        const SizedBox(width: 6),
                        const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SbOutlineButton(
                label: 'Log Out',
                icon: Icons.logout,
                onPressed: () => _confirmLogout(context),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _switchTile(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SbCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          Switch(
            value: value,
            activeColor: Colors.white,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.panel2,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Log out?'),
        content: const Text("You'll need to verify your number again to sign back in."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              AppState.instance.switchToPassenger();
              Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
            },
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
  }
}
