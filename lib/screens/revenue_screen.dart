import 'package:flutter/material.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

/// Platform revenue dashboard — the "profitable" slide.
///
/// Every figure here comes from [PlatformLedger], which only grows when a
/// transaction actually completes, so the numbers on this screen are the same
/// ones that moved the helper's balance a moment earlier.
///
/// Two distinctions this screen must never blur:
///
///  * A ride's **platform fee** is a separate charge on top of the provider's
///    fare, not a percentage cut out of it. Pasuyo and rental commissions are
///    still percentage-based and are reported on their own line.
///  * This is a **cash** prototype. An earned fee is a receivable until the
///    driver actually remits it, so only [PlatformLedger.remittedRevenue] may
///    be presented as cash collected.
class RevenueScreen extends StatelessWidget {
  const RevenueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Platform Revenue')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([AppState.instance, PlatformLedger.instance]),
        builder: (context, _) {
          final ledger = PlatformLedger.instance;
          final byService = ledger.revenueByService;
          final volume = ledger.volumeByService;
          final days = ledger.revenueLastDays(7);
          final maxDay =
              days.isEmpty ? 0 : days.reduce((a, b) => a > b ? a : b);

          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
            children: [
              _headline(ledger),
              const SizedBox(height: 20),
              const Text('Platform fees vs provider earnings',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              SbCard(
                child: Column(
                  children: [
                    _row('Ride platform fees earned',
                        Money.format(ledger.platformFeeRevenue),
                        color: AppColors.yellow, bold: true),
                    const SizedBox(height: 4),
                    _row('  Remitted to SurGo',
                        Money.format(ledger.remittedPlatformFees),
                        color: AppColors.secondaryLight),
                    _row('  Still held by drivers',
                        Money.format(ledger.outstandingPlatformFees)),
                    const SizedBox(height: 12),
                    _row('Pasuyo & rental commissions',
                        Money.format(ledger.commissionRevenue),
                        color: AppColors.yellow, bold: true),
                    const SizedBox(height: 4),
                    _row('  Remitted to SurGo',
                        Money.format(ledger.remittedCommission),
                        color: AppColors.secondaryLight),
                    _row('  Outstanding commission',
                        Money.format(ledger.outstandingCommission)),
                    const SizedBox(height: 12),
                    const Divider(color: AppColors.border, height: 1),
                    const SizedBox(height: 12),
                    _row('Paid to riders, helpers & owners',
                        Money.format(ledger.providerEarnings),
                        color: AppColors.secondaryLight, bold: true),
                    const SizedBox(height: 8),
                    _row('Gross volume handled',
                        Money.format(ledger.totalVolume), bold: true),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Cash basis: a platform fee is only counted as collected once '
                'it has been remitted. Cash trips start as outstanding because '
                'the driver still holds the customer’s payment.',
                style: TextStyle(color: AppColors.muted2, fontSize: 10.5),
              ),
              const SizedBox(height: 20),
              const Text('Earnings by service',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              SbCard(
                child: Column(
                  children: ServiceType.values.map((service) {
                    final earned = byService[service] ?? 0;
                    final share = ledger.totalRevenue == 0
                        ? 0.0
                        : earned / ledger.totalRevenue;
                    final isRide = service == ServiceType.ride;
                    final basisLabel = isRide
                        ? '₱2.00/km · ₱5–₱30 band'
                        : '${FeeCalculator.commissionPercentFor(service).toStringAsFixed(0)}% commission';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(service.label,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12.5)),
                              ),
                              Text(
                                  Money.format(earned),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                      color: AppColors.yellow)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(basisLabel,
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 10.5)),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: share.clamp(0.0, 1.0),
                              minHeight: 5,
                              backgroundColor: AppColors.panel3,
                              valueColor: const AlwaysStoppedAnimation(
                                  AppColors.yellow),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              '${ledger.countFor(service)} transactions · '
                              '${Money.format(volume[service] ?? 0)} volume · '
                              '${Money.format(ledger.providerEarningsFor(service))} to provider',
                              style: const TextStyle(
                                  color: AppColors.muted2, fontSize: 10)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Last 7 days (platform earnings)',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              SbCard(
                child: SizedBox(
                  height: 150,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: days.asMap().entries.map((entry) {
                      final amount = entry.value;
                      final factor = maxDay == 0 ? 0.0 : amount / maxDay;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(Money.format(amount, symbol: false),
                              style: const TextStyle(
                                  fontSize: 8.5, color: AppColors.muted)),
                          const SizedBox(height: 4),
                          Container(
                            width: 26,
                            height: 95 * factor.clamp(0.04, 1.0),
                            decoration: BoxDecoration(
                              color: AppColors.yellow,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(_dayLabel(entry.key),
                              style: const TextStyle(
                                  fontSize: 9.5,
                                  color: AppColors.muted,
                                  fontWeight: FontWeight.w700)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _headline(PlatformLedger ledger) {
    return SbCard(
      borderColor: AppColors.yellow.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Cash collected by SurGo',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 4),
          Text(Money.format(ledger.remittedRevenue),
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 30,
                  color: AppColors.yellow)),
          const SizedBox(height: 6),
          Text(
              '${Money.format(ledger.totalRevenue)} earned · '
              '${Money.format(ledger.outstandingRevenue)} still outstanding',
              style: const TextStyle(color: AppColors.muted2, fontSize: 11)),
          const SizedBox(height: 10),
          Row(
            children: [
              _pill('Platform fees',
                  Money.format(ledger.platformFeeRevenue)),
              const SizedBox(width: 8),
              _pill('Commission',
                  Money.format(ledger.commissionRevenue)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
              '${ledger.transactionCount} transactions · '
              '${Money.format(ledger.totalVolume)} gross volume',
              style:
                  const TextStyle(color: AppColors.muted2, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _pill(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.panel3,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style:
                    const TextStyle(color: AppColors.muted, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }

  String _dayLabel(int offsetFromToday) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: 6 - offsetFromToday));
    return names[day.weekday - 1];
  }

  Widget _row(String label, String value,
      {bool bold = false, Color? color}) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold ? AppColors.text : AppColors.muted,
              )),
        ),
        Text(value,
            style: TextStyle(
              fontSize: bold ? 14 : 12.5,
              fontWeight: FontWeight.w800,
              color: color ?? AppColors.text,
            )),
      ],
    );
  }
}
