import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import 'pasuyo_post_screen.dart';
import 'pasuyo_task_screen.dart';

/// Customer-side Pasuyo hub: post a new errand, or track the ones already in
/// flight. Mirrors the tabbed shape of the other role screens but stays a
/// simple pushed route so it works from the Home tile.
class PasuyoScreen extends StatelessWidget {
  const PasuyoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Pasuyo')),
        body: state.usesHostedIdentity && state.repositories.isSupabaseBacked
            ? RepositoryView<List<ServiceRequestRecord>>(
                key: ValueKey((state.repositories, state.identity?.userId)),
                slot: DomainSlot.customerErrands,
                data: (context, records) => RefreshIndicator(
                  onRefresh: _refresh,
                  child: _buildBody(context, [
                    for (final record in records) pasuyoTaskFromRecord(record),
                  ]),
                ),
                empty: (_) => RefreshIndicator(
                  onRefresh: _refresh,
                  child: _buildBody(context, const []),
                ),
              )
            : _buildBody(context, state.myPasuyoOrders),
      ),
    );
  }

  Future<void> _refresh() async {
    final state = AppState.instance;
    if (state.usesHostedIdentity &&
        state.repositories.isSupabaseBacked &&
        state.isSignedIn) {
      await state.cache.refresh(DomainSlot.customerErrands);
    }
  }

  Future<void> _open(BuildContext context, Widget screen) async {
    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (!context.mounted ||
        !identical(registry, state.repositories) ||
        userId != state.identity?.userId) {
      return;
    }
    await _refresh();
  }

  Widget _buildBody(BuildContext context, List<PasuyoTask> orders) {
    // Posted errands are waiting, not history. Only terminal tasks are done.
    final active = orders.where((t) => !t.status.isTerminal).toList();
    final done = orders.where((t) => t.status.isTerminal).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        SbPrimaryButton(
          label: 'Post a Pasuyo',
          icon: Icons.add_rounded,
          background: AppColors.yellow,
          onAccent: true,
          onPressed: () => _open(context, const PasuyoPostScreen()),
        ),
        const SizedBox(height: 22),
        const SbSectionHeader(title: 'In progress'),
        const SizedBox(height: 10),
        if (active.isEmpty)
          _empty(
            'No errands in progress',
            'Post one and a helper nearby will pick it up.',
          )
        else
          ...active.map(
            (t) => _TaskRow(
              task: t,
              onTap: () => _open(context, PasuyoTaskScreen(taskId: t.id)),
            ),
          ),
        if (done.isNotEmpty) ...[
          const SizedBox(height: 22),
          const SbSectionHeader(title: 'History'),
          const SizedBox(height: 10),
          ...done.map(
            (t) => _TaskRow(
              task: t,
              onTap: () => _open(context, PasuyoTaskScreen(taskId: t.id)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _empty(String title, String subtitle) {
    return SbTintedCard(
      tone: SbTone.neutral,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.inbox_outlined, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

/// One task row, shared shape between the customer's tracker and the helper's
/// nearby list.
class _TaskRow extends StatelessWidget {
  final PasuyoTask task;
  final VoidCallback onTap;
  const _TaskRow({required this.task, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // A hosted errand carries the fixed fee the database charged; a seeded one
    // is still priced by the legacy percentage rule.
    final fee = task.platformFee > 0
        ? task.platformFee
        : FeeCalculator.surgoShare(ServiceType.pasuyo, task.budget);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SbTintedCard(
        tone: task.isComplete || task.isCancelled
            ? SbTone.neutral
            : SbTone.pasuyo,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SbToneIcon(
                  tone: task.isComplete || task.isCancelled
                      ? SbTone.neutral
                      : SbTone.pasuyo,
                  icon: task.category.icon,
                  size: 34,
                  iconSize: 17,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${task.pickup} → ${task.dropoff}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      Money.format(task.budget),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      'fee ${Money.format(fee)}',
                      style: const TextStyle(
                        color: AppColors.muted2,
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 11),
            PasuyoStepper(task: task, compact: true),
            const SizedBox(height: 9),
            Row(
              children: [
                SbTag(
                  task.statusLabel,
                  secondary: task.isComplete || task.isCancelled,
                ),
                const Spacer(),
                Text(
                  task.requestedAt,
                  style: const TextStyle(color: AppColors.muted2, fontSize: 10),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
