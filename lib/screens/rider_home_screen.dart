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
import '../widgets/ride_request_card.dart';
import '../widgets/surfaces.dart';
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 90),
          children: [
            Row(
              children: [
                Expanded(child: _identityBlock()),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Row(
                      children: [
                        SbIconButton(
                          icon: Icons.map_outlined,
                          onTap: () =>
                              Navigator.pushNamed(context, '/map/earner'),
                        ),
                        const SizedBox(width: 8),
                        SbIconButton(
                          icon: Icons.notifications_none,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const NotificationsScreen(isRider: true)),
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      top: -2,
                      right: -2,
                      child: RepositoryInline<int>(
                        slot: DomainSlot.unreadEarnerNotifications,
                        data: (context, unread) => unread == 0
                            ? const SizedBox.shrink()
                            : Container(
                                width: 15,
                                height: 15,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(
                                    color: AppColors.secondary,
                                    shape: BoxShape.circle),
                                child: Text(
                                  '$unread',
                                  style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.onAccent),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SbTintedCard(
              tone: state.riderOnline ? SbTone.success : SbTone.neutral,
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: state.riderOnline
                          ? AppColors.secondary
                          : AppColors.muted2,
                      shape: BoxShape.circle,
                      boxShadow: state.riderOnline
                          ? [
                              const BoxShadow(
                                  color: AppColors.secondarySoft,
                                  blurRadius: 0,
                                  spreadRadius: 3)
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            state.riderOnline
                                ? "You're Online"
                                : "You're Offline",
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 13)),
                        const Text('Visible for new ride requests',
                            style: TextStyle(
                                color: AppColors.muted, fontSize: 11)),
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
                Expanded(
                    child: _statBox(
                        Money.format(state.earningsToday), 'Earnings')),
                const SizedBox(width: 8),
                Expanded(
                    child: _statBox(
                        '${state.riderTrips.where((t) => t.status == 'Completed').length}',
                        'Trips')),
                const SizedBox(width: 8),
                Expanded(
                    child: _statBox(
                        Money.format(state.earningsWeek), 'This Week')),
              ],
            ),
            const SizedBox(height: 18),
            if (state.activeRide != null)
              SbActiveRideBanner(ride: state.activeRide!),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Incoming Requests',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
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
                child: Text('No pending requests right now.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
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
        appBar: AppBar(
            automaticallyImplyLeading: false, title: const Text('Rider Mode')),
        body: content,
      ),
    );
  }

  /// The earner this build is acting as, read through the repository layer.
  ///
  /// Only the profile record speaks here: a seeded build gets the seeded earner
  /// row and a Supabase build gets the signed-in account's own row. The old
  /// `Earner ID` line is deliberately gone rather than read from the record —
  /// `profiles.id` is an auth uuid in a Supabase build, and a name from one
  /// source with an id from another is the disagreement this layer exists to
  /// prevent. The summary line keeps to the two fields that mean the same
  /// thing in both: the account's rating and the year its row was created.
  Widget _identityBlock() {
    return RepositoryView<ProfileRecord>(
      slot: DomainSlot.earnerProfile,
      loading: _identityWaiting('Loading your profile…'),
      empty: (_) => _identityWaiting('No earner profile on this account'),
      failure: (_, failure) => _identityWaiting(failure.message),
      data: (context, profile) {
        final since = profile.createdAt?.year;
        return Row(
          children: [
            SbAvatar(initials: initialsFor(profile.fullName)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.fullName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  Text(
                    since == null
                        ? '⭐ ${profile.rating}'
                        : '⭐ ${profile.rating} · Since $since',
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// The same header space while the read has no answer for it.
  ///
  /// The avatar stays, so the row does not move when the profile lands, and the
  /// message takes the name's place rather than inventing one.
  Widget _identityWaiting(String message) {
    return Row(
      children: [
        const SbAvatar(initials: '?'),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message,
              style: const TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 14)),
        ),
      ],
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
    return SbTintedCard(
      tone: SbTone.wallet,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: SbTone.wallet.accent)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 10)),
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
        MaterialPageRoute(
            builder: (_) =>
                PasuyoTaskScreen(taskId: task.id, helperMode: true)),
      ),
      child: SbTintedCard(
        tone: SbTone.pasuyo,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SbToneIcon(
                  tone: SbTone.pasuyo,
                  icon: task.category.icon,
                  size: 30,
                  iconSize: 16,
                ),
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
                  child: Text(
                      'You keep ${b.providerGetsLabel} of ${b.customerPaysLabel}',
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
        MaterialPageRoute(
            builder: (_) =>
                PasuyoTaskScreen(taskId: task.id, helperMode: true)),
      ),
      child: SbTintedCard(
        tone: SbTone.pasuyo,
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
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12.5)),
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
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 11.5),
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
