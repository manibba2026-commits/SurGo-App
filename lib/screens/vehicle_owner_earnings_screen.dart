import 'package:flutter/material.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_status.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';

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
        if (state.usesHostedIdentity) return _hostedBody(state);
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
                    child: _rentalRow(b.vehicleName,
                        '${b.renterName} · ${b.startDate} → ${b.endDate}',
                        b.totalFare),
                  )),
          ],
        );
      },
    );
    if (embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(appBar: AppBar(title: const Text('Earnings')), body: content);
  }

  /// Hosted owner earnings: settled rental payouts and the bookings that
  /// produced them. A pending or declined request never appears, and cash
  /// rentals settle into a service transaction rather than the wallet ledger.
  Widget _hostedBody(AppState state) {
    final profileId = state.identity?.userId;
    return ListView(
      padding:
          EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
      children: [
        if (embedded) const SbTabHeader(title: 'Earnings'),
        RepositoryView<List<ServiceTransactionRecord>>(
          slot: DomainSlot.earnerSettlements,
          loading: const SizedBox.shrink(),
          empty: (_) => _statsRow(0, 0, 0),
          failure: (_, __) => _statsRow(0, 0, 0),
          data: (context, entries) {
            final now = DateTime.now();
            final todayStart = DateTime(now.year, now.month, now.day);
            final weekStart =
                todayStart.subtract(Duration(days: now.weekday - 1));
            final monthStart = DateTime(now.year, now.month, 1);
            int earnedSince(DateTime from) => entries
                .where((e) =>
                    e.serviceType == 'rental' &&
                    e.providerId == profileId &&
                    e.status == 'completed' &&
                    e.settledAt != null &&
                    !e.settledAt!.isBefore(from))
                .fold(0, (sum, e) => sum + e.providerPayoutCentavos);
            return _statsRow(earnedSince(todayStart), earnedSince(weekStart),
                earnedSince(monthStart));
          },
        ),
        const SizedBox(height: 20),
        const Text('Accepted Rentals',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
        const SizedBox(height: 10),
        RepositoryView<List<RentalRecord>>(
          slot: DomainSlot.ownerRentalBookings,
          loading: const SizedBox.shrink(),
          empty: (_) => const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No accepted rentals yet.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          ),
          failure: (_, failure) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(failure.message,
                style:
                    const TextStyle(color: AppColors.muted, fontSize: 12.5)),
          ),
          data: (context, records) {
            final accepted = [
              for (final record in records)
                if (record.status == RentalStatus.accepted ||
                    record.status == RentalStatus.active ||
                    record.status == RentalStatus.returned ||
                    record.status == RentalStatus.completed)
                  record,
            ];
            if (accepted.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No accepted rentals yet.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final record in accepted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _rentalRow(
                      record.vehicleName ?? 'Vehicle',
                      '${record.renterName ?? 'Renter'} · '
                      '${displayDateOnly(record.startAt)} → '
                      '${displayDateOnly(record.endAt)}',
                      record.totalFareCentavos,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _statsRow(int today, int week, int month) {
    return Row(
      children: [
        Expanded(child: _statCard(Money.format(today), 'Today')),
        const SizedBox(width: 8),
        Expanded(child: _statCard(Money.format(week), 'This Week')),
        const SizedBox(width: 8),
        Expanded(child: _statCard(Money.format(month), 'This Month')),
      ],
    );
  }

  Widget _rentalRow(String vehicleName, String subtitle, int amount) {
    return SbCard(
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
            child: const Icon(Icons.directions_car,
                size: 16, color: AppColors.secondaryLight),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vehicleName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12.5)),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          Text(Money.format(amount),
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
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
