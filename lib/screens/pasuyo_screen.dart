import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Pasuyo')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final orders = state.myPasuyoOrders;
          final active = orders.where((t) => t.isActive).toList();
          final done = orders.where((t) => !t.isActive).toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
            children: [
              SbPrimaryButton(
                label: 'Post a Pasuyo',
                icon: Icons.add_rounded,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PasuyoPostScreen()),
                ),
              ),
              const SizedBox(height: 22),
              const Text('In progress',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 10),
              if (active.isEmpty)
                _empty('No errands in progress', 'Post one and a helper nearby will pick it up.')
              else
                ...active.map((t) => _TaskRow(
                      task: t,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => PasuyoTaskScreen(taskId: t.id)),
                      ),
                    )),
              if (done.isNotEmpty) ...[
                const SizedBox(height: 22),
                const Text('History',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                const SizedBox(height: 10),
                ...done.map((t) => _TaskRow(
                      task: t,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => PasuyoTaskScreen(taskId: t.id)),
                      ),
                    )),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _empty(String title, String subtitle) {
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.inbox_outlined, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 3),
          Text(subtitle,
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
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
    final b = FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SbCard(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.yellow.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(task.category.icon,
                      size: 17, color: AppColors.yellow),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 12.5)),
                      const SizedBox(height: 2),
                      Text('${task.pickup} → ${task.dropoff}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(Money.format(task.budget),
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13)),
                    Text('fee ${b.surgoKeepsLabel}',
                        style: const TextStyle(
                            color: AppColors.muted2, fontSize: 9.5)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 11),
            PasuyoStepper(task: task, compact: true),
            const SizedBox(height: 9),
            Row(
              children: [
                SbTag(task.statusLabel,
                    secondary: task.isComplete || task.isCancelled),
                const Spacer(),
                Text(task.requestedAt,
                    style: const TextStyle(
                        color: AppColors.muted2, fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
