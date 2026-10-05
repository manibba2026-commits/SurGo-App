import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../services/fee_calculator.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';

/// One Pasuyo task, seen from the customer's side: live progress, the fee
/// split, a cancel/report escape hatch, and a rating prompt once delivered.
///
/// Looks the task up by id from state on every build rather than holding a
/// reference, so a status change made elsewhere (the helper accepting it, say)
/// is reflected here without any plumbing.
class PasuyoTaskScreen extends StatelessWidget {
  final String taskId;
  const PasuyoTaskScreen({super.key, required this.taskId});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final matches =
            state.pasuyoTasks.where((t) => t.id == taskId).toList();
        if (matches.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('Pasuyo')),
            body: const Center(child: Text('This task is no longer available.')),
          );
        }
        final task = matches.first;
        final breakdown =
            FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);
        final helper = _helperFor(state, task);

        return Scaffold(
          appBar: AppBar(title: const Text('Pasuyo Task')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.yellow.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(task.category.icon,
                        size: 19, color: AppColors.yellow),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(task.title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 14)),
                        const SizedBox(height: 2),
                        Text('${task.category.label} · ${task.requestedAt}',
                            style: const TextStyle(
                                color: AppColors.muted, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SbCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(task.statusLabel,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 12.5)),
                        const Spacer(),
                        Text(task.stepLabel,
                            style: const TextStyle(
                                color: AppColors.muted, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    PasuyoStepper(task: task),
                    const SizedBox(height: 16),
                    _line(Icons.storefront_outlined, 'Pickup', task.pickup,
                        AppColors.secondary),
                    const SizedBox(height: 10),
                    _line(Icons.place_outlined, 'Drop-off', task.dropoff,
                        AppColors.primary),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (task.items.isNotEmpty)
                SbCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Items',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 12.5)),
                      const SizedBox(height: 8),
                      ...task.items.map((item) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.circle, size: 5,
                                    color: AppColors.muted2),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(item,
                                      style: const TextStyle(fontSize: 12)),
                                ),
                              ],
                            ),
                          )),
                      if (task.note.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('“${task.note}”',
                            style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11.5,
                                fontStyle: FontStyle.italic)),
                      ],
                    ],
                  ),
                ),
              if (helper != null) ...[
                const SizedBox(height: 14),
                SbCard(
                  child: Row(
                    children: [
                      SbAvatar(initials: _initials(helper.name), size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(helper.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 12.5)),
                            Text(
                                '★ ${helper.rating.toStringAsFixed(1)} · ${helper.vehicleModel}',
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 11)),
                          ],
                        ),
                      ),
                      const Icon(Icons.verified,
                          size: 16, color: AppColors.secondaryLight),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _receipt(breakdown),
              const SizedBox(height: 18),
              if (task.isComplete && !task.rated)
                _ratePrompt(context, state, task)
              else if (task.isActive)
                Row(
                  children: [
                    Expanded(
                      child: SbOutlineButton(
                        label: 'Cancel task',
                        icon: Icons.close_rounded,
                        onPressed: () => _confirmCancel(context, state, task),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SbOutlineButton(
                        label: 'Report issue',
                        icon: Icons.flag_outlined,
                        onPressed: () => _report(context, task),
                      ),
                    ),
                  ],
                ),
              if (task.isCancelled)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'This task was cancelled. No payment was taken.',
                    style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// The "Customer pays / Helper gets / SurGo keeps" block — the single
  /// highest-value widget in the Pasuyo flow.
  Widget _receipt(FeeBreakdown b) {
    return SbCard(
      borderColor: AppColors.secondary.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Fee breakdown',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
          const SizedBox(height: 12),
          _row('Customer pays', b.customerPaysLabel, bold: true),
          const SizedBox(height: 7),
          _row('Helper gets', b.providerGetsLabel,
              color: AppColors.secondaryLight),
          const SizedBox(height: 7),
          _row('SurGo keeps (15%)', b.surgoKeepsLabel, color: AppColors.yellow),
        ],
      ),
    );
  }

  Widget _ratePrompt(
      BuildContext context, AppState state, PasuyoTask task) {
    var stars = 5;
    return StatefulBuilder(
      builder: (ctx, setSheet) => SbCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Rate your helper',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
            const SizedBox(height: 10),
            Row(
              children: List.generate(5, (i) {
                final filled = i < stars;
                return IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () => setSheet(() => stars = i + 1),
                  icon: Icon(
                    filled ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 26,
                    color: filled ? AppColors.yellow : AppColors.muted2,
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
            SbPrimaryButton(
              label: 'Submit $stars-star rating',
              onPressed: () {
                state.ratePasuyoTask(task, stars);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmCancel(BuildContext context, AppState state, PasuyoTask task) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Cancel this task?'),
        content: const Text(
          'The helper will be notified and you will not be charged.',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () {
              state.cancelPasuyoTask(task);
              Navigator.pop(dialogContext);
            },
            child: const Text('Cancel task',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  void _report(BuildContext context, PasuyoTask task) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
            'Report for ${task.id} sent. Our team will review it within 24 hours.'),
      ));
  }

  MapRider? _helperFor(AppState state, PasuyoTask task) {
    if (task.helperId == null) return null;
    final matches =
        state.db.mapRiders.where((r) => r.id == task.helperId).toList();
    return matches.isEmpty ? null : matches.first;
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  Widget _line(IconData icon, String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 9),
        SizedBox(
          width: 62,
          child: Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold ? AppColors.text : AppColors.muted,
              )),
        ),
        Text(value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: color ?? AppColors.text,
            )),
      ],
    );
  }
}