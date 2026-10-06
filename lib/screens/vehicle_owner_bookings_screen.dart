import 'package:flutter/material.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';

/// Vehicle Owner mode — Bookings tab. Every incoming rental request across
/// the whole fleet, whatever its status.
class VehicleOwnerBookingsScreen extends StatelessWidget {
  final bool embedded;
  const VehicleOwnerBookingsScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final content = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final bookings = state.ownerBookingRequests;
        return ListView(
          padding: EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
          children: [
            if (embedded) const SbTabHeader(title: 'Bookings'),
            if (bookings.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: Text('No booking requests yet', style: TextStyle(color: AppColors.muted))),
              )
            else
              ...bookings.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SbCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              SbAvatar(initials: b.renterInitials, size: 32),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(b.renterName,
                                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                    Text(b.vehicleName, style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                                  ],
                                ),
                              ),
                              SbTag(b.status, secondary: b.status == 'Accepted'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('${b.startDate} → ${b.endDate}',
                              style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                          const SizedBox(height: 6),
                          Text('${Money.format(b.totalFare)} total',
                              style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.primaryLight)),
                        ],
                      ),
                    ),
                  )),
          ],
        );
      },
    );
    if (embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(appBar: AppBar(title: const Text('Bookings')), body: content);
  }
}
