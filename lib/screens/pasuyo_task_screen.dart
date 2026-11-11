import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/pasuyo_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';
import '../widgets/surgo_notice.dart';

/// One Pasuyo task, seen from the customer's side: live progress, the fee
/// split, a cancel/report escape hatch, and a rating prompt once delivered.
///
/// Looks the task up by id from state on every build rather than holding a
/// reference, so a status change made elsewhere (the helper accepting it, say)
/// is reflected here without any plumbing.
class PasuyoTaskScreen extends StatelessWidget {
  final String taskId;

  /// True when opened from the helper's side of the app.
  ///
  /// One screen serves both roles: the customer watches the stepper and uses
  /// cancel/report, the helper works the errand. The task itself cannot answer
  /// who is looking — every seeded errand belongs to the same customer, so
  /// inferring the role from the data would mean the helper is never offered
  /// an accept button. The caller therefore states which side it is on.
  final bool helperMode;

  const PasuyoTaskScreen(
      {super.key, required this.taskId, this.helperMode = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;

    if (state.usesHostedIdentity) {
      return _HostedPasuyoTaskScreen(taskId: taskId, helperMode: helperMode);
    }

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
              // The helper's controls, offered only from the helper's side.
              // Each label comes from the enum: a null label means the machine
              // has no legal move, and a button rendered anyway would press
              // into nothing while looking perfectly alive.
              if (helperMode && task.isOpen) ...[
                SbPrimaryButton(
                  label: 'Accept task',
                  icon: Icons.handshake_outlined,
                  background: AppColors.yellow,
                  onAccent: true,
                  onPressed: () {
                    final refusal = state.acceptPasuyoTask(task);
                    SurgoNotice.show(
                      context,
                      refusal == null
                          ? 'Accepted — this is now your active errand.'
                          : refusal.label,
                      tone: refusal == null
                          ? SbNoticeTone.success
                          : SbNoticeTone.warning,
                    );
                  },
                ),
                const SizedBox(height: 10),
              ] else if (helperMode &&
                  task.helperId == state.earner.id &&
                  task.status.advanceActionLabel != null) ...[
                SbPrimaryButton(
                  label: task.status.advanceActionLabel!,
                  icon: Icons.arrow_forward_rounded,
                  onPressed: () {
                    state.advancePasuyoTask(task);
                    SurgoNotice.show(context, task.status.label,
                        tone: SbNoticeTone.info);
                  },
                ),
                const SizedBox(height: 10),
              ],
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
              // Reporting stays available after delivery: a problem with the
              // errand often only shows up once the goods have arrived, so
              // hiding this behind the in-progress state left completed tasks
              // with no way to raise an issue at all.
              if (task.isComplete && task.rated)
                SbOutlineButton(
                  label: 'Report issue',
                  icon: Icons.flag_outlined,
                  block: true,
                  onPressed: () => _report(context, task),
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
              // No Navigator.pop here: this prompt is inline, not a sheet, so
              // popping would close the whole task screen and throw away the
              // receipt. Recording the rating rebuilds the card instead.
              onPressed: () => state.ratePasuyoTask(task, stars),
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
    SurgoNotice.show(
      context,
      'Report sent. Our team will review it within 24 hours.',
      tone: SbNoticeTone.success,
    );
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
/// Hosted errand detail: reads the database row by id and offers only the
/// actions the row's owner allows. Every button calls a database function that
/// re-checks the role and the legal transition, so a stale screen cannot push
/// an invalid move.
class _HostedPasuyoTaskScreen extends StatefulWidget {
  const _HostedPasuyoTaskScreen({
    required this.taskId,
    required this.helperMode,
  });

  final String taskId;
  final bool helperMode;

  @override
  State<_HostedPasuyoTaskScreen> createState() => _HostedPasuyoTaskScreenState();
}

class _HostedPasuyoTaskScreenState extends State<_HostedPasuyoTaskScreen> {
  ServiceRequestRecord? _record;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  final Map<String, TextEditingController> _costCtrls = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final ctrl in _costCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final record = await AppState.instance.repositories.pasuyo
          .fetchRequest(widget.taskId);
      if (!mounted) return;
      _syncCostControllers(record);
      setState(() {
        _record = record;
        _error = record == null ? 'This task is no longer available.' : null;
        _loading = false;
      });
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure.message;
        _loading = false;
      });
    }
  }

  void _syncCostControllers(ServiceRequestRecord? record) {
    if (record == null) return;
    for (final item in record.items) {
      final actual = item.actualUnitPriceCentavos;
      _costCtrls.putIfAbsent(
        item.id,
        () => TextEditingController(
          text: actual == null ? '' : (actual / 100).toStringAsFixed(2),
        ),
      );
    }
  }

  /// Runs one database action, reloads the row afterwards, and surfaces the
  /// server's refusal instead of pretending the button worked.
  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (!mounted) return;
      SurgoNotice.show(context, success, tone: SbNoticeTone.success);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      SurgoNotice.show(context, failure.message, tone: SbNoticeTone.warning);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(PasuyoTask task) => _run(
        () async {
          await AppState.instance.acceptHostedErrand(task);
        },
        'Accepted — this is now your active errand.',
      );

  Future<void> _advance(PasuyoTask task) => _run(
        () async {
          final updated = await AppState.instance.advanceHostedErrand(task);
          if (updated == null) {
            throw RepositoryFailure.unsupported('This errand has no next step.');
          }
        },
        'Errand updated.',
      );

  Future<void> _saveActuals(PasuyoTask task) async {
    final items = <Map<String, dynamic>>[];
    for (final item in _record!.items) {
      final raw = _costCtrls[item.id]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      final pesos = double.tryParse(raw);
      if (pesos == null || pesos < 0) {
        SurgoNotice.show(context, 'Enter a valid amount for ${item.name}.',
            tone: SbNoticeTone.warning);
        return;
      }
      items.add({
        'id': item.id,
        'actual_unit_price_centavos': (pesos * 100).round(),
        'quantity': item.quantity,
      });
    }
    if (items.isEmpty) {
      SurgoNotice.show(context, 'Enter at least one item price.',
          tone: SbNoticeTone.warning);
      return;
    }
    await _run(
      () => AppState.instance.setHostedErrandActuals(task, items),
      'Item costs saved.',
    );
  }

  void _confirmCancel(PasuyoTask task) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Cancel this errand?'),
        content: Text(
          widget.helperMode
              ? 'The customer will be notified and the errand will leave their queue.'
              : 'The helper will be notified and you will not be charged.',
          style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _run(
                () => AppState.instance.cancelHostedErrand(task),
                'Errand cancelled.',
              );
            },
            child: const Text('Cancel errand',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pasuyo Task')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final record = _record;
    if (record == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pasuyo Task')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error ?? 'This task is no longer available.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted)),
          ),
        ),
      );
    }

    final task = pasuyoTaskFromRecord(record);
    final breakdown = AppState.instance.hostedErrandBreakdown(task);
    final userId = AppState.instance.identity?.userId;
    final isAssignedHelper =
        record.providerId != null && record.providerId == userId;
    final canEnterCosts = widget.helperMode &&
        isAssignedHelper &&
        !record.status.isTerminal &&
        record.status != PasuyoStatus.available;
    final helperAction = widget.helperMode &&
            isAssignedHelper &&
            record.status.advanceActionLabel != null
        ? record.status.advanceActionLabel
        : null;
    final customerPays = task.budget + breakdown.surgoKeeps + task.itemCost;

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
                child:
                    Icon(task.category.icon, size: 19, color: AppColors.yellow),
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
              SbTag(record.status.shortLabel,
                  secondary: record.status == PasuyoStatus.delivered),
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
                if (task.dropoff.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _line(Icons.place_outlined, 'Drop-off', task.dropoff,
                      AppColors.primary),
                ],
                if (task.bookedForSomeone) ...[
                  const SizedBox(height: 10),
                  _line(
                    Icons.person_outline,
                    'Recipient',
                    task.recipientPhone.isEmpty
                        ? task.recipientName
                        : '${task.recipientName} · ${task.recipientPhone}',
                    AppColors.yellow,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (record.items.isNotEmpty)
            SbCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Items',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12.5)),
                  const SizedBox(height: 8),
                  ...record.items.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.circle,
                                size: 5, color: AppColors.muted2),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(item.name,
                                  style: const TextStyle(fontSize: 12)),
                            ),
                            Text(
                              item.actualUnitPriceCentavos != null
                                  ? Money.format(
                                      item.actualUnitPriceCentavos!)
                                  : item.estimatedUnitPriceCentavos != null
                                      ? '~${Money.format(item.estimatedUnitPriceCentavos!)}'
                                      : '',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 11),
                            ),
                          ],
                        ),
                      )),
                  if (record.description != null &&
                      record.description!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('“${record.description}”',
                        style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11.5,
                            fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
          if (record.providerName != null) ...[
            const SizedBox(height: 14),
            SbCard(
              child: Row(
                children: [
                  SbAvatar(initials: _initials(record.providerName!), size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(record.providerName!,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12.5)),
                        const Text('Assigned helper',
                            style: TextStyle(
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
          SbCard(
            borderColor: AppColors.secondary.withValues(alpha: 0.3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Fee breakdown',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12.5)),
                const SizedBox(height: 12),
                _row('Helper fee', Money.format(task.budget)),
                const SizedBox(height: 7),
                _row('Platform fee', Money.format(breakdown.surgoKeeps),
                    color: AppColors.yellow),
                if (task.itemCost > 0) ...[
                  const SizedBox(height: 7),
                  _row('Item cost (paid in cash)',
                      Money.format(task.itemCost),
                      color: AppColors.secondaryLight),
                ],
                const Divider(height: 20),
                _row('Customer pays in cash', Money.format(customerPays),
                    bold: true),
                const SizedBox(height: 3),
                const Text(
                    'Cash changes hands on delivery; SurGo does not hold the money.',
                    style: TextStyle(color: AppColors.muted, fontSize: 10.5)),
              ],
            ),
          ),
          if (canEnterCosts) ...[
            const SizedBox(height: 14),
            _actualsCard(task),
          ],
          const SizedBox(height: 18),
          if (widget.helperMode && record.status.isOpen) ...[
            SbPrimaryButton(
              label: _busy ? 'Accepting…' : 'Accept task',
              icon: Icons.handshake_outlined,
              background: AppColors.yellow,
              onAccent: true,
              onPressed: _busy ? null : () => _accept(task),
            ),
            const SizedBox(height: 10),
          ] else if (helperAction != null) ...[
            SbPrimaryButton(
              label: _busy ? 'Saving…' : helperAction,
              icon: Icons.arrow_forward_rounded,
              onPressed: _busy ? null : () => _advance(task),
            ),
            const SizedBox(height: 10),
          ],
          if (!record.status.isTerminal)
            SbOutlineButton(
              label: 'Cancel errand',
              icon: Icons.close_rounded,
              onPressed: _busy ? null : () => _confirmCancel(task),
            ),
          if (record.status == PasuyoStatus.cancelled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                record.cancellationReason == null
                    ? 'This errand was cancelled. No payment was taken.'
                    : 'Cancelled: ${record.cancellationReason}',
                style:
                    const TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actualsCard(PasuyoTask task) {
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('What did you actually pay?',
              style:
                  TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
          const SizedBox(height: 4),
          const Text(
              'Record the unit price for each item so the customer is reimbursed the real amount.',
              style: TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 12),
          ..._record!.items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(item.name,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _costCtrls[item.id],
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: const TextStyle(fontSize: 12.5),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixText: '₱ ',
                          hintText: '0.00',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
          SbPrimaryButton(
            label: _busy ? 'Saving…' : 'Save item costs',
            icon: Icons.save_outlined,
            onPressed: _busy ? null : () => _saveActuals(task),
          ),
        ],
      ),
    );
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
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
