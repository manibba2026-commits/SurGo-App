import 'package:flutter/material.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/rental_status.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';

/// Vehicle Owner mode — Earnings tab. Today / week / month rental income
/// summary plus the accepted bookings feeding into it.
class VehicleOwnerEarningsScreen extends StatelessWidget {
  final bool embedded;
  const VehicleOwnerEarningsScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final content = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final accepted = state.ownerBookingRequests.where((b) => b.status == RentalStatus.accepted).toList();
        return ListView(
          padding: EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
          children: [
            if (embedded) const SbTabHeader(title: 'Earnings'),
            Row(
              children: [
                Expanded(child: _statCard(Money.format(state.ownerEarningsToday), 'Today')),
                const SizedBox(width: 8),
                Expanded(child: _statCard(Money.format(state.ownerEarningsWeek), 'This Week')),
                const SizedBox(width: 8),
                Expanded(child: _statCard(Money.format(state.ownerEarningsMonth), 'This Month')),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Accepted Rentals', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
            const SizedBox(height: 10),
            if (accepted.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No accepted rentals yet.', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              )
            else
              ...accepted.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SbCard(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.secondarySoft,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.directions_car, size: 16, color: AppColors.secondaryLight),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(b.vehicleName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                                Text('${b.renterName} · ${b.startDate} → ${b.endDate}',
                                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                              ],
                            ),
                          ),
                          Text(Money.format(b.totalFare), style: const TextStyle(fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                  )),
          ],
        );
      },
    );
    if (embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(appBar: AppBar(title: const Text('Earnings')), body: content);
  }

  Widget _statCard(String value, String label) {
    return SbCard(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.primaryLight)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 10.5)),
        ],
      ),
    );
  }
}
