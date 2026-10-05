import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../theme/app_colors.dart';

/// Visual progress of a Pasuyo task across its five statuses:
/// posted → accepted → purchasing → delivering → completed.
///
/// Reads the task's own status and [PasuyoTask.flow] so the stepper can never
/// disagree with the state machine driving the buttons.
class PasuyoStepper extends StatelessWidget {
  final PasuyoTask task;
  final bool compact;
  const PasuyoStepper({super.key, required this.task, this.compact = false});

  static const _labels = ['Posted', 'Accepted', 'Buying', 'Delivering', 'Done'];

  @override
  Widget build(BuildContext context) {
    if (task.isCancelled) {
      return Row(
        children: [
          const Icon(Icons.cancel_outlined, size: 14, color: AppColors.danger),
          const SizedBox(width: 6),
          const Text('Cancelled',
              style: TextStyle(
                  color: AppColors.danger, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      );
    }

    final current = task.stepIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < PasuyoTask.flow.length; i++) ...[
              _dot(i, current),
              if (i < PasuyoTask.flow.length - 1) _line(i, current),
            ],
          ],
        ),
        if (!compact) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final label in _labels)
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: _labels.indexOf(label) <= current
                        ? AppColors.secondaryLight
                        : AppColors.muted2,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _dot(int index, int current) {
    final done = index <= current;
    final isCurrent = index == current;
    return Container(
      width: isCurrent ? 13 : 10,
      height: isCurrent ? 13 : 10,
      decoration: BoxDecoration(
        color: done ? AppColors.secondary : AppColors.panel3,
        shape: BoxShape.circle,
        border: isCurrent ? Border.all(color: AppColors.secondaryLight, width: 2) : null,
      ),
      child: done && !isCurrent
          ? const Icon(Icons.check, size: 6, color: AppColors.onAccent)
          : null,
    );
  }

  Widget _line(int index, int current) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        color: index < current ? AppColors.secondary : AppColors.panel3,
      ),
    );
  }
}
