import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';

class WalletScreen extends StatelessWidget {
  final bool isRider;
  final bool isOwner;
  final bool embedded;
  const WalletScreen({super.key, this.isRider = false, this.isOwner = false, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final isPayout = isRider || isOwner;
    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final balance =
            isOwner ? state.ownerWalletBalance : (isRider ? state.riderWalletBalance : state.passengerWalletBalance);
        final txns =
            isOwner ? state.ownerTransactions : (isRider ? state.riderTransactions : state.passengerTransactions);
        final title = isOwner ? 'Owner Wallet' : (isRider ? 'Earnings Wallet' : 'Wallet');
        return ListView(
          padding: EdgeInsets.fromLTRB(18, embedded ? 0 : 14, 18, embedded ? 90 : 24),
          children: [
            if (embedded) SbTabHeader(title: title),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.primaryDark, AppColors.secondaryDark],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isPayout ? 'Available for payout' : 'Wallet balance',
                        style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(Money.format(balance),
                        style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: SbPrimaryButton(
                            label: isPayout ? 'Cash Out' : 'Top Up',
                            icon: isPayout ? Icons.account_balance_wallet : Icons.add_card,
                            onPressed: () =>
                                isPayout ? _showPayoutSheet(context, state, balance) : _showTopUpSheet(context, state),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('Transaction History',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              if (txns.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('No transactions yet', style: TextStyle(color: AppColors.muted)),
                )
              else
                ...txns.map((t) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _txnTile(t),
                    )),
            ],
          );
        },
      );
    if (embedded) return SafeArea(bottom: false, child: body);
    return Scaffold(
      appBar: AppBar(title: Text(isOwner ? 'Owner Wallet' : (isRider ? 'Earnings Wallet' : 'Wallet'))),
      body: body,
    );
  }

  Widget _txnTile(WalletTransaction t) {
    final positive = t.isPositive;
    return SbCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: positive ? AppColors.secondarySoft : AppColors.panel2,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              positive ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
              size: 17,
              color: positive ? AppColors.secondaryLight : AppColors.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text('${t.date} · ${t.status}', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          Text(
            '${positive ? '+' : '-'}${Money.format(t.amount)}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: positive ? AppColors.secondaryLight : AppColors.text,
            ),
          ),
        ],
      ),
    );
  }

  void _showTopUpSheet(BuildContext context, AppState state) {
    final amounts = [100, 300, 500, 1000];
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Top up wallet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: amounts
                  .map((a) => SbChip(Money.format(a), onTap: () {
                        Navigator.pop(context);
                        state.topUpPassengerWallet(a, 'GCash');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('${Money.format(a)} added to your wallet (simulated)')),
                        );
                      }))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showPayoutSheet(BuildContext context, AppState state, int balance) {
    final amounts = {500, 1000, 2000, balance};
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Cash out to GCash', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text('Available: ${Money.format(balance)}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: amounts
                  .where((a) => a > 0 && a <= balance)
                  .map((a) => SbChip(Money.format(a), onTap: () {
                        Navigator.pop(context);
                        if (isOwner) {
                          state.requestOwnerPayout(a, 'GCash');
                        } else {
                          state.requestRiderPayout(a, 'GCash');
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Payout of ${Money.format(a)} requested (simulated)')),
                        );
                      }))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
