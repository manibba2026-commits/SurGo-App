import 'package:flutter/material.dart';
import '../services/fee_calculator.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import 'wallet_screen.dart';

class RiderEarningsScreen extends StatelessWidget {
  final bool embedded;
  const RiderEarningsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final body = ListenableBuilder(
      listenable: Listenable.merge([state, PlatformLedger.instance]),
      builder: (context, _) {
        final dailyEarnings = state.dailyEarnings;
        final maxAmount = dailyEarnings.isEmpty
            ? 0
            : dailyEarnings.map((d) => d.amount).reduce((a, b) => a > b ? a : b);
        return ListView(
          padding: EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
          children: [
            if (embedded) const SbTabHeader(title: 'Earnings'),
              Row(
                children: [
                  Expanded(child: _statCard(state.availableEarningsLabel, 'Available')),
                  const SizedBox(width: 8),
                  Expanded(child: _statCard(state.pendingEarningsLabel, 'Pending')),
                  const SizedBox(width: 8),
                  Expanded(child: _statCard('₱${state.earningsWeek}', 'This Week')),
                ],
              ),
              const SizedBox(height: 18),
              _earningsBreakdown(state),
              const SizedBox(height: 20),
              const Text('This Week', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 14),
              SbCard(
                child: SizedBox(
                  height: 140,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: dailyEarnings.map((d) {
                      final heightFactor = maxAmount == 0 ? 0.0 : d.amount / maxAmount;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('${d.amount}', style: const TextStyle(fontSize: 9.5, color: AppColors.muted)),
                          const SizedBox(height: 4),
                          Container(
                            width: 20,
                            height: 90 * heightFactor.clamp(0.05, 1.0),
                            decoration: BoxDecoration(
                              color: AppColors.secondary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(d.day, style: const TextStyle(fontSize: 10.5, color: AppColors.muted, fontWeight: FontWeight.w700)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SbPrimaryButton(
                label: 'Withdraw to Wallet',
                icon: Icons.account_balance_wallet,
                onPressed: state.db.riderWalletBalance <= 0
                    ? null
                    : () => _showWithdrawSheet(context, state),
              ),
              const SizedBox(height: 10),
              SbOutlineButton(
                label: 'Cash Out to GCash',
                icon: Icons.payments_outlined,
                onPressed: state.db.riderWalletBalance <= 0
                    ? null
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const WalletScreen(isRider: true)),
                        ),
              ),
              const SizedBox(height: 20),
              const Text('Payout History', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              ...state.payoutHistory.map((p) => Padding(
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
                            child: const Icon(Icons.arrow_downward_rounded, size: 16, color: AppColors.secondaryLight),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Payout via ${p.method}',
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                                Text('${p.date} · ${p.status}',
                                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                              ],
                            ),
                          ),
                          Text('₱${p.amount}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                  )),
            ],
          );
        },
      );
    if (embedded) return SafeArea(bottom: false, child: body);
    return Scaffold(appBar: AppBar(title: const Text('Earnings')), body: body);
  }

  /// Earnings split by what earned them. Rides and Pasuyo are derived from
  /// completed trips at the net rate SurGo actually pays out, so the numbers
  /// move when a task completes rather than being hardcoded.
  Widget _earningsBreakdown(AppState state) {
    final rows = <(String, String, int)>[
      ('Rides', 'Net of 10% SurGo fee', state.netRideEarnings),
      ('Pasuyo', 'Net of 15% SurGo fee', state.netPasuyoEarnings),
      ('Bonus', 'Incentives and tips', state.bonusEarnings),
    ];
    final total = state.netRideEarnings + state.netPasuyoEarnings + state.bonusEarnings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Where your earnings come from',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
        const SizedBox(height: 10),
        SbCard(
          child: Column(
            children: [
              ...rows.map((row) {
                final share = total == 0 ? 0.0 : row.$3 / total;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(row.$1,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 12.5)),
                          ),
                          Text('₱${row.$3}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 12.5)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(row.$2,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 10.5)),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: share.clamp(0.0, 1.0),
                          minHeight: 5,
                          backgroundColor: AppColors.panel3,
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.secondary),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(color: AppColors.border, height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Text('Total earned',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ),
                  Text('₱$total',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: AppColors.secondaryLight)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Lets the rider pull some of their available earnings into their wallet.
  /// Amount defaults to everything available so the demo is one tap.
  void _showWithdrawSheet(BuildContext context, AppState state) {
    final available = state.db.riderWalletBalance;
    var amount = available;
    final controller = TextEditingController(text: '$amount');

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Withdraw earnings',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 4),
              Text('Available ₱$available',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                onChanged: (v) =>
                    setSheet(() => amount = int.tryParse(v.trim()) ?? 0),
                style: const TextStyle(fontWeight: FontWeight.w700),
                decoration: const InputDecoration(
                  prefixText: '₱',
                  prefixStyle: TextStyle(color: AppColors.muted),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SbOutlineButton(
                      label: 'All',
                      onPressed: () {
                        controller.text = '$available';
                        setSheet(() => amount = available);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SbOutlineButton(
                      label: 'Half',
                      onPressed: () {
                        final half = available ~/ 2;
                        controller.text = '$half';
                        setSheet(() => amount = half);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SbPrimaryButton(
                label: 'Withdraw ₱$amount',
                icon: Icons.arrow_downward_rounded,
                onPressed: amount <= 0 || amount > available
                    ? null
                    : () {
                        state.withdrawEarnings(amount, 'Wallet');
                        Navigator.pop(ctx);
                      },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Widget _statCard(String value, String label) {
    return SbCard(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.secondaryLight)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 10.5)),
        ],
      ),
    );
  }
}
