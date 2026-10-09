import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';
import '../widgets/ride_request_card.dart';
import 'notifications_screen.dart';
import 'pasuyo_task_screen.dart';

/// The rider's home dashboard tab. When [embedded] (the normal case, inside
/// [RiderShell]) this renders without its own Scaffold/bottom nav — the
/// shell supplies those and handles the sliding Home/Trips/Earnings/Profile
/// tab transitions.
class RiderHomeScreen extends StatelessWidget {
  final bool embedded;
  const RiderHomeScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final content = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final earner = state.db.earner;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 90),
          children: [
            Row(
              children: [
                SbAvatar(initials: earner.initials),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(earner.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      Text('Earner ID ${earner.id}', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                    ],
                  ),
                ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Row(
                      children: [
                        SbIconButton(
                          icon: Icons.map_outlined,
                          onTap: () => Navigator.pushNamed(context, '/map/earner'),
                        ),
                        const SizedBox(width: 8),
                        SbIconButton(
                          icon: Icons.notifications_none,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const NotificationsScreen(isRider: true)),
                          ),
                        ),
                      ],
                    ),
                    if (state.unreadRiderNotifications > 0)
                      Positioned(
                        top: -2,
                        right: -2,
                        child: Container(
                          width: 15,
                          height: 15,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: AppColors.secondary, shape: BoxShape.circle),
                          child: Text(
                            '${state.unreadRiderNotifications}',
                            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: AppColors.onAccent),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SbCard(
              borderColor: AppColors.secondary.withValues(alpha: 0.35),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: state.riderOnline ? AppColors.secondary : AppColors.muted2,
                      shape: BoxShape.circle,
                      boxShadow: state.riderOnline
                          ? [const BoxShadow(color: AppColors.secondarySoft, blurRadius: 0, spreadRadius: 3)]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(state.riderOnline ? "You're Online" : "You're Offline",
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        const Text('Visible for new ride requests',
                            style: TextStyle(color: AppColors.muted, fontSize: 11)),
                      ],
                    ),
                  ),
                  Switch(
                    value: state.riderOnline,
                    activeColor: Colors.white,
                    activeTrackColor: AppColors.secondary,
                    inactiveTrackColor: AppColors.panel2,
                    onChanged: (_) => state.toggleRiderOnline(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _statBox(Money.format(state.earningsToday), 'Earnings')),
                const SizedBox(width: 8),
                Expanded(child: _statBox('${state.riderTrips.where((t) => t.status == 'Completed').length}', 'Trips')),
                const SizedBox(width: 8),
                Expanded(child: _statBox('5h 20m', 'Online')),
              ],
            ),
            const SizedBox(height: 18),
            if (state.activeRide != null) SbActiveRideBanner(ride: state.activeRide!),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Incoming Requests', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                SbTag('${state.pendingRequests.length} New', secondary: true),
              ],
            ),
            const SizedBox(height: 10),
            if (!state.riderOnline)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  "You're offline — go online to receive ride requests.",
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              )
            else if (state.pendingRequests.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No pending requests right now.', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              )
            else
              ...state.pendingRequests.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SbRideRequestCard(request: r),
                ),
              ),
            _pasuyoSection(context, state),
          ],
        );
      },
    );

    if (embedded) return SafeArea(bottom: false, child: content);

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(automaticallyImplyLeading: false, title: const Text('Rider Mode')),
        body: content,
      ),
    );
  }

  /// Helper mode lives on the rider account, so the Pasuyo work sits directly
  /// under the incoming ride requests. An active task takes over the list —
  /// finishing an errand in progress matters more than chasing a new one.
  Widget _pasuyoSection(BuildContext context, AppState state) {
    final active = state.activePasuyoTask;
    final nearby = state.nearbyPasuyoTasks;
    // The feed is gated on capabilities, so an empty list is ambiguous: it can
    // mean "nothing posted" or "you don't take errands". Those need different
    // copy, and only the earner knows which is true.
    final canTakeErrands = state.acceptsCapability(EarnerCapability.errands) ||
        state.acceptsCapability(EarnerCapability.deliveries);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Nearby Pasuyo',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
            SbTag('${nearby.length} Open', secondary: true),
          ],
        ),
        const SizedBox(height: 10),
        if (active != null) ...[
          _ActivePasuyoCard(task: active, state: state),
          const SizedBox(height: 10),
        ],
        if (!canTakeErrands && active == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Errands are off. Turn on Errands or Deliveries in Profile to see work here.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          )
        else if (nearby.isEmpty && active == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No open errands nearby right now.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          )
        else
          ...nearby.map((task) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NearbyPasuyoCard(task: task, state: state),
              )),
      ],
    );
  }

  Widget _statBox(String value, String label) {
    return SbCard(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.primaryLight)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 10)),
        ],
      ),
    );
  }
}

/// An open errand the helper can claim, with the split shown up front so
/// they know what they earn before accepting.
class _NearbyPasuyoCard extends StatelessWidget {
  final PasuyoTask task;
  final AppState state;
  const _NearbyPasuyoCard({required this.task, required this.state});

  @override
  Widget build(BuildContext context) {
    final b = FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);
    // Tapping anywhere on the card opens the errand. The whole card is the
    // affordance rather than a small button inside it, so the feed reads as a
    // list and the details screen owns every action.
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: task.id, helperMode: true)),
      ),
      child: SbCard(
      borderColor: AppColors.yellow.withValues(alpha: 0.25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(task.category.icon, size: 17, color: AppColors.yellow),
              const SizedBox(width: 9),
              Expanded(
                child: Text(task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12.5)),
              ),
              Text(b.providerGetsLabel,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: AppColors.secondaryLight)),
            ],
          ),
          const SizedBox(height: 4),
          Text('${task.pickup} → ${task.dropoff}',
              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 10),
          // Read-only: claiming the errand lives on the details screen, so the
          // feed is a browse list and every card has exactly one job, which is
          // to open the errand.
          Row(
            children: [
              Expanded(
                child: Text('You keep ${b.providerGetsLabel} of ${b.customerPaysLabel}',
                    style: const TextStyle(
                        color: AppColors.muted2, fontSize: 10.5)),
              ),
              const SizedBox(width: 10),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.muted2),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

/// The errand this helper is working: progress stepper plus one button that
/// advances it, labelled with whatever comes next.
class _ActivePasuyoCard extends StatelessWidget {
  final PasuyoTask task;
  final AppState state;
  const _ActivePasuyoCard({required this.task, required this.state});

  @override
  Widget build(BuildContext context) {
    final next = task.nextStatus;
    // Tappable like the feed cards: the banner reports progress and sends the
    // helper to the details screen, which is where the action buttons live.
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: task.id, helperMode: true)),
      ),
      child: SbCard(
      borderColor: AppColors.secondary.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Active task',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12.5)),
              ),
              SbTag(task.status.shortLabel, secondary: true),
            ],
          ),
          const SizedBox(height: 10),
          Text(task.title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
          const SizedBox(height: 12),
          PasuyoStepper(task: task),
          const SizedBox(height: 12),
          // Progress only. The advance button is deliberately absent here: one
          // screen per task owns its actions, so a stray tap on a banner in the
          // feed cannot skip a step.
          Row(
            children: [
              Expanded(
                child: Text(
                  next == null
                      ? 'Waiting for the customer to rate this task.'
                      : 'Next: ${task.status.advanceActionLabel}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ),
              const SizedBox(width: 10),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.muted2),
            ],
          ),
        ],
      ),
      ),
    );
  }
}
