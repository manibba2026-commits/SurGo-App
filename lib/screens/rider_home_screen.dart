import 'dart:async';

import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/pasuyo_stepper.dart';
import '../widgets/repository_states.dart';
import '../widgets/ride_request_card.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';
import 'notifications_screen.dart';
import 'pasuyo_task_screen.dart';

/// The rider's home dashboard tab. When [embedded] (the normal case, inside
/// [RiderShell]) this renders without its own Scaffold/bottom nav — the
/// shell supplies those and handles the sliding Home/Trips/Earnings/Profile
/// tab transitions.
class RiderHomeScreen extends StatefulWidget {
  final bool embedded;
  const RiderHomeScreen({super.key, this.embedded = true});

  @override
  State<RiderHomeScreen> createState() => _RiderHomeScreenState();
}

class _RiderHomeScreenState extends State<RiderHomeScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Requests are assigned from the passenger side, so the rider's inbox has
    // to be re-read while this screen is open. Fifteen seconds keeps a demo
    // assignment visible without hammering the database.
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _refresh() {
    final state = AppState.instance;
    if (!state.usesHostedIdentity || !state.isSignedIn) return;
    unawaited(state.refreshRiderWorkspace().catchError((Object _) {}));
  }

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
            _onlineCard(context, state),
            const SizedBox(height: 14),
            if (state.usesHostedIdentity)
              _hostedStats()
            else
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
            _incomingSection(context, state),
            _pasuyoSection(context, state),
          ],
        );
      },
    );

    if (widget.embedded) return SafeArea(bottom: false, child: content);

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
            automaticallyImplyLeading: false, title: const Text('Rider Mode')),
        body: content,
      ),
    );
  }

  /// The online switch. A hosted build reads the presence row from Postgres;
  /// a seeded build keeps the in-memory flag the prototype has always used.
  Widget _onlineCard(BuildContext context, AppState state) {
    if (!state.usesHostedIdentity) {
      return _presenceCard(
        online: state.riderOnline,
        subtitle: 'Visible for new ride requests',
        onChanged: (_) => state.toggleRiderOnline(),
      );
    }
    return RepositoryView<RiderPresenceRecord>(
      slot: DomainSlot.riderPresence,
      loading: const SbListLoading(label: 'Loading your online status…'),
      empty: (_) => _presenceCard(
        online: false,
        subtitle: 'Go online to receive demo ride requests',
        onChanged: (value) => _setOnline(context, state, value),
      ),
      failure: (_, failure) => _presenceCard(
        online: false,
        subtitle: failure.message,
        onChanged: (value) => _setOnline(context, state, value),
      ),
      data: (context, presence) => _presenceCard(
        online: presence.isOnline,
        subtitle: presence.isOnline
            ? (presence.isSimulated
                ? 'Online · simulated demo position'
                : 'Visible for new ride requests')
            : 'You are hidden from passengers',
        onChanged: (value) => _setOnline(context, state, value),
      ),
    );
  }

  Widget _presenceCard({
    required bool online,
    required String subtitle,
    required ValueChanged<bool> onChanged,
  }) {
    return SbTintedCard(
      tone: online ? SbTone.success : SbTone.neutral,
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: online ? AppColors.secondary : AppColors.muted2,
              shape: BoxShape.circle,
              boxShadow: online
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
                  online ? "You're Online" : "You're Offline",
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13),
                ),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          Switch(
            value: online,
            activeColor: Colors.white,
            activeTrackColor: AppColors.secondary,
            inactiveTrackColor: AppColors.panel2,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Future<void> _setOnline(
    BuildContext context,
    AppState state,
    bool online,
  ) async {
    try {
      await state.setHostedRiderOnline(online);
    } on RepositoryFailure catch (failure) {
      if (!context.mounted) return;
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
        title: 'Online status not changed',
      );
    }
  }

  Widget _incomingSection(BuildContext context, AppState state) {
    if (!state.usesHostedIdentity) return _mockIncoming(state);
    return RepositoryView<List<RideRecord>>(
      slot: DomainSlot.riderIncomingRides,
      loading: const SbListLoading(label: 'Loading ride requests…'),
      empty: (_) =>
          _incomingList(state, const [], const [], showOfflineHint: false),
      failure: (_, failure) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _incomingHeader(0),
          const SizedBox(height: 10),
          Text(failure.message,
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
        ],
      ),
      data: (context, records) {
        final pending = [
          for (final record in records)
            if (record.status == RideStatus.awaitingAcceptance) record,
        ];
        final active = [
          for (final record in records)
            if (record.status == RideStatus.accepted ||
                record.status == RideStatus.headingToPickup ||
                record.status == RideStatus.arrived ||
                record.status == RideStatus.inProgress)
              record,
        ];
        return _incomingList(state, pending, active, showOfflineHint: false);
      },
    );
  }

  Widget _incomingList(
    AppState state,
    List<RideRecord> pending,
    List<RideRecord> active, {
    bool showOfflineHint = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _incomingHeader(pending.length),
        const SizedBox(height: 10),
        if (showOfflineHint && !state.riderOnline)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              "You're offline — go online to receive ride requests.",
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          )
        else if (pending.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No pending requests right now.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          )
        else
          for (final record in pending)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Builder(builder: (context) {
                final request = rideRequestFromRecord(record);
                return SbRideRequestCard(
                  request: request,
                  onRespond: (accepted) => state.respondToHostedRequest(
                    request,
                    accepted: accepted,
                  ),
                );
              }),
            ),
        if (active.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text('Active trip',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 8),
          for (final record in active)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SbCard(
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: AppColors.secondary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            record.passengerName == null
                                ? 'Accepted ride'
                                : '${record.passengerName} · ${record.status.label}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12.5),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${record.pickupAddress} → ${record.dropoffAddress}',
                            style: const TextStyle(
                                color: AppColors.muted, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _incomingHeader(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Incoming Requests',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
        SbTag('$count New', secondary: true),
      ],
    );
  }

  Widget _mockIncoming(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _incomingHeader(state.pendingRequests.length),
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
      ],
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
    if (state.usesHostedIdentity) return _hostedPasuyoSection(context, state);
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

  /// Hosted stat row: money comes from the earner's wallet ledger and trips
  /// from the rides actually assigned to this account.
  Widget _hostedStats() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart = todayStart.subtract(Duration(days: now.weekday - 1));
    int earnedSince(List<WalletEntryRecord> entries, DateTime from) => entries
        .where((e) =>
            e.isCredit && e.createdAt != null && !e.createdAt!.isBefore(from))
        .fold(0, (sum, e) => sum + e.amountCentavos);

    return Row(
      children: [
        Expanded(
          child: RepositoryInline<List<WalletEntryRecord>>(
            slot: DomainSlot.earnerWalletEntries,
            placeholder: _statBox('—', 'Earnings'),
            data: (context, entries) =>
                _statBox(Money.format(earnedSince(entries, todayStart)), 'Earnings'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RepositoryInline<List<RideRecord>>(
            slot: DomainSlot.riderIncomingRides,
            placeholder: _statBox('—', 'Trips'),
            data: (context, rides) => _statBox(
                '${rides.where((r) => r.status == RideStatus.completed).length}',
                'Trips'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RepositoryInline<List<WalletEntryRecord>>(
            slot: DomainSlot.earnerWalletEntries,
            placeholder: _statBox('—', 'This Week'),
            data: (context, entries) =>
                _statBox(Money.format(earnedSince(entries, weekStart)), 'This Week'),
          ),
        ),
      ],
    );
  }

  /// Hosted Pasuyo: the helper's claimed errands come from the provider slot
  /// and the unclaimed feed from the open slot. Both are RLS-filtered reads,
  /// so an account without errand capability simply sees an empty feed.
  Widget _hostedPasuyoSection(BuildContext context, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        RepositoryView<List<ServiceRequestRecord>>(
          slot: DomainSlot.providerErrands,
          loading: const SizedBox.shrink(),
          empty: (_) => const SizedBox.shrink(),
          failure: (_, failure) => Text(failure.message,
              style:
                  const TextStyle(color: AppColors.muted, fontSize: 12.5)),
          data: (context, records) {
            final active = [
              for (final record in records)
                if (record.status.isActive) pasuyoTaskFromRecord(record),
            ];
            if (active.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final task in active)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ActivePasuyoCard(task: task, state: state),
                  ),
              ],
            );
          },
        ),
        RepositoryView<List<ServiceRequestRecord>>(
          slot: DomainSlot.openErrands,
          loading: const SbListLoading(label: 'Loading nearby errands…'),
          empty: (_) => _openPasuyoList(const []),
          failure: (_, failure) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _pasuyoHeader(0),
              const SizedBox(height: 10),
              Text(failure.message,
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 12.5)),
            ],
          ),
          data: (context, records) {
            final open = [
              for (final record in records)
                if (record.status.isOpen) pasuyoTaskFromRecord(record),
            ];
            return _openPasuyoList(open);
          },
        ),
      ],
    );
  }

  Widget _openPasuyoList(List<PasuyoTask> open) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pasuyoHeader(open.length),
        const SizedBox(height: 10),
        if (open.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No open errands nearby right now.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          )
        else
          ...open.map((task) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NearbyPasuyoCard(task: task, state: AppState.instance),
              )),
      ],
    );
  }

  Widget _pasuyoHeader(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Nearby Pasuyo',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
        SbTag('$count Open', secondary: true),
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
    // A hosted errand carries its own fixed platform fee and pays the helper
    // the fee whole; a seeded errand still uses the legacy percentage split.
    final b = task.platformFee > 0
        ? FeeBreakdown.fixedAddon(
            service: ServiceType.pasuyo,
            providerFare: task.budget,
            platformFee: task.platformFee,
          )
        : FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);
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
