import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../state/pasuyo_status.dart';
import '../theme/app_colors.dart';

/// Visual progress of a Pasuyo errand along [PasuyoStatus.flow].
///
/// Reads the task's own status and the enum's flow, so the stepper can never
/// disagree with the state machine driving the buttons. It draws a dot per
/// state but labels only four milestones, because eight labels will not fit
/// across a phone width and truncating them would say less than the status line
/// already does.
class PasuyoStepper extends StatelessWidget {
  final PasuyoTask task;
  final bool compact;
  const PasuyoStepper({super.key, required this.task, this.compact = false});

  /// The states worth naming to a customer watching the errand. Each is a real
  /// state in [PasuyoStatus.flow]; the stepper looks them up by identity so a
  /// reordering of the flow cannot silently orphan a label.
  static const List<PasuyoStatus> _milestones = [
    PasuyoStatus.accepted,
    PasuyoStatus.atPickup,
    PasuyoStatus.delivering,
    PasuyoStatus.delivered,
  ];

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
    final flow = PasuyoStatus.flow;
    // zipped so each label keeps the identity of the state it names; the
    // stepper compares `state.index` rather than the string.
    final milestones = [
      for (final m in _milestones) (state: m, label: m.shortLabel),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < flow.length; i++) ...[
              _dot(i, current),
              if (i < flow.length - 1) _line(i, current),
            ],
          ],
        ),
        if (!compact) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final m in milestones)
                Flexible(
                  child: Text(
                    m.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      color: m.state.index <= current
                          ? AppColors.secondaryLight
                          : AppColors.muted2,
                    ),
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
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? AppColors.yellow : AppColors.muted2.withValues(alpha: 0.35),
        border: Border.all(
          color: index == current ? AppColors.yellow : Colors.transparent,
          width: 2,
        ),
      ),
    );
  }

  Widget _line(int index, int current) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        color: index < current ? AppColors.yellow : AppColors.muted2.withValues(alpha: 0.35),
      ),
    );
  }
}