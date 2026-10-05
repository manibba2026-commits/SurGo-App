import 'package:flutter/material.dart';
import '../services/fee_calculator.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

/// Platform revenue dashboard — the "profitable" slide.
///
/// Every figure here comes from PlatformLedger, which only grows when a
/// transaction actually completes, so the numbers on this screen are the same
/// ones that moved the helper's balance a moment earlier.
class RevenueScreen extends StatelessWidget {
  const RevenueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Platform Revenue')),
      body: ListenableBuilder(
        listenable: Listenable.merge([AppState.instance, PlatformLedger.instance]),
        builder: (context, _) {
          final ledger = PlatformLedger.instance;
          final byService = ledger.revenueByService;
          final volume = ledger.volumeByService;
          final days = ledger.revenueLastDays(7);
          final maxDay = days.isEmpty ? 0 : days.reduce((a, b) => a > b ? a : b);

          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
            children: [
              _headline(ledger.totalRevenue, ledger.totalVolume,
                  ledger.transactionCount),
              const SizedBox(height: 20),
              const Text('Commission by service',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              SbCard(
                child: Column(
                  children: ServiceType.values.map((service) {
                    final revenue = byService[service] ?? 0;
                    final share =
                        ledger.totalRevenue == 0 ? 0.0 : revenue / ledger.totalRevenue;
                    final rate = FeeCalculator.commissionPercentFor(service);
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
                                  '${rate.toStringAsFixed(0)}% of ₱${volume[service] ?? 0}',
                                  style: const TextStyle(
                                      color: AppColors.muted, fontSize: 10.5)),
                              const SizedBox(width: 8),
                              Text('₱$revenue',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                      color: AppColors.yellow)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: share.clamp(0.0, 1.0),
                              minHeight: 5,
                              backgroundColor: AppColors.panel3,
                              valueColor:
                                  const AlwaysStoppedAnimation(AppColors.yellow),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              '${ledger.countFor(service)} transactions',
                              style: const TextStyle(
                                  color: AppColors.muted2, fontSize: 10)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Last 7 days',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              SbCard(
                child: SizedBox(
                  height: 150,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: days.asMap().entries.map((entry) {
                      final amount = entry.value;
                      final factor =
                          maxDay == 0 ? 0.0 : amount / maxDay;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('${amount}',
                              style: const TextStyle(
                                  fontSize: 9.5, color: AppColors.muted)),
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
              const SizedBox(height: 20),
              SbCard(
                child: Column(
                  children: [
                    _row('Gross volume handled',
                        '₱${ledger.totalVolume}', bold: true),
                    const SizedBox(height: 8),
                    _row('Paid to riders & helpers',
                        '₱${ledger.totalPayouts}',
                        color: AppColors.secondaryLight),
                    const SizedBox(height: 8),
                    _row('SurGo net commission',
                        '₱${ledger.totalRevenue}', color: AppColors.yellow),
                    const SizedBox(height: 12),
                    const Divider(color: AppColors.border, height: 1),
                    const SizedBox(height: 12),
                    _row('Take rate on volume',
                        '${_takeRate(ledger.totalVolume, ledger.totalRevenue)}%',
                        bold: true),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _takeRate(int volume, int revenue) {
    if (volume == 0) return '0.0';
    return ((revenue / volume) * 100).toStringAsFixed(1);
  }

  Widget _headline(int revenue, int volume, int count) {
    return SbCard(
      borderColor: AppColors.yellow.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SurGo keeps',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 6),
          Text('₱$revenue',
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 30,
                  color: AppColors.yellow)),
          const SizedBox(height: 4),
          Text(
              '$count transactions · ₱$volume gross volume',
              style:
                  const TextStyle(color: AppColors.muted2, fontSize: 11)),
        ],
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

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
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