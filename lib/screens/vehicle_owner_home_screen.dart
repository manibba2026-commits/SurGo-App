import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';
import 'vehicle_owner_vehicles_screen.dart';
import 'active_rental_screen.dart';

/// Vehicle Owner mode — Home tab. Shows the owner's fleet at a glance and
/// any incoming rental booking requests that need a response.
class VehicleOwnerHomeScreen extends StatelessWidget {
  final bool embedded;
  const VehicleOwnerHomeScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final content = ListenableBuilder(
      listenable: state,
      builder: (context, _) =>
          state.usesHostedIdentity && state.repositories.isSupabaseBacked
          ? RentalRefreshScope(
              owner: true,
              builder: (context, refresh, refreshing, failure) =>
                  _hostedBody(context, state, refresh, refreshing, failure),
            )
          : _mockBody(context, state),
    );
    if (embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(body: content);
  }

  Widget _mockBody(BuildContext context, AppState state) {
    final owner = state.db.vehicleOwner;
    final pending = state.ownerBookingRequests
        .where((b) => b.status.isPending)
        .toList();
    final activeRentals = state.ownerBookingRequests
        .where((b) => b.status == RentalStatus.accepted)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 90),
      children: [
        Row(
          children: [
            SbAvatar(initials: owner.initials),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    owner.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    'Vehicle Owner · Member since ${owner.memberSince}',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            SbIconButton(
              icon: Icons.map_outlined,
              onTap: () => Navigator.pushNamed(context, '/map/owner'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _statBox(Money.format(state.ownerEarningsToday), 'Today'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statBox(
                Money.format(state.ownerEarningsWeek),
                'This Week',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: RepositoryInline<List<VehicleRecord>>(
                slot: DomainSlot.ownerFleet,
                placeholder: _statBox('—', 'Vehicles'),
                data: (context, fleet) =>
                    _statBox('${fleet.length}', 'Vehicles'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _fleetSection(context),
        const SizedBox(height: 12),
        if (activeRentals.isNotEmpty) ...[
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Active Rentals',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...activeRentals.map(
            (b) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _activeRentalCard(context, state, b),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Booking Requests',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
            ),
            SbTag('${pending.length} New', secondary: true),
          ],
        ),
        const SizedBox(height: 10),
        if (pending.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'No pending booking requests right now.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          )
        else
          ...pending.map(
            (b) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _bookingCard(context, state, b),
            ),
          ),
      ],
    );
  }

  /// Hosted owner home: identity, earnings and bookings all come from the
  /// database. Nothing here falls back to a seeded owner or booking.
  Widget _hostedBody(
    BuildContext context,
    AppState state,
    Future<void> Function() refresh,
    bool refreshing,
    String? failure,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 90),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: refreshing ? null : refresh,
            icon: const Icon(Icons.refresh),
            label: Text(refreshing ? 'Refreshing…' : 'Refresh bookings'),
          ),
        ),
        if (failure != null)
          Text(failure, style: const TextStyle(color: AppColors.danger)),
        RepositoryInline<ProfileRecord>(
          slot: DomainSlot.profile,
          placeholder: _ownerHeader('Vehicle owner', '—', '?'),
          data: (context, profile) => _ownerHeader(
            profile.fullName,
            profile.createdAt?.year.toString() ?? '—',
            initialsFor(profile.fullName),
          ),
        ),
        const SizedBox(height: 16),
        RepositoryView<List<WalletEntryRecord>>(
          slot: DomainSlot.ownerWalletEntries,
          loading: const SizedBox.shrink(),
          empty: (_) => _earningsRow(0, 0),
          failure: (_, __) => _earningsRow(0, 0),
          data: (context, entries) {
            final now = DateTime.now();
            final todayStart = DateTime(now.year, now.month, now.day);
            final weekStart = todayStart.subtract(
              Duration(days: now.weekday - 1),
            );
            int earnedSince(DateTime from) => entries
                .where(
                  (e) =>
                      e.isCredit &&
                      e.createdAt != null &&
                      !e.createdAt!.isBefore(from),
                )
                .fold(0, (sum, e) => sum + e.amountCentavos);
            return _earningsRow(
              earnedSince(todayStart),
              earnedSince(weekStart),
            );
          },
        ),
        const SizedBox(height: 20),
        _fleetSection(context),
        const SizedBox(height: 12),
        RepositoryView<List<RentalRecord>>(
          slot: DomainSlot.ownerRentalBookings,
          loading: const SizedBox.shrink(),
          empty: (_) => const SizedBox.shrink(),
          failure: (_, __) => const SizedBox.shrink(),
          data: (context, records) {
            final active = [
              for (final record in records)
                if (!record.status.isPending && !record.status.isTerminal)
                  record,
            ];
            if (active.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Active Rentals',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
                ),
                const SizedBox(height: 10),
                for (final record in active)
                  Padding(
                    key: ValueKey(record.id),
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _activeRentalCard(
                      context,
                      state,
                      ownerBookingFromRecord(record),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
        RepositoryView<List<RentalRecord>>(
          slot: DomainSlot.ownerRentalBookings,
          loading: const SizedBox.shrink(),
          empty: (_) => _bookingRequests(const []),
          failure: (_, failure) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _bookingHeader(0),
              const SizedBox(height: 10),
              Text(
                failure.message,
                style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
            ],
          ),
          data: (context, records) {
            final pending = [
              for (final record in records)
                if (record.status.isPending) ownerBookingFromRecord(record),
            ];
            return _bookingRequests(pending);
          },
        ),
      ],
    );
  }

  Widget _ownerHeader(String name, String year, String initials) {
    return Row(
      children: [
        SbAvatar(initials: initials),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              Text(
                'Vehicle Owner · Member since $year',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        Builder(
          builder: (context) => SbIconButton(
            icon: Icons.map_outlined,
            onTap: () => Navigator.pushNamed(context, '/map/owner'),
          ),
        ),
      ],
    );
  }

  Widget _earningsRow(int today, int week) {
    return Row(
      children: [
        Expanded(child: _statBox(Money.format(today), 'Today')),
        const SizedBox(width: 8),
        Expanded(child: _statBox(Money.format(week), 'This Week')),
        const SizedBox(width: 8),
        Expanded(
          child: RepositoryInline<List<VehicleRecord>>(
            slot: DomainSlot.ownerFleet,
            placeholder: _statBox('—', 'Vehicles'),
            data: (context, fleet) => _statBox('${fleet.length}', 'Vehicles'),
          ),
        ),
      ],
    );
  }

  Widget _bookingHeader(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Booking Requests',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
        ),
        SbTag('$count New', secondary: true),
      ],
    );
  }

  Widget _bookingRequests(List<OwnerBookingRequest> pending) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bookingHeader(pending.length),
        const SizedBox(height: 10),
        if (pending.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'No pending booking requests right now.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          )
        else
          for (final b in pending)
            Padding(
              key: ValueKey(b.id),
              padding: const EdgeInsets.only(bottom: 10),
              child: _hostedBookingCard(b),
            ),
      ],
    );
  }

  Widget _hostedBookingCard(OwnerBookingRequest b) {
    return SbTintedCard(
      tone: SbTone.rent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SbAvatar(initials: b.renterInitials, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${b.renterName} wants to rent',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      b.vehicleName,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${b.startDate} → ${b.endDate}',
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                Money.format(b.totalFare),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primaryLight,
                ),
              ),
              _HostedRespondButtons(key: ValueKey(b.id), request: b),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fleetSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SbSectionHeader(
          title: 'My Fleet',
          actionLabel: 'Manage',
          onAction: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const VehicleOwnerVehiclesScreen(embedded: false),
            ),
          ),
        ),
        const SizedBox(height: 10),
        RepositoryView<List<VehicleRecord>>(
          slot: DomainSlot.ownerFleet,
          empty: (_) => const SizedBox.shrink(),
          data: (context, fleet) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final v in fleet)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SbTintedCard(
                    tone: SbTone.vehicle,
                    padding: const EdgeInsets.all(13),
                    child: Row(
                      children: [
                        SbToneIcon(
                          tone: SbTone.vehicle,
                          icon: iconForVehicle(v.category, v.vehicleType),
                          size: 42,
                          iconSize: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                v.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12.5,
                                ),
                              ),
                              Text(
                                'Plate ${v.plateNumber} · ${Money.format(v.pricePerDayCentavos)}/day',
                                style: const TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SbTag(
                          v.statusLabel,
                          secondary: v.statusLabel == 'Listed',
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bookingCard(
    BuildContext context,
    AppState state,
    OwnerBookingRequest b,
  ) {
    return SbTintedCard(
      tone: SbTone.rent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SbAvatar(initials: b.renterInitials, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${b.renterName} wants to rent',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      b.vehicleName,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${b.startDate} → ${b.endDate}',
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                Money.format(b.totalFare),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primaryLight,
                ),
              ),
              Row(
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                    ),
                    onPressed: () =>
                        state.respondToOwnerBooking(b, accepted: false),
                    child: const Text('Decline'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                    ),
                    onPressed: () {
                      state.respondToOwnerBooking(b, accepted: true);
                      SurgoNotice.show(
                        context,
                        'Accepted ${b.renterName}\'s booking (simulated)',
                        tone: SbNoticeTone.success,
                      );
                    },
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _activeRentalCard(
    BuildContext context,
    AppState state,
    OwnerBookingRequest b,
  ) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/active_rental', arguments: b),
      child: SbTintedCard(
        tone: SbTone.assist,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SbAvatar(initials: b.renterInitials, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${b.renterName} · ${b.status.shortLabel}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: AppColors.primary,
                        ),
                      ),
                      Text(
                        b.vehicleName,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.muted,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${b.startDate} → ${b.endDate}',
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statBox(String value, String label) {
    return SbTintedCard(
      tone: SbTone.wallet,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: SbTone.wallet.accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Accept/Decline against the hosted rental RPC. The server decides whether
/// the request is still open, so the buttons report its refusal instead of
/// assuming the tap succeeded.
class _HostedRespondButtons extends StatefulWidget {
  const _HostedRespondButtons({super.key, required this.request});

  final OwnerBookingRequest request;

  @override
  State<_HostedRespondButtons> createState() => _HostedRespondButtonsState();
}

class _HostedRespondButtonsState extends State<_HostedRespondButtons> {
  bool _busy = false;

  Future<void> _respond(bool accepted) async {
    if (_busy || !widget.request.status.isPending) return;
    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    bool sameSession() =>
        mounted &&
        state.isSignedIn &&
        identical(state.repositories, registry) &&
        state.identity?.userId == userId;
    setState(() => _busy = true);
    try {
      await state.respondToHostedRentalRequest(
        widget.request,
        accepted: accepted,
      );
      if (!mounted || !sameSession()) return;
      SurgoNotice.show(
        context,
        accepted
            ? 'Accepted ${widget.request.renterName}\'s booking'
            : 'Declined ${widget.request.renterName}\'s booking',
        tone: accepted ? SbNoticeTone.success : SbNoticeTone.info,
      );
    } on RepositoryFailure catch (failure) {
      if (!mounted || !sameSession()) return;
      SurgoNotice.show(context, failure.message, tone: SbNoticeTone.warning);
    } catch (_) {
      if (!mounted || !sameSession()) return;
      SurgoNotice.show(
        context,
        'Could not respond to this rental. Refresh and try again.',
        tone: SbNoticeTone.danger,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          ),
          onPressed: _busy ? null : () => _respond(false),
          child: const Text('Decline'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          ),
          onPressed: _busy ? null : () => _respond(true),
          child: Text(_busy ? 'Saving…' : 'Accept'),
        ),
      ],
    );
  }
}
