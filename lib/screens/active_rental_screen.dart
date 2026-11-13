import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../data/db_models.dart';
import '../data/models.dart' show RentalBooking;
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../repositories/repository_registry.dart';
import '../repositories/repository_state.dart';
import '../services/fee_calculator.dart';
import '../services/geoapify_service.dart';
import '../services/money.dart';
import '../services/rental_presence.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

/// Full detail view for the passenger's current rental request/active
/// rental — pushed from the pending/active card on the Home tab. The demo
/// tracks one mutable booking through simulated approval, handover and its
/// terminal receipt, without following a later unrelated request.
class ActiveRentalScreen extends StatelessWidget {
  const ActiveRentalScreen({super.key, this.rentalId});

  final String? rentalId;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final argument = ModalRoute.of(context)?.settings.arguments;
    final ownerArg = argument is OwnerBookingRequest ? argument : null;

    if (state.usesHostedIdentity && state.repositories.isSupabaseBacked) {
      return _HostedActiveRentalScreen(
        rentalId:
            rentalId ??
            ownerArg?.id ??
            (argument is RentalBooking ? argument.id : null),
        ownerMode: ownerArg != null,
      );
    }

    return _DemoActiveRentalScreen(
      rentalId: rentalId,
      ownerBooking: ownerArg,
      booking: argument is RentalBooking ? argument : null,
    );
  }
}

class _DemoActiveRentalScreen extends StatefulWidget {
  const _DemoActiveRentalScreen({
    this.rentalId,
    this.ownerBooking,
    this.booking,
  });

  final String? rentalId;
  final OwnerBookingRequest? ownerBooking;
  final RentalBooking? booking;

  @override
  State<_DemoActiveRentalScreen> createState() =>
      _DemoActiveRentalScreenState();
}

class _DemoActiveRentalScreenState extends State<_DemoActiveRentalScreen> {
  final AppState _state = AppState.instance;
  late final RepositoryRegistry _registry;
  late final String? _accountId;
  late final String? _accountUserId;
  late final String? _userId;
  late final bool _hostedIdentity;
  late final String? _trackedId;
  late final OwnerBookingRequest? _ownerBooking;
  RentalBooking? _booking;
  FeeBreakdown? _receipt;
  bool _retired = false;

  bool get _sameBinding =>
      !_retired &&
      identical(_state.repositories, _registry) &&
      _state.currentAccount?.id == _accountId &&
      _state.currentAccount?.authUserId == _accountUserId &&
      _state.identity?.userId == _userId &&
      _state.usesHostedIdentity == _hostedIdentity;

  @override
  void initState() {
    super.initState();
    _registry = _state.repositories;
    _accountId = _state.currentAccount?.id;
    _accountUserId = _state.currentAccount?.authUserId;
    _userId = _state.identity?.userId;
    _hostedIdentity = _state.usesHostedIdentity;
    _ownerBooking = widget.ownerBooking;
    final candidate = widget.booking ?? _state.activeRentalBooking;
    _trackedId = widget.rentalId ?? candidate?.id;
    _booking = _ownerBooking == null && candidate?.id == _trackedId
        ? candidate
        : null;
    _state.addListener(_changed);
  }

  void _checkBinding() {
    if (_sameBinding) return;
    // Same-account sign-in must not revive an already retired screen.
    _retired = true;
    _booking = null;
    _receipt = null;
  }

  void _changed() {
    _checkBinding();
    if (mounted) setState(() {});
  }

  bool _canAct(RentalStatus expected) {
    _checkBinding();
    final booking = _booking;
    return mounted &&
        _sameBinding &&
        _ownerBooking == null &&
        booking != null &&
        booking.id == _trackedId &&
        identical(_state.activeRentalBooking, booking) &&
        booking.status == expected &&
        !expected.isTerminal;
  }

  void _advance(RentalStatus expected) {
    if (!_canAct(expected)) return;
    if (expected == RentalStatus.returned) {
      // The singleton's last settlement may belong to an unrelated rental.
      final split = FeeCalculator.breakdownFor(
        ServiceType.rental,
        _booking!.totalFare,
      );
      _state.completeActiveRental();
      if (_sameBinding && _booking?.status == RentalStatus.completed) {
        setState(() => _receipt = split);
      }
    } else {
      _state.advanceRentalBooking(pickup: expected == RentalStatus.accepted);
    }
  }

  void _cancel(RentalStatus expected) {
    if (!_canAct(expected) || !expected.isPending) return;
    _state.cancelRentalBooking();
  }

  void _home() => Navigator.pushNamedAndRemoveUntil(
    context,
    _state.homeRoute,
    (_) => false,
  );

  @override
  void dispose() {
    _state.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _checkBinding();
    final state = _state;
    final db = DbService.instance;
    final ownerArg = _sameBinding ? _ownerBooking : null;
    final passengerBooking = _sameBinding ? _booking : null;
    if (!_sameBinding ||
        (ownerArg == null &&
            (passengerBooking == null ||
                (!passengerBooking.status.isTerminal &&
                    !identical(
                      state.activeRentalBooking,
                      passengerBooking,
                    ))))) {
      return Scaffold(
        appBar: AppBar(title: const Text('Your Rental')),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    !_sameBinding
                        ? 'Your session changed. Reopen rentals from Home.'
                        : _trackedId == null
                        ? 'No current rental request.'
                        : 'This rental is no longer available.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  SbOutlineButton(
                    label: 'Home',
                    icon: Icons.home_outlined,
                    onPressed: _home,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Builder(
        builder: (context) {
          final isOwnerMode = ownerArg != null;
          // "Pending" covers both requested and awaiting-owner: from the renter's
          // side those are the same thing, that the owner has not said yes yet.
          final isPending = isOwnerMode
              ? ownerArg.status.isPending
              : passengerBooking!.status.isPending;
          final status = isOwnerMode
              ? ownerArg.status
              : passengerBooking!.status;
          const iconData = Icons.electric_rickshaw;

          final vehicleName = isOwnerMode
              ? ownerArg.vehicleName
              : passengerBooking!.vehicleName;
          final avatarInitials = isOwnerMode
              ? ownerArg.renterInitials
              : passengerBooking!.ownerInitials;
          final targetName = isOwnerMode
              ? ownerArg.renterName
              : passengerBooking!.ownerName;
          final namePrefix = isOwnerMode ? 'Rented to' : 'Owned by';
          final pickup = isOwnerMode
              ? ownerArg.startDate
              : passengerBooking!.pickupLabel;
          final dropoff = isOwnerMode
              ? ownerArg.endDate
              : passengerBooking!.returnLabel;
          final totalFare = isOwnerMode
              ? ownerArg.totalFare
              : passengerBooking!.totalFare;
          final completed = !isOwnerMode && status == RentalStatus.completed;
          final receipt = completed
              ? (_receipt ??= FeeCalculator.breakdownFor(
                  ServiceType.rental,
                  totalFare,
                ))
              : null;

          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                  child: Row(
                    children: [
                      SbIconButton(
                        icon: Icons.arrow_back,
                        onTap: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Your Rental',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _home,
                        icon: const Icon(Icons.home_outlined),
                        label: const Text('Home'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 200,
                  child: Stack(
                    children: [
                      SurgoMap(
                        height: 200,
                        fallbackCenter: db.mapConfig.defaultCenter,
                        initialZoom: db.mapConfig.defaultZoom,
                        markers: const [],
                        interactive: false,
                        borderRadius: BorderRadius.zero,
                      ),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                if (isPending)
                                  SizedBox(
                                    width: 84,
                                    height: 84,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      valueColor: const AlwaysStoppedAnimation(
                                        AppColors.primary,
                                      ),
                                      backgroundColor: AppColors.panel2,
                                    ),
                                  ),
                                Container(
                                  width: 64,
                                  height: 64,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppColors.panel,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isPending
                                          ? AppColors.primary
                                          : AppColors.secondary,
                                      width: 2,
                                    ),
                                  ),
                                  child: Icon(
                                    iconData,
                                    size: 28,
                                    color: AppColors.primaryLight,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.panel.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isPending
                                    ? 'Waiting for owner approval…'
                                    : status.label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                    child: Column(
                      children: [
                        if (completed) ...[
                          const Text(
                            'Rental receipt',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        SbCard(
                          borderColor:
                              (isPending
                                      ? AppColors.primary
                                      : AppColors.secondary)
                                  .withValues(alpha: 0.3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  SbTag(
                                    status.shortLabel,
                                    secondary: !isPending,
                                  ),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Text(
                                      isOwnerMode
                                          ? 'Vehicle'
                                          : passengerBooking!.vehicleType,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  SbAvatar(initials: avatarInitials),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          vehicleName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          '$namePrefix $targetName',
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
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: SbField(
                                      label: 'Pick-up',
                                      value: pickup,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SbField(
                                      label: 'Return',
                                      value: dropoff,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              if (receipt != null) ...[
                                _MoneyRow(
                                  label: 'Owner receives',
                                  amount: receipt.providerGets,
                                ),
                                const SizedBox(height: 4),
                                _MoneyRow(
                                  label: 'SurGo commission',
                                  amount: receipt.surgoKeeps,
                                ),
                                const Divider(height: 18),
                                _MoneyRow(
                                  label: 'You paid · Cash',
                                  amount: receipt.customerPays,
                                  emphasized: true,
                                ),
                              ] else
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      isOwnerMode
                                          ? 'Total price'
                                          : '${passengerBooking!.days} day${passengerBooking.days > 1 ? 's' : ''} total',
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      Money.format(totalFare),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.primaryLight,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _demoStatusMessage(status, owner: isOwnerMode),
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 18),
                        if (isOwnerMode)
                          const SizedBox.shrink() // Owners don't complete rentals here, they see it on their end / or mark returned elsewhere.
                        else if (isPending)
                          SbOutlineButton(
                            label: 'Cancel Request',
                            icon: Icons.close,
                            onPressed: () => _cancel(status),
                          )
                        else if (status.advanceActionLabel != null)
                          SbPrimaryButton(
                            label: status.advanceActionLabel!,
                            icon: Icons.check_circle_outline,
                            onPressed: () => _advance(status),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _demoStatusMessage(
  RentalStatus status, {
  required bool owner,
}) => switch (status) {
  RentalStatus.requested || RentalStatus.awaitingOwner =>
    owner
        ? 'Rental request pending. Respond from Bookings.'
        : '${status.label}. Demo owner acceptance is simulated after 10 seconds, '
              'not a live owner response.',
  RentalStatus.accepted =>
    'Owner approved. The vehicle has not been picked up yet.',
  RentalStatus.active =>
    'Rental is active. Return the vehicle after handing it back to the owner.',
  RentalStatus.returned =>
    owner
        ? 'Vehicle returned. Completion is still pending.'
        : 'Vehicle returned. Tap "Complete rental" to settle this demo rental.',
  RentalStatus.completed =>
    owner
        ? 'Rental completed.'
        : 'Rental completed. This cash receipt includes the demo rental commission.',
  RentalStatus.cancelled =>
    'Rental cancelled. No payment or owner payout was recorded.',
  RentalStatus.declined =>
    'Rental declined. No payment or owner payout was recorded.',
};

/// A tracked hosted booking. Only authoritative reads change its status.
class _HostedActiveRentalScreen extends StatefulWidget {
  const _HostedActiveRentalScreen({this.rentalId, required this.ownerMode});

  final String? rentalId;
  final bool ownerMode;

  @override
  State<_HostedActiveRentalScreen> createState() =>
      _HostedActiveRentalScreenState();
}

class _HostedActiveRentalScreenState extends State<_HostedActiveRentalScreen> {
  final DomainCache _cache = AppState.instance.cache;
  bool _busy = false;
  String? _trackedId;
  RentalBooking? _lastBooking;
  late final RepositoryRegistry _registry;
  late final String? _userId;

  DomainSlot get _slot => widget.ownerMode
      ? DomainSlot.ownerRentalBookings
      : DomainSlot.passengerRentalBookings;

  bool get _sameSession {
    final state = AppState.instance;
    return mounted &&
        state.isSignedIn &&
        state.usesHostedIdentity &&
        identical(state.repositories, _registry) &&
        state.identity?.userId == _userId;
  }

  @override
  void initState() {
    super.initState();
    _trackedId = widget.rentalId;
    _registry = AppState.instance.repositories;
    _userId = AppState.instance.identity?.userId;
  }

  RentalBooking? _bookingFromCache() {
    final snapshot = _cache.stateOf<List<RentalRecord>>(_slot);
    if (snapshot.status == RepositoryStatus.failure ||
        snapshot.status == RepositoryStatus.loading ||
        snapshot.status == RepositoryStatus.idle) {
      return _lastBooking;
    }
    final record = _recordFromCache();
    if (record == null) return null;
    return _lastBooking = rentalBookingFromRecord(record);
  }

  /// The raw row behind [_bookingFromCache], for the fields the display
  /// booking does not carry (handover coordinates).
  RentalRecord? _recordFromCache() {
    final snapshot = _cache.stateOf<List<RentalRecord>>(_slot);
    if (snapshot.status != RepositoryStatus.data) return null;
    final records = List<RentalRecord>.of(snapshot.data ?? const []);
    RentalRecord? record;
    if (_trackedId != null) {
      for (final item in records) {
        if (item.id == _trackedId) record = item;
      }
    } else {
      records.removeWhere((item) => item.status.isTerminal);
      records.sort(
        (a, b) =>
            (b.startAt ?? DateTime(0)).compareTo(a.startAt ?? DateTime(0)),
      );
      if (records.isNotEmpty) record = records.first;
    }
    if (record != null) _trackedId = record.id;
    return record;
  }

  Future<void> _advance(RentalBooking booking) async {
    if (_busy || !_sameSession) return;
    if (!widget.ownerMode && booking.status == RentalStatus.returned) return;
    setState(() => _busy = true);
    try {
      final updated = await AppState.instance.advanceHostedRental(booking);
      if (!mounted || !_sameSession) return;
      if (updated != null) setState(() => _lastBooking = updated);
    } on RepositoryFailure catch (failure) {
      if (!mounted || !_sameSession) return;
      SurgoNotice.show(context, failure.message, tone: SbNoticeTone.danger);
    } catch (_) {
      if (!mounted || !_sameSession) return;
      SurgoNotice.show(
        context,
        'That step could not be completed. Refresh and try again.',
        tone: SbNoticeTone.danger,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(RentalBooking booking) async {
    if (_busy || !_sameSession) return;
    setState(() => _busy = true);
    try {
      await AppState.instance.cancelHostedRental(booking);
      // Stay on the request; the refreshed row, not the tap, confirms cancellation.
    } on RepositoryFailure catch (failure) {
      if (!mounted || !_sameSession) return;
      SurgoNotice.show(context, failure.message, tone: SbNoticeTone.danger);
    } catch (_) {
      if (!mounted || !_sameSession) return;
      SurgoNotice.show(
        context,
        'Cancellation failed. Refresh and try again.',
        tone: SbNoticeTone.danger,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => RentalRefreshScope(
    owner: widget.ownerMode,
    builder: (context, refresh, refreshing, refreshFailure) =>
        _buildRental(context, refresh, refreshing, refreshFailure),
  );

  Widget _buildRental(
    BuildContext context,
    Future<void> Function() refresh,
    bool refreshing,
    String? refreshFailure,
  ) {
    final snapshot = _cache.stateOf<List<RentalRecord>>(_slot);
    final booking = _bookingFromCache();
    final record = _recordFromCache();
    final failure = snapshot.failure?.message ?? refreshFailure;
    if (booking == null) {
      final loading =
          failure == null &&
          (snapshot.status == RepositoryStatus.idle ||
              snapshot.status == RepositoryStatus.loading);
      return Scaffold(
        appBar: AppBar(title: const Text('Your Rental')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  loading ? Icons.hourglass_empty : Icons.event_note_outlined,
                  color: AppColors.muted,
                  size: 32,
                ),
                const SizedBox(height: 12),
                Text(
                  failure ??
                      (loading
                          ? 'Loading your rental…'
                          : _trackedId == null
                          ? 'No current rental request.'
                          : 'This rental is no longer available.'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                SbOutlineButton(
                  label: refreshing ? 'Refreshing…' : 'Refresh',
                  icon: Icons.refresh,
                  onPressed: refreshing ? null : refresh,
                ),
                const SizedBox(height: 10),
                SbOutlineButton(
                  label: 'Home',
                  icon: Icons.home_outlined,
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(
                    context,
                    AppState.instance.homeRoute,
                    (_) => false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final pending = booking.status.isPending;
    final breakdown = AppState.instance.hostedRentalBreakdown(booking);
    final actionLabel = widget.ownerMode
        ? (booking.status == RentalStatus.returned
              ? 'Confirm return & complete'
              : null)
        : (booking.status == RentalStatus.accepted ||
                  booking.status == RentalStatus.active
              ? booking.status.advanceActionLabel
              : null);
    final actionable =
        snapshot.status == RepositoryStatus.data && failure == null;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Row(
                children: [
                  SbIconButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Your Rental',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: refreshing ? null : refresh,
                  ),
                  IconButton(
                    tooltip: 'Home',
                    icon: const Icon(Icons.home_outlined),
                    onPressed: () => Navigator.pushNamedAndRemoveUntil(
                      context,
                      AppState.instance.homeRoute,
                      (_) => false,
                    ),
                  ),
                ],
              ),
            ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  failure,
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (booking.status == RentalStatus.completed) ...[
                      const Text(
                        'Rental receipt',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    SbCard(
                      borderColor:
                          (pending ? AppColors.primary : AppColors.secondary)
                              .withValues(alpha: 0.3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              SbTag(
                                booking.status.shortLabel,
                                secondary: !pending,
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  booking.vehicleType,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              SbAvatar(initials: booking.ownerInitials),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      booking.vehicleName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      'Owned by ${booking.ownerName}',
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
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: SbField(
                                  label: 'Pick-up',
                                  value: booking.pickupLabel,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SbField(
                                  label: 'Return',
                                  value: booking.returnLabel,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _MoneyRow(
                            label:
                                'Owner fare · ${booking.days} '
                                '${booking.days == 1 ? 'day' : 'days'}',
                            amount: breakdown.providerGets,
                          ),
                          const SizedBox(height: 4),
                          _MoneyRow(
                            label: 'SurGo platform fee',
                            amount: breakdown.surgoKeeps,
                          ),
                          const Divider(height: 18),
                          _MoneyRow(
                            label: widget.ownerMode
                                ? 'Customer pays (cash)'
                                : 'You pay (cash)',
                            amount: breakdown.customerPays,
                            emphasized: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _statusMessage(booking.status, owner: widget.ownerMode),
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (!booking.status.isTerminal && record != null) ...[
                      _RentalLiveSection(
                        record: record,
                        ownerMode: widget.ownerMode,
                        profileId: AppState.instance.identity?.userId ?? '',
                      ),
                      const SizedBox(height: 14),
                    ],
                    const SizedBox(height: 18),
                    if (pending && !widget.ownerMode)
                      SbOutlineButton(
                        label: _busy ? 'Cancelling…' : 'Cancel Request',
                        icon: Icons.close,
                        onPressed: _busy || !actionable
                            ? null
                            : () => _cancel(booking),
                      )
                    else if (actionLabel != null)
                      SbPrimaryButton(
                        label: _busy ? 'Updating…' : actionLabel,
                        icon: Icons.check_circle_outline,
                        onPressed: _busy || !actionable
                            ? null
                            : () => _advance(booking),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusMessage(
  RentalStatus status, {
  required bool owner,
}) => switch (status) {
  RentalStatus.requested || RentalStatus.awaitingOwner =>
    owner
        ? 'A renter is waiting for your decision. Respond from Bookings.'
        : 'Waiting for owner approval. This screen updates when they respond.',
  RentalStatus.accepted =>
    'Owner approved. The vehicle has not been picked up yet.',
  RentalStatus.active =>
    'The vehicle is out on rent. Confirm return only after handover.',
  RentalStatus.returned =>
    owner
        ? 'Vehicle returned. Confirm the handover to complete this rental.'
        : 'Vehicle returned. Waiting for the owner to confirm completion.',
  RentalStatus.completed =>
    'Rental completed. This receipt uses the agreed fare and platform fee.',
  RentalStatus.declined => 'The owner declined this rental request.',
  RentalStatus.cancelled => 'This rental request was cancelled.',
};

/// The handover point and both parties' live positions for one booking.
///
/// Positions travel over an ephemeral presence channel scoped to the rental,
/// so the renter and the owner see each other while their screens are open and
/// nothing is stored. Without a GPS fix the map still shows the agreed
/// handover point and says plainly that sharing is off.
class _RentalLiveSection extends StatefulWidget {
  const _RentalLiveSection({
    required this.record,
    required this.ownerMode,
    required this.profileId,
  });

  final RentalRecord record;
  final bool ownerMode;
  final String profileId;

  @override
  State<_RentalLiveSection> createState() => _RentalLiveSectionState();
}

class _RentalLiveSectionState extends State<_RentalLiveSection> {
  final RideRouting _routing = RideRouting();
  RentalPresenceSession? _presence;
  MapPoint? _routeStart;
  DateTime? _routeAt;
  MapPoint? _geocodedHandover;
  bool _geocoding = false;

  /// Position sharing belongs to a handover that is actually being arranged,
  /// not to a request the owner has not answered yet.
  bool get _shares =>
      widget.record.status == RentalStatus.accepted ||
      widget.record.status == RentalStatus.active;

  MapPoint? get _handover {
    final latitude = widget.record.pickupLatitude;
    final longitude = widget.record.pickupLongitude;
    return latitude == null || longitude == null
        ? null
        : MapPoint(latitude, longitude);
  }

  /// The stored point when the request carried one, otherwise a Geoapify
  /// geocode of the named handover area. Never a bundled barangay centre.
  MapPoint? get _effectiveHandover => _handover ?? _geocodedHandover;

  @override
  void initState() {
    super.initState();
    _routing.addListener(_onRouting);
    if (_shares) {
      unawaited(_startPresence());
      unawaited(_geocodeHandover());
    }
  }

  Future<void> _geocodeHandover() async {
    if (!_shares || _handover != null || _geocoding) return;
    final label = widget.record.pickupLocation?.trim();
    if (label == null || label.isEmpty) return;
    if (!AppState.instance.repositories.isSupabaseBacked) return;
    setState(() => _geocoding = true);
    try {
      final places = await GeoapifyService().autocomplete('$label, Tandag City');
      if (!mounted) return;
      setState(() {
        _geocodedHandover = places.isEmpty ? null : places.first.point;
        _geocoding = false;
      });
      _syncRoute();
    } on Object {
      if (mounted) setState(() => _geocoding = false);
    }
  }

  @override
  void didUpdateWidget(covariant _RentalLiveSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_shares) {
      unawaited(_stopPresence());
    } else if (_presence == null &&
        (oldWidget.record.id != widget.record.id ||
            oldWidget.profileId != widget.profileId ||
            oldWidget.record.status != widget.record.status)) {
      unawaited(_startPresence());
      unawaited(_geocodeHandover());
    }
  }

  @override
  void dispose() {
    _routing.removeListener(_onRouting);
    _routing.dispose();
    unawaited(_stopPresence());
    super.dispose();
  }

  void _onRouting() {
    if (mounted) setState(() {});
  }

  Future<void> _startPresence() async {
    final presence = AppState.instance.repositories.presence;
    if (presence == null || widget.profileId.isEmpty) return;
    final session = RentalPresenceSession(
      presence: presence,
      rentalId: widget.record.id,
      profileId: widget.profileId,
      role: widget.ownerMode ? 'owner' : 'renter',
    );
    session.ownPosition.addListener(_onPosition);
    session.partner.addListener(_onPosition);
    try {
      await session.start();
    } on Object {
      session.ownPosition.removeListener(_onPosition);
      session.partner.removeListener(_onPosition);
      return;
    }
    if (!mounted || !_shares) {
      session.ownPosition.removeListener(_onPosition);
      session.partner.removeListener(_onPosition);
      await session.stop();
      return;
    }
    setState(() => _presence = session);
    _onPosition();
  }

  Future<void> _stopPresence() async {
    final session = _presence;
    _presence = null;
    if (session == null) return;
    session.ownPosition.removeListener(_onPosition);
    session.partner.removeListener(_onPosition);
    await session.stop();
  }

  void _onPosition() {
    if (!mounted) return;
    _syncRoute();
    setState(() {});
  }

  /// Recalculates the approach only when the start point moved meaningfully,
  /// so a live fix does not turn into a routing call every few metres.
  void _syncRoute() {
    final handover = _effectiveHandover;
    final start =
        _presence?.ownPosition.value ?? _presence?.partner.value?.point;
    if (handover == null || start == null) {
      _routing.sync(start: null, end: null, enabled: false);
      return;
    }
    final moved =
        _routeStart == null || _metersBetween(_routeStart!, start) >= 80;
    final stale =
        _routeAt == null ||
        DateTime.now().difference(_routeAt!) > const Duration(minutes: 2);
    if (!moved && !stale) return;
    _routeStart = start;
    _routeAt = DateTime.now();
    _routing.sync(start: start, end: handover, enabled: true);
  }

  @override
  Widget build(BuildContext context) {
    final handover = _effectiveHandover;
    final own = _presence?.ownPosition.value;
    final partner = _presence?.partner.value;
    final center = handover ?? own ?? partner?.point;
    final partnerLabel = widget.ownerMode ? 'renter' : 'owner';
    final canShare = AppState.instance.repositories.presence != null;

    if (center == null) {
      return Text(
        canShare
            ? 'No handover point on file for this booking. Arrange the '
                  'handover in chat with the $partnerLabel.'
            : 'Live vehicle / delivery position is unavailable. Arrange '
                  'handover with the $partnerLabel.',
        style: const TextStyle(color: AppColors.muted, fontSize: 12),
      );
    }

    final message = partner != null
        ? '${widget.ownerMode ? 'Renter' : 'Owner'} sharing live'
              '${handover == null ? '' : ' · ${_distanceLabel(_metersBetween(partner.point, handover))} from handover'}'
              ' · ${_ageLabel(partner.seenAt)}'
        : own != null
        ? 'You are sharing your position. Waiting for the $partnerLabel to '
              'share theirs.'
        : 'Location is off for this device. Turn on location to share your '
              'position; the handover point is still shown.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SbTag(
              partner != null ? 'Live' : (own != null ? 'Sharing' : 'Map'),
              secondary: partner == null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SurgoMap(
          height: 190,
          borderRadius: BorderRadius.circular(14),
          // A status map inside a scrolling form: letting it take drags would
          // stop the page from scrolling when the finger lands on it.
          interactive: false,
          showUserLocation: false,
          fallbackCenter: center,
          route: _routing.route?.points ?? const [],
          routeIsEstimate: _routing.route == null,
          routeColor: AppColors.success,
          markers: [
            if (handover != null)
              SurgoMapMarker(
                id: 'handover',
                position: handover,
                icon: Icons.handshake_outlined,
                title: 'Handover point',
                subtitle:
                    widget.record.pickupLocation ?? 'Agreed handover point',
              ),
            if (own != null)
              SurgoMapMarker(
                id: 'you',
                position: own,
                icon: Icons.my_location,
                title: 'You',
                subtitle: 'Live position',
                color: AppColors.secondary,
              ),
            if (partner != null)
              SurgoMapMarker(
                id: 'partner',
                position: partner.point,
                icon: widget.ownerMode
                    ? Icons.person_pin_circle_outlined
                    : Icons.directions_car_filled,
                title: widget.ownerMode ? 'Renter' : 'Owner',
                subtitle: 'Live position',
              ),
          ],
        ),
      ],
    );
  }

  static String _ageLabel(DateTime seenAt) {
    final age = DateTime.now().difference(seenAt);
    if (age.inSeconds < 45) return 'now';
    if (age.inMinutes < 60) return '${age.inMinutes} min ago';
    return 'stale';
  }

  static String _distanceLabel(double meters) => meters < 1000
      ? '${meters.round()} m'
      : '${(meters / 1000).toStringAsFixed(1)} km';

  static double _metersBetween(MapPoint a, MapPoint b) {
    const radius = 6371000.0;
    const toRadians = math.pi / 180;
    final dLat = (b.latitude - a.latitude) * toRadians;
    final dLng = (b.longitude - a.longitude) * toRadians;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * toRadians) *
            math.cos(b.latitude * toRadians) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * radius * math.asin(math.min(1, math.sqrt(h)));
  }
}

/// Screen-scoped invalidation: authenticated, payload-free row events plus
/// reconciliation for missed events. Shared only by the rental screens.
class RentalRefreshScope extends StatefulWidget {
  const RentalRefreshScope({
    super.key,
    required this.owner,
    required this.builder,
  });

  final bool owner;
  final Widget Function(
    BuildContext context,
    Future<void> Function() refresh,
    bool refreshing,
    String? failure,
  )
  builder;

  @override
  State<RentalRefreshScope> createState() => _RentalRefreshScopeState();
}

class _RentalRefreshScopeState extends State<RentalRefreshScope> {
  final AppState _state = AppState.instance;
  late final RepositoryRegistry _registry;
  late final String? _userId;
  late final String? _accountId;
  StreamSubscription<void>? _subscription;
  Timer? _timer;
  Future<void>? _flight;
  bool _again = false;
  bool _refreshing = false;
  bool _retired = false;
  String? _failure;

  DomainSlot get _slot => widget.owner
      ? DomainSlot.ownerRentalBookings
      : DomainSlot.passengerRentalBookings;

  bool get _valid =>
      mounted &&
      !_retired &&
      _state.isSignedIn &&
      _state.usesHostedIdentity &&
      _registry.isSupabaseBacked &&
      identical(_registry, _state.repositories) &&
      _userId != null &&
      _state.identity?.userId == _userId &&
      _state.currentAccount?.id == _accountId;

  @override
  void initState() {
    super.initState();
    _registry = _state.repositories;
    _userId = _state.identity?.userId;
    _accountId = _state.currentAccount?.id;
    _state.addListener(_changed);
    _state.cache.addListener(_changed);
    if (!_valid) {
      _retire();
      return;
    }
    try {
      // Verified against SupabaseRentalRepository and the rental schema.
      _subscription = _registry.realtime
          ?.watchRows(
            table: 'rental_bookings',
            column: widget.owner ? 'owner_id' : 'renter_id',
            value: _userId!,
          )
          .listen(
            (_) => unawaited(_refresh()),
            onError: (Object _) {
              if (_valid) unawaited(_refresh());
            },
          );
    } catch (_) {
      // Polling and explicit refresh remain available without realtime.
    }
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_valid) unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  void _changed() {
    if (!mounted) return;
    if (!_valid) _retire();
    setState(() {});
  }

  void _retire() {
    // A later login with the same IDs must reopen the screen, not revive a
    // scope whose realtime subscription and reconciliation timer have stopped.
    _retired = true;
    _again = false;
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(_cancelSubscription(subscription));
  }

  Future<void> _cancelSubscription(
    StreamSubscription<void> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (_) {
      // Teardown is best effort; a transport failure cannot revive this scope
      // or escape as an unhandled asynchronous error after disposal.
    }
  }

  Future<void> _refresh() {
    if (!_valid) return Future.value();
    final flight = _flight;
    if (flight != null) {
      _again = true;
      return flight;
    }
    _refreshing = true;
    _failure = null;
    // Begin on a microtask: initState must not mark an ancestor dirty.
    return _flight = Future<void>.microtask(() async {
      if (mounted) setState(() {});
      try {
        do {
          _again = false;
          if (!_valid) break;
          await _state.cache
              .refresh(_slot)
              .timeout(const Duration(seconds: 20));
        } while (_again && _valid);
      } on TimeoutException {
        if (_valid) _failure = 'Rental refresh took too long. Try again.';
      } catch (_) {
        if (_valid) _failure = 'Unable to refresh rentals. Try again.';
      } finally {
        _flight = null;
        _refreshing = false;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _retire();
    _state.removeListener(_changed);
    _state.cache.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_valid) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Your session changed. Reopen rentals after signing in.',
                ),
                TextButton(
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(
                    context,
                    AppState.instance.homeRoute,
                    (_) => false,
                  ),
                  child: const Text('Home'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widget.builder(context, _refresh, _refreshing, _failure);
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.label,
    required this.amount,
    this.emphasized = false,
  });

  final String label;
  final int amount;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: emphasized ? AppColors.text : AppColors.muted,
              fontSize: 12,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          Money.format(amount),
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: emphasized ? AppColors.primaryLight : AppColors.text,
            fontSize: emphasized ? 15 : 13,
          ),
        ),
      ],
    );
  }
}
