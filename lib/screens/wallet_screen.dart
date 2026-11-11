import 'package:flutter/material.dart';

import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';

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
        final balanceSlot = isOwner
            ? DomainSlot.ownerWalletBalance
            : (isRider
                ? DomainSlot.earnerWalletBalance
                : DomainSlot.passengerWalletBalance);
        final entriesSlot = isOwner
            ? DomainSlot.ownerWalletEntries
            : (isRider
                ? DomainSlot.earnerWalletEntries
                : DomainSlot.passengerWalletEntries);
        final title = isOwner ? 'Owner Wallet' : (isRider ? 'Earnings Wallet' : 'Wallet');
        return ListView(
          padding: EdgeInsets.fromLTRB(18, embedded ? 0 : 14, 18, embedded ? 90 : 24),
          children: [
            if (embedded) SbTabHeader(title: title),
              RepositoryView<int>(
                slot: balanceSlot,
                data: (context, balance) => _balanceCard(
                  isPayout: isPayout,
                  amount: _amountText(Money.format(balance)),
                  action: SbPrimaryButton(
                    label: isPayout ? 'Cash Out' : 'Top Up',
                    icon: isPayout
                        ? Icons.account_balance_wallet
                        : Icons.add_card,
                    background: Colors.white,
                    foreground: AppColors.primaryDark,
                    glow: false,
                    // The hosted build has no top-up or payout function yet;
                    // offering the seeded simulation here would present a fake
                    // money movement as real.
                    onPressed: state.usesHostedIdentity
                        ? () => SurgoNotice.show(
                              context,
                              'Top-ups and cash-outs are not enabled for live accounts yet. '
                              'Your balance reflects settled transactions only.',
                              tone: SbNoticeTone.info,
                            )
                        : isPayout && balance < state.minimumWithdrawal
                            ? null
                            : () => isPayout
                                ? _showPayoutSheet(context, state, balance)
                                : _showTopUpSheet(context, state),
                  ),
                ),
                loading: _balanceCard(
                  isPayout: isPayout,
                  amount: _amountText('—'),
                  action: SbPrimaryButton(
                    label: isPayout ? 'Cash Out' : 'Top Up',
                    icon: isPayout
                        ? Icons.account_balance_wallet
                        : Icons.add_card,
                    background: Colors.white,
                    foreground: AppColors.primaryDark,
                    glow: false,
                    onPressed: null,
                  ),
                ),
                failure: (context, failure) => _balanceCard(
                  isPayout: isPayout,
                  amount: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _amountText('—'),
                      const SizedBox(height: 6),
                      Text(failure.message,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11.5)),
                    ],
                  ),
                  action: SbPrimaryButton(
                    label: 'Try again',
                    icon: Icons.refresh,
                    background: Colors.white,
                    foreground: AppColors.primaryDark,
                    glow: false,
                    onPressed: () => state.cache.retry(balanceSlot),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const SbSectionHeader(title: 'Transaction History'),
              const SizedBox(height: 10),
              RepositoryView<List<WalletEntryRecord>>(
                slot: entriesSlot,
                empty: (_) => const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('No transactions yet',
                      style: TextStyle(color: AppColors.muted)),
                ),
                data: (context, entries) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _txnTile(entry),
                      ),
                  ],
                ),
              ),
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

  /// The balance card, with whatever the current read state puts in it.
  Widget _balanceCard({
    required bool isPayout,
    required Widget amount,
    required Widget action,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SbRadius.lg),
        gradient: SbGradients.wallet,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: SbShadows.glow(AppColors.primary, alpha: 0.26, blur: 28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  isPayout
                      ? Icons.account_balance_wallet_outlined
                      : Icons.account_balance_outlined,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 9),
              Text(isPayout ? 'Available for payout' : 'Wallet balance',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          amount,
          const SizedBox(height: 16),
          Row(children: [Expanded(child: action)]),
        ],
      ),
    );
  }

  Widget _amountText(String text) => Text(text,
      style: const TextStyle(
          color: Colors.white,
          fontSize: 30,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5));

  Widget _txnTile(WalletEntryRecord entry) {
    final positive = entry.isCredit;
    final tone = positive ? SbTone.success : SbTone.neutral;
    return SbTintedCard(
      tone: tone,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SbToneIcon(
            tone: tone,
            icon: positive
                ? Icons.arrow_downward_rounded
                : Icons.arrow_upward_rounded,
            size: 38,
            iconSize: 17,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.description ?? walletEntryTypeLabel(entry.type),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text(
                  '${displayTimestamp(entry.createdAt)} · '
                  '${walletEntryTypeLabel(entry.type)}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            '${positive ? '+' : '-'}${Money.format(entry.amountCentavos)}',
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
                        SurgoNotice.show(
                          context,
                          '${Money.format(a)} added to your wallet (simulated)',
                          tone: SbNoticeTone.success,
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
    // A double tap can land before the sheet's pop is painted, so the first
    // request latches and the second tap is ignored.
    var submitting = false;
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
                  // Rider and owner payouts share the configured minimum.
                  .where((a) =>
                      a > 0 &&
                      a <= balance &&
                      a >= state.minimumWithdrawal)
                  .map((a) => SbChip(Money.format(a), onTap: () {
                        if (submitting) return;
                        submitting = true;
                        Navigator.pop(context);
                        final requested = isOwner
                            ? state.requestOwnerPayout(a, 'GCash')
                            : state.requestPayout(a, 'GCash');
                        SurgoNotice.show(
                          context,
                          requested
                              ? 'Payout of ${Money.format(a)} requested (simulated)'
                              : 'Minimum payout is ${Money.format(state.minimumWithdrawal)}',
                          tone: requested
                              ? SbNoticeTone.success
                              : SbNoticeTone.warning,
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
