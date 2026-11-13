import 'dart:async';

import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../repositories/repository_registry.dart';
import '../widgets/flow_scaffold.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/pasuyo_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';
import '../widgets/route_preview.dart';
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

  const PasuyoTaskScreen({
    super.key,
    required this.taskId,
    this.helperMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.usesHostedIdentity && state.repositories.isSupabaseBacked) {
          return _HostedPasuyoTaskScreen(
            taskId: taskId,
            helperMode: helperMode,
          );
        }
        final matches = state.pasuyoTasks.where((t) => t.id == taskId).toList();
        if (matches.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('Pasuyo')),
            body: const Center(
              child: Text('This task is no longer available.'),
            ),
          );
        }
        final task = matches.first;
        final breakdown = FeeCalculator.breakdownFor(
          ServiceType.pasuyo,
          task.budget,
        );
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
                    child: Icon(
                      task.category.icon,
                      size: 19,
                      color: AppColors.yellow,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${task.category.label} · ${task.requestedAt}',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                          ),
                        ),
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
                        Text(
                          task.statusLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          task.stepLabel,
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _PasuyoProgress(task: task),
                    if (task.helperId != null &&
                        task.pickupPoint != null &&
                        task.dropoffPoint != null) ...[
                      const SizedBox(height: 14),
                      SbRoutePreview(
                        start: task.pickupPoint!,
                        end: task.dropoffPoint!,
                        startLabel: 'Pickup',
                        endLabel: 'Drop-off',
                      ),
                    ],
                    const SizedBox(height: 16),
                    _line(
                      Icons.storefront_outlined,
                      'Pickup',
                      task.pickup,
                      AppColors.secondary,
                    ),
                    const SizedBox(height: 10),
                    _line(
                      Icons.place_outlined,
                      'Drop-off',
                      task.dropoff,
                      AppColors.primary,
                    ),
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
              if (task.items.isNotEmpty)
                SbCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Items',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...task.items.map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.circle,
                                size: 5,
                                color: AppColors.muted2,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (task.note.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '“${task.note}”',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11.5,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
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
                            Text(
                              helper.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                            Text(
                              '★ ${helper.rating.toStringAsFixed(1)} · ${helper.vehicleModel}',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.verified,
                        size: 16,
                        color: AppColors.secondaryLight,
                      ),
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
                    SurgoNotice.show(
                      context,
                      task.status.label,
                      tone: SbNoticeTone.info,
                    );
                  },
                ),
                const SizedBox(height: 10),
              ],
              if (!helperMode && task.isComplete && !task.rated)
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
              if (task.isComplete && (helperMode || task.rated))
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
              const SizedBox(height: 14),
              const _BackToHome(),
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
          const Text(
            'Fee breakdown',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          _row('Customer pays', b.customerPaysLabel, bold: true),
          const SizedBox(height: 7),
          _row(
            'Helper gets',
            b.providerGetsLabel,
            color: AppColors.secondaryLight,
          ),
          const SizedBox(height: 7),
          _row('SurGo keeps (15%)', b.surgoKeepsLabel, color: AppColors.yellow),
        ],
      ),
    );
  }

  Widget _ratePrompt(BuildContext context, AppState state, PasuyoTask task) {
    var stars = 5;
    return StatefulBuilder(
      builder: (ctx, setSheet) => SbCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Rate your helper',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            Row(
              children: List.generate(5, (i) {
                final filled = i < stars;
                return IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
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
            child: const Text(
              'Cancel task',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _report(BuildContext context, PasuyoTask task) {
    SurgoNotice.show(
      context,
      'Demo only: issue reporting is not connected. No report or support ticket was sent.',
      tone: SbNoticeTone.info,
    );
  }

  MapRider? _helperFor(AppState state, PasuyoTask task) {
    if (task.helperId == null) return null;
    final matches = state.db.mapRiders
        .where((r) => r.id == task.helperId)
        .toList();
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
          child: Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              color: bold ? AppColors.text : AppColors.muted,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: color ?? AppColors.text,
          ),
        ),
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
  State<_HostedPasuyoTaskScreen> createState() =>
      _HostedPasuyoTaskScreenState();
}

class _HostedPasuyoTaskScreenState extends State<_HostedPasuyoTaskScreen> {
  ServiceRequestRecord? _record;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _writing = false;
  bool _reloadPending = false;
  int _generation = 0;
  int _revision = 0;
  Future<void>? _readDrain;
  RepositoryRegistry? _registry;
  String? _userId;
  String? _accountId;
  StreamSubscription<void>? _subscription;
  Timer? _reconciliation;
  final Map<String, TextEditingController> _costCtrls = {};
  final Map<String, String> _serverCostTexts = {};

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onAppChanged);
    _bindSession();
  }

  @override
  void didUpdateWidget(covariant _HostedPasuyoTaskScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) _bindSession();
  }

  bool get _sessionMatches {
    final state = AppState.instance;
    return identical(_registry, state.repositories) &&
        _userId == state.identity?.userId &&
        _accountId == state.currentAccount?.id &&
        state.usesHostedIdentity &&
        state.repositories.isSupabaseBacked;
  }

  bool _isCurrent(int generation) =>
      mounted && generation == _generation && _sessionMatches;

  void _onAppChanged() {
    if (!mounted) return;
    if (!_sessionMatches) {
      setState(_bindSession);
    }
  }

  void _bindSession() {
    _generation++;
    _revision++;
    unawaited(_subscription?.cancel().catchError((Object _) {}));
    _subscription = null;
    _reconciliation?.cancel();
    _reconciliation = null;
    _readDrain = null;
    _reloadPending = false;
    _busy = false;
    _writing = false;
    _record = null;
    for (final ctrl in _costCtrls.values) {
      ctrl.dispose();
    }
    _costCtrls.clear();
    _serverCostTexts.clear();
    final state = AppState.instance;
    _registry = state.repositories;
    _userId = state.identity?.userId;
    _accountId = state.currentAccount?.id;
    _loading = _sessionMatches && _userId != null && state.isSignedIn;
    _error = _loading ? null : 'Sign in again to view this errand.';
    if (!_loading) return;
    final generation = _generation;
    // Events are invalidations only. The authenticated repository and RLS own
    // the status, participants and receipt, never the event payload.
    try {
      _subscription = _registry!.realtime
          ?.watchRows(
            table: 'service_requests',
            column: 'id',
            value: widget.taskId,
          )
          .listen(
            (_) {
              if (_isCurrent(generation)) unawaited(_load());
            },
            onError: (Object error) {
              if (_isCurrent(generation)) unawaited(_load());
            },
          );
    } catch (_) {
      // Reconciliation remains available if subscribing is unavailable.
    }
    _reconciliation = Timer.periodic(const Duration(seconds: 15), (_) {
      _onAppChanged();
      if (_isCurrent(generation)) unawaited(_load());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    AppState.instance.removeListener(_onAppChanged);
    unawaited(_subscription?.cancel().catchError((Object _) {}));
    _reconciliation?.cancel();
    for (final ctrl in _costCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() {
    if (!_isCurrent(_generation) ||
        _userId == null ||
        !AppState.instance.isSignedIn) {
      return Future<void>.value();
    }
    _reloadPending = true;
    if (_writing) return _readDrain ?? Future<void>.value();
    // Install the future before starting: a burst of events shares one drain
    // and at most one queued reconciliation read, not parallel snapshots.
    final generation = _generation;
    return _readDrain ??= Future<void>.microtask(() => _drainReads(generation));
  }

  Future<void> _drainReads(int generation) async {
    if (!_isCurrent(generation)) return;
    final registry = _registry!;
    final taskId = widget.taskId;
    try {
      while (_isCurrent(generation) && _reloadPending && !_writing) {
        _reloadPending = false;
        final revision = _revision;
        try {
          final record = await registry.pasuyo
              .fetchRequest(taskId)
              .timeout(const Duration(seconds: 20));
          if (!_isCurrent(generation)) return;
          if (revision != _revision) continue;
          if (record != null && record.id != taskId) {
            throw RepositoryFailure.invalidData(
              'The errand service returned a different task.',
            );
          }
          _syncCostControllers(record);
          setState(() {
            _record = record;
            _error = record == null
                ? 'This task is no longer available.'
                : null;
            _loading = false;
          });
        } catch (error) {
          if (!_isCurrent(generation)) return;
          if (revision != _revision) continue;
          final failure = mapBackendError(error);
          setState(() {
            _error = failure.message;
            _loading = false;
            // An authorization refusal must not leave another account's data
            // on screen; transient outages keep the last confirmed receipt.
            if (failure.isPermissionProblem ||
                failure.kind == RepositoryFailureKind.notFound) {
              _record = null;
            }
          });
        }
      }
    } finally {
      if (mounted && generation == _generation) _readDrain = null;
    }
  }

  void _syncCostControllers(ServiceRequestRecord? record) {
    if (record == null) return;
    for (final item in record.items) {
      final actual = item.actualUnitPriceCentavos;
      final text = actual == null ? '' : (actual / 100).toStringAsFixed(2);
      final ctrl = _costCtrls[item.id];
      if (ctrl == null) {
        _costCtrls[item.id] = TextEditingController(text: text);
      } else if (ctrl.text == _serverCostTexts[item.id] && ctrl.text != text) {
        // Refresh clean fields, but never erase an unsaved helper draft when
        // a reconciliation read arrives while they are typing.
        ctrl.text = text;
      }
      _serverCostTexts[item.id] = text;
    }
  }

  /// Runs one database action, reloads the row afterwards, and surfaces the
  /// server's refusal instead of pretending the button worked.
  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy || !_isCurrent(_generation) || _record == null) return;
    final generation = _generation;
    _revision++;
    setState(() {
      _busy = true;
      _writing = true;
    });
    try {
      await action();
      if (!mounted || !_isCurrent(generation)) return;
      SurgoNotice.show(context, success, tone: SbNoticeTone.success);
    } catch (error) {
      if (!mounted || !_isCurrent(generation)) return;
      SurgoNotice.show(
        context,
        mapBackendError(error).message,
        tone: SbNoticeTone.warning,
      );
    } finally {
      if (_isCurrent(generation)) {
        _writing = false;
        _revision++;
        // Invalidate even on a refusal: an intervening helper/customer action
        // may have changed the legal controls. Pre-write reads cannot apply.
        await _load();
        if (_isCurrent(generation)) setState(() => _busy = false);
      }
    }
  }

  Future<void> _accept(PasuyoTask task) => _run(() async {
    await AppState.instance.acceptHostedErrand(task);
  }, 'Accepted — this is now your active errand.');

  Future<void> _advance(PasuyoTask task) => _run(() async {
    final updated = await AppState.instance.advanceHostedErrand(task);
    if (updated == null) {
      throw RepositoryFailure.unsupported('This errand has no next step.');
    }
  }, 'Errand updated.');

  Future<void> _saveActuals(PasuyoTask task) async {
    if (_busy || _record == null || !_isCurrent(_generation)) return;
    final items = <Map<String, dynamic>>[];
    for (final item in _record!.items) {
      final raw = _costCtrls[item.id]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      final pesos = double.tryParse(raw);
      if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(raw) ||
          pesos == null ||
          !pesos.isFinite ||
          pesos < 0 ||
          !(pesos * 100).isFinite) {
        SurgoNotice.show(
          context,
          'Enter a valid amount for ${item.name}.',
          tone: SbNoticeTone.warning,
        );
        return;
      }
      items.add({
        'id': item.id,
        'actual_unit_price_centavos': (pesos * 100).round(),
        'quantity': item.quantity,
      });
    }
    if (items.isEmpty) {
      SurgoNotice.show(
        context,
        'Enter at least one item price.',
        tone: SbNoticeTone.warning,
      );
      return;
    }
    await _run(
      () => AppState.instance.setHostedErrandActuals(task, items),
      'Item costs saved.',
    );
  }

  void _confirmCancel(PasuyoTask task) {
    if (_busy || !_isCurrent(_generation)) return;
    final generation = _generation;
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
              if (!_isCurrent(generation) ||
                  _record?.status.isTerminal != false) {
                return;
              }
              _run(
                () => AppState.instance.cancelHostedErrand(task),
                'Errand cancelled.',
              );
            },
            child: const Text(
              'Cancel errand',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_sessionMatches) {
      // Repository installation does not necessarily notify AppState. Hide the
      // previous snapshot immediately and bind after this build completes.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onAppChanged());
      return Scaffold(
        appBar: AppBar(title: const Text('Pasuyo Task')),
        body: const Center(child: _BackToHome()),
      );
    }
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error ?? 'This task is no longer available.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                if (_userId != null && AppState.instance.isSignedIn)
                  SbOutlineButton(label: 'Retry', onPressed: () => _load()),
                const SizedBox(height: 10),
                const _BackToHome(),
              ],
            ),
          ),
        ),
      );
    }

    final task = pasuyoTaskFromRecord(record);
    final breakdown = AppState.instance.hostedErrandBreakdown(task);
    final userId = AppState.instance.identity?.userId;
    final isAssignedHelper =
        record.providerId != null && record.providerId == userId;
    final isCustomer = record.customerId == userId;
    final canAccept = widget.helperMode && record.status.isOpen && !isCustomer;
    final canCancel = widget.helperMode ? isAssignedHelper : isCustomer;
    final canEnterCosts =
        widget.helperMode &&
        isAssignedHelper &&
        !record.status.isTerminal &&
        record.status != PasuyoStatus.available;
    final helperAction =
        widget.helperMode &&
            isAssignedHelper &&
            record.status.advanceActionLabel != null
        ? record.status.advanceActionLabel
        : null;
    final customerPays = task.budget + breakdown.surgoKeeps + task.itemCost;

    return Scaffold(
      appBar: AppBar(title: const Text('Pasuyo Task')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
          children: [
            if (_error != null) ...[
              Text(
                'Could not refresh: $_error',
                style: const TextStyle(color: AppColors.danger, fontSize: 12),
              ),
              const SizedBox(height: 12),
            ],
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
                  child: Icon(
                    task.category.icon,
                    size: 19,
                    color: AppColors.yellow,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${task.category.label} · ${task.requestedAt}',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SbTag(
                  record.status.shortLabel,
                  secondary: record.status == PasuyoStatus.delivered,
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
                      Text(
                        task.statusLabel,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        task.stepLabel,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _PasuyoProgress(task: task),
                  if (task.helperId != null &&
                      task.pickupPoint != null &&
                      task.dropoffPoint != null) ...[
                    const SizedBox(height: 14),
                    SbRoutePreview(
                      start: task.pickupPoint!,
                      end: task.dropoffPoint!,
                      startLabel: 'Pickup',
                      endLabel: 'Drop-off',
                    ),
                  ],
                  const SizedBox(height: 16),
                  _line(
                    Icons.storefront_outlined,
                    'Pickup',
                    task.pickup,
                    AppColors.secondary,
                  ),
                  if (task.dropoff.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _line(
                      Icons.place_outlined,
                      'Drop-off',
                      task.dropoff,
                      AppColors.primary,
                    ),
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
                    const Text(
                      'Items',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...record.items.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.circle,
                              size: 5,
                              color: AppColors.muted2,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                item.name,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Text(
                              item.actualUnitPriceCentavos != null
                                  ? Money.format(item.actualUnitPriceCentavos!)
                                  : item.estimatedUnitPriceCentavos != null
                                  ? '~${Money.format(item.estimatedUnitPriceCentavos!)}'
                                  : '',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (record.description != null &&
                        record.description!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '“${record.description}”',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (record.providerName != null) ...[
              const SizedBox(height: 14),
              SbCard(
                child: Row(
                  children: [
                    SbAvatar(
                      initials: _initials(record.providerName!),
                      size: 38,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            record.providerName!,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                          const Text(
                            'Assigned helper',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.verified,
                      size: 16,
                      color: AppColors.secondaryLight,
                    ),
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
                  const Text(
                    'Fee breakdown',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _row('Helper fee', Money.format(task.budget)),
                  const SizedBox(height: 7),
                  _row(
                    'Platform fee',
                    Money.format(breakdown.surgoKeeps),
                    color: AppColors.yellow,
                  ),
                  if (task.itemCost > 0) ...[
                    const SizedBox(height: 7),
                    _row(
                      'Item cost (paid in cash)',
                      Money.format(task.itemCost),
                      color: AppColors.secondaryLight,
                    ),
                  ],
                  const Divider(height: 20),
                  _row(
                    'Customer pays in cash',
                    Money.format(customerPays),
                    bold: true,
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Cash changes hands on delivery; SurGo does not hold the money.',
                    style: TextStyle(color: AppColors.muted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
            if (canEnterCosts) ...[
              const SizedBox(height: 14),
              _actualsCard(task),
            ],
            const SizedBox(height: 18),
            if (canAccept) ...[
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
            if (canCancel && !record.status.isTerminal)
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
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                  ),
                ),
              ),
            if (task.isComplete) ...[
              const SizedBox(height: 12),
              const Text(
                'Errand delivered. Your cash receipt stays available here.',
                style: TextStyle(color: AppColors.secondaryLight, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            const _BackToHome(),
          ],
        ),
      ),
    );
  }

  Widget _actualsCard(PasuyoTask task) {
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'What did you actually pay?',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
          ),
          const SizedBox(height: 4),
          const Text(
            'Record the unit price for each item so the cash receipt uses the real amount.',
            style: TextStyle(color: AppColors.muted, fontSize: 11),
          ),
          const SizedBox(height: 12),
          ..._record!.items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _costCtrls[item.id],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
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
            ),
          ),
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
          child: Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              color: bold ? AppColors.text : AppColors.muted,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: color ?? AppColors.text,
          ),
        ),
      ],
    );
  }
}

class _BackToHome extends StatelessWidget {
  const _BackToHome();

  @override
  Widget build(BuildContext context) => SbOutlineButton(
    label: 'Back to Home',
    icon: Icons.home_outlined,
    onPressed: () => Navigator.of(context).popUntil(
      (route) =>
          route.isFirst ||
          const {'/home', '/earner', '/owner'}.contains(route.settings.name),
    ),
  );
}

class _PasuyoProgress extends StatelessWidget {
  const _PasuyoProgress({required this.task});
  final PasuyoTask task;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 250);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: AnimatedSwitcher(
            duration: duration,
            child: task.isOpen
                ? const Center(
                    key: ValueKey(PasuyoStatus.available),
                    child: SbSearchRadar(size: 76),
                  )
                : Row(
                    key: ValueKey(task.status),
                    children: [
                      Icon(
                        task.isComplete
                            ? Icons.check_circle_outline
                            : task.isCancelled
                            ? Icons.cancel_outlined
                            : Icons.handshake_outlined,
                        size: 20,
                        color: AppColors.secondaryLight,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          task.statusLabel,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 10),
        PasuyoStepper(task: task),
        if (!task.isCancelled) ...[
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            duration: duration,
            tween: Tween(end: task.stepIndex / (PasuyoStatus.flow.length - 1)),
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              color: AppColors.yellow,
              backgroundColor: AppColors.panel3,
              semanticsLabel: task.statusLabel,
            ),
          ),
        ],
      ],
    );
  }
}
