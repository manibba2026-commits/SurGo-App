import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

class _ModeInfo {
  final UserMode mode;
  final String label;
  final IconData icon;
  final String route;
  const _ModeInfo(this.mode, this.label, this.icon, this.route);
}

const _modes = [
  _ModeInfo(UserMode.passenger, 'Passenger', Icons.person_outline, '/home'),
  _ModeInfo(UserMode.earner, 'Earner', Icons.electric_rickshaw, '/earner'),
  _ModeInfo(UserMode.vehicleOwner, 'Vehicle Owner', Icons.directions_car_filled_outlined, '/owner'),
];

/// A dropdown menu (not a simple on/off switch) that lets the user pick
/// between all 3 account modes: Passenger, Earner, and Vehicle Owner.
/// Used on every Profile tab so switching is always one tap away.
class SbModeSwitcher extends StatelessWidget {
  const SbModeSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final current = _modes.firstWhere((m) => m.mode == state.mode);

    return PopupMenuButton<_ModeInfo>(
      color: AppColors.panel2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      offset: const Offset(0, 8),
      onSelected: (picked) {
        if (picked.mode == state.mode) return;
        state.switchToMode(picked.mode);
        Navigator.pushNamedAndRemoveUntil(context, picked.route, (r) => false);
      },
      itemBuilder: (context) => _modes
          .map(
            (m) => PopupMenuItem(
              value: m,
              child: Row(
                children: [
                  Icon(
                    m.icon,
                    size: 18,
                    color: m.mode == state.mode ? AppColors.primaryLight : AppColors.muted,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    m.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: m.mode == state.mode ? AppColors.primaryLight : AppColors.text,
                    ),
                  ),
                  if (m.mode == state.mode) ...[
                    const Spacer(),
                    const Icon(Icons.check, size: 16, color: AppColors.primaryLight),
                  ],
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(current.icon, size: 18, color: AppColors.primaryLight),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CURRENT MODE',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.muted2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(current.label,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                ],
              ),
            ),
            const Icon(Icons.unfold_more, size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}
