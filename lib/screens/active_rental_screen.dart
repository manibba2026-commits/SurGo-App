import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../data/db_models.dart';
import '../data/models.dart' show RentalBooking;
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../repositories/repository_state.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

/// Full detail view for the passenger's current rental request/active
/// rental — pushed from the pending/active card on the Home tab. Reflects
/// [AppState.activeRentalBooking] live, so if the 10s simulated owner
/// approval fires while this screen is open it flips from Pending to
/// Active in place.
class ActiveRentalScreen extends StatelessWidget {
  const ActiveRentalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final db = DbService.instance;
    // When opened from Vehicle Owner mode, the specific booking is passed directly.
    final ownerArg =
        ModalRoute.of(context)?.settings.arguments as OwnerBookingRequest?;

    // A hosted renter has no in-memory booking: the live one comes from the
    // database, and its state is advanced by the booking functions.
    if (state.usesHostedIdentity && ownerArg == null) {
      return const _HostedActiveRentalScreen();
    }

    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          // If no owner arg was passed, fall back to the passenger's active booking simulation.
          final passengerBooking = state.activeRentalBooking;

          if (ownerArg == null && passengerBooking == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(context)) Navigator.pop(context);
            });
            return const SizedBox.shrink();
          }

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
          final targetName =
              isOwnerMode ? ownerArg.renterName : passengerBooking!.ownerName;
          final namePrefix = isOwnerMode ? 'Rented to' : 'Owned by';
          final pickup =
              isOwnerMode ? ownerArg.startDate : passengerBooking!.pickupLabel;
          final dropoff =
              isOwnerMode ? ownerArg.endDate : passengerBooking!.returnLabel;
          final totalFare =
              isOwnerMode ? ownerArg.totalFare : passengerBooking!.totalFare;

          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                  child: Row(
                    children: [
                      SbIconButton(
                          icon: Icons.arrow_back,
                          onTap: () => Navigator.pop(context)),
                      const SizedBox(width: 10),
                      const Text('Your Rental',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
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
                                          AppColors.primary),
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
                                  child: Icon(iconData,
                                      size: 28, color: AppColors.primaryLight),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.panel.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isPending
                                    ? 'Waiting for owner approval…'
                                    : 'Rental is active',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 13),
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
                        SbCard(
                          borderColor: (isPending
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
                                  SbTag(status.shortLabel, secondary: !isPending),
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
                                            fontSize: 11.5)),
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
                                        Text(vehicleName,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 14)),
                                        Text('$namePrefix $targetName',
                                            style: const TextStyle(
                                                color: AppColors.muted,
                                                fontSize: 11.5)),
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
                                          label: 'Pick-up', value: pickup)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: SbField(
                                          label: 'Return', value: dropoff)),
                                ],
                              ),
                              const SizedBox(height: 10),
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
                                          fontSize: 12)),
                                  Text(Money.format(totalFare),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primaryLight,
                                          fontSize: 15)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isOwnerMode
                              ? 'This rental is active. The renter has your vehicle until the return date.'
                              : (isPending
                                  ? '$targetName has been notified of your request. This usually takes a few minutes — we\'ll update this screen the moment it\'s approved.'
                                  : 'Your rental is active. Ride safe, and tap "Return Vehicle" once you bring it back to the owner.'),
                          style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                              height: 1.6),
                        ),
                        const SizedBox(height: 18),
                        if (isOwnerMode)
                          const SizedBox
                              .shrink() // Owners don't complete rentals here, they see it on their end / or mark returned elsewhere.
                        else if (isPending)
                          SbOutlineButton(
                            label: 'Cancel Request',
                            icon: Icons.close,
                            onPressed: () {
                              state.cancelRentalBooking();
                              Navigator.pop(context);
                            },
                          )
                        else if (status.advanceActionLabel != null)
                          SbPrimaryButton(
                            label: status.advanceActionLabel!,
                            icon: Icons.check_circle_outline,
                            onPressed: () {
                              // Settling is the only step that pays the owner,
                              // and only from [RentalStatus.returned]. The
                              // earlier steps move the booking along without
                              // any money changing hands, so treating them all
                              // as "return" would tell the renter the vehicle
                              // was handed back while the guard had refused it.
                              if (status == RentalStatus.returned) {
                                state.completeActiveRental();
                                Navigator.pop(context);
                                SurgoNotice.show(
                                  context,
                                  '$vehicleName returned — thanks for riding with SurGo!',
                                  tone: SbNoticeTone.success,
                                );
                              } else {
                                // accepted -> active is the pick-up, active ->
                                // returned is bringing it back. One flag carries
                                // both because [advanceRentalBooking] takes the
                                // caller's intent, not the current status.
                                state.advanceRentalBooking(
                                    pickup: status == RentalStatus.accepted);
                              }
                            },
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

/// The hosted renter's live booking, read from the database.
///
/// No timers and no local transitions: the action button asks the server for
/// the next legal state, and the screen re-renders from the refreshed row.
class _HostedActiveRentalScreen extends StatefulWidget {
  const _HostedActiveRentalScreen();

  @override
  State<_HostedActiveRentalScreen> createState() =>
      _HostedActiveRentalScreenState();
}

class _HostedActiveRentalScreenState extends State<_HostedActiveRentalScreen> {
  final DomainCache _cache = AppState.instance.cache;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _cache.addListener(_onCacheChanged);
    _cache.ensure(DomainSlot.passengerRentalBookings);
  }

  @override
  void dispose() {
    _cache.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  RentalRecord? get _liveRecord {
    final state =
        _cache.stateOf<List<RentalRecord>>(DomainSlot.passengerRentalBookings);
    if (state.status != RepositoryStatus.data) return null;
    final records = (state.data as List<RentalRecord>)
        .where((r) => !r.status.isTerminal)
        .toList()
      ..sort((a, b) => (b.startAt ?? DateTime(0))
          .compareTo(a.startAt ?? DateTime(0)));
    return records.isEmpty ? null : records.first;
  }

  Future<void> _advance(RentalBooking booking) async {
    setState(() => _busy = true);
    try {
      final updated = await AppState.instance.advanceHostedRental(booking);
      if (!mounted) return;
      if (updated == null || updated.status.isTerminal) {
        Navigator.pop(context);
        SurgoNotice.show(
          context,
          '${booking.vehicleName} rental completed.',
          tone: SbNoticeTone.success,
        );
      }
    } catch (_) {
      if (!mounted) return;
      SurgoNotice.show(
        context,
        'That step could not be completed. Please refresh and try again.',
        tone: SbNoticeTone.danger,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(RentalBooking booking) async {
    setState(() => _busy = true);
    try {
      await AppState.instance.cancelHostedRental(booking);
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = _liveRecord;
    if (record == null) {
      final settled = _cache
          .stateOf<List<RentalRecord>>(DomainSlot.passengerRentalBookings)
          .status;
      if (settled == RepositoryStatus.data || settled == RepositoryStatus.empty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (Navigator.canPop(context)) Navigator.pop(context);
        });
      }
      return const Scaffold(
        body: SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final booking = rentalBookingFromRecord(record);
    final pending = booking.status.isPending;
    final platformFee = booking.platformFee;
    final actionLabel = booking.status.advanceActionLabel;

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
                      onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 10),
                  const Text('Your Rental',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SbCard(
                      borderColor: (pending
                              ? AppColors.primary
                              : AppColors.secondary)
                          .withValues(alpha: 0.3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              SbTag(booking.status.shortLabel,
                                  secondary: !pending),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(booking.vehicleType,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 11.5)),
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(booking.vehicleName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 14)),
                                    Text('Owned by ${booking.ownerName}',
                                        style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 11.5)),
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
                                      value: booking.pickupLabel)),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: SbField(
                                      label: 'Return',
                                      value: booking.returnLabel)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _MoneyRow(
                            label: 'Owner fare · ${booking.days} '
                                '${booking.days == 1 ? 'day' : 'days'}',
                            amount: booking.totalFare,
                          ),
                          const SizedBox(height: 4),
                          _MoneyRow(
                            label: 'SurGo platform fee',
                            amount: platformFee,
                          ),
                          const Divider(height: 18),
                          _MoneyRow(
                            label: 'You pay (cash)',
                            amount: booking.customerPays,
                            emphasized: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      pending
                          ? 'The owner has been notified. This screen updates '
                              'the moment they respond.'
                          : 'Your rental is active. Tap the button when you '
                              'pick up or return the vehicle; the owner is paid '
                              'only when the rental is completed.',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12, height: 1.6),
                    ),
                    const SizedBox(height: 18),
                    if (pending)
                      SbOutlineButton(
                        label: _busy ? 'Cancelling…' : 'Cancel Request',
                        icon: Icons.close,
                        onPressed: _busy ? null : () => _cancel(booking),
                      )
                    else if (actionLabel != null)
                      SbPrimaryButton(
                        label: _busy ? 'Updating…' : actionLabel,
                        icon: Icons.check_circle_outline,
                        onPressed: _busy ? null : () => _advance(booking),
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
          child: Text(label,
              style: TextStyle(
                  color: emphasized ? AppColors.text : AppColors.muted,
                  fontSize: 12,
                  fontWeight:
                      emphasized ? FontWeight.w700 : FontWeight.w500)),
        ),
        Text(Money.format(amount),
            style: TextStyle(
                fontWeight: FontWeight.w800,
                color: emphasized ? AppColors.primaryLight : AppColors.text,
                fontSize: emphasized ? 15 : 13)),
      ],
    );
  }
}
