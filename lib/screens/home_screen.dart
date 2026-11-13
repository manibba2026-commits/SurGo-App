import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import 'active_rental_screen.dart';
import 'activity_screen.dart';
import 'assisted_booking_screen.dart';
import 'notifications_screen.dart';
import 'pasuyo_task_screen.dart';

/// The passenger Home tab. When [embedded] is true (the normal case, as a
/// page inside [PassengerShell]) it renders just its content with no
/// Scaffold/bottom nav of its own — the shell supplies those. When false it
/// wraps itself in a full Scaffold so it can still be pushed standalone.
class HomeScreen extends StatelessWidget {
  final bool embedded;
  const HomeScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    final content = _HomeContent();
    if (embedded) return content;
    return Scaffold(body: content);
  }
}

class _HomeContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 90),
        children: [
          const Text(
            'Tandag City, Surigao del Sur',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: RepositoryInline<ProfileRecord>(
                  slot: DomainSlot.passengerProfile,
                  placeholder: const Text(
                    'Hi there',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  data: (context, profile) {
                    final firstName = profile.firstName?.trim();
                    final name = firstName != null && firstName.isNotEmpty
                        ? firstName
                        : profile.fullName.trim().split(RegExp(r'\s+')).first;
                    return Text(
                      name.isEmpty ? 'Hi there' : 'Hi, $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    );
                  },
                ),
              ),
              ListenableBuilder(
                listenable: state,
                builder: (context, _) => Row(
                  children: [
                    SbIconButton(
                      icon: Icons.map_outlined,
                      onTap: () =>
                          Navigator.pushNamed(context, '/map/passenger'),
                    ),
                    const SizedBox(width: 8),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SbIconButton(
                          icon: Icons.notifications_none,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const NotificationsScreen(),
                            ),
                          ),
                        ),
                        Positioned(
                          top: -2,
                          right: -2,
                          child: RepositoryInline<int>(
                            slot: DomainSlot.unreadPassengerNotifications,
                            data: (context, unread) => unread == 0
                                ? const SizedBox.shrink()
                                : Container(
                                    width: 15,
                                    height: 15,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(
                                      color: AppColors.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '$unread',
                                      style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.onAccent,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Where to today?',
            style: TextStyle(
              fontSize: 24,
              height: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 18),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final ride = state.liveRideRequest;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.passengerRideLoading)
                    const LinearProgressIndicator(minHeight: 2),
                  if (state.passengerRideFailure != null)
                    SbStatusBanner(
                      tone: SbTone.warning,
                      icon: Icons.sync_problem,
                      title: 'Request sync unavailable',
                      message: state.passengerRideFailure!.message,
                    ),
                  if (state.passengerRideFailure != null)
                    TextButton(
                      onPressed: state.refreshPassengerRide,
                      child: const Text('Refresh current request'),
                    ),
                  if (ride != null) ...[
                    const Text(
                      'Current ride request',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    _liveRideCard(context, ride),
                    const SizedBox(height: 16),
                  ],
                  if (ride == null &&
                      state.rideReceiptPending &&
                      state.lastCompletedRide != null) ...[
                    const Text(
                      'Trip completed',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    _completedRideCard(context, state.lastCompletedRide!),
                    const SizedBox(height: 16),
                  ],
                ],
              );
            },
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AppColors.border),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: () => _openRide(context),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 18, color: AppColors.muted),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Search destination',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 16,
                        color: AppColors.primaryLight,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 138,
                  child: SbServiceCard(
                    tone: SbTone.ride,
                    icon: Icons.electric_rickshaw_rounded,
                    title: 'Find rider',
                    subtitle: 'Book a ride now',
                    onTap: () => _openRide(context),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 138,
                  child: SbServiceCard(
                    tone: SbTone.rent,
                    icon: Icons.directions_car_filled_rounded,
                    title: 'Rent vehicle',
                    subtitle: 'Bikes, cars, vans',
                    onTap: () => Navigator.pushNamed(context, '/rental'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 138,
                  child: SbServiceCard(
                    tone: SbTone.pasuyo,
                    icon: Icons.shopping_basket_rounded,
                    title: 'Pasuyo',
                    subtitle: 'Errands done for you',
                    onTap: () => Navigator.pushNamed(context, '/pasuyo'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 138,
                  child: SbServiceCard(
                    tone: SbTone.assist,
                    icon: Icons.family_restroom_rounded,
                    title: 'Book for someone',
                    subtitle: 'Ride for family or friends',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AssistedBookingScreen(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final orders = state.livePasuyoOrders;
              return Column(
                children: [
                  for (final t in orders)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _livePasuyoCard(context, t),
                    ),
                ],
              );
            },
          ),
          if (state.usesHostedRideDispatch)
            // The signed-in renter's own rental, read from Postgres. Only an
            // unfinished booking is shown; a finished one belongs in history.
            RepositoryView<List<RentalRecord>>(
              slot: DomainSlot.passengerRentalBookings,
              loading: const SizedBox.shrink(),
              empty: (_) => const SizedBox.shrink(),
              failure: (_, __) => const SizedBox.shrink(),
              data: (context, records) {
                final live = [
                  for (final record in records)
                    if (!record.status.isTerminal) record,
                ];
                if (live.isEmpty) return const SizedBox.shrink();
                return _rentalCard(
                  context,
                  rentalBookingFromRecord(live.first),
                );
              },
            )
          else
            ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                final booking = state.activeRentalBooking;
                if (booking == null) return const SizedBox.shrink();
                return _rentalCard(context, booking);
              },
            ),
          if (state.usesHostedRideDispatch)
            // The customer's own open errands; a delivered or cancelled one is
            // history, not a live card.
            RepositoryView<List<ServiceRequestRecord>>(
              slot: DomainSlot.customerErrands,
              loading: const SizedBox.shrink(),
              empty: (_) => const SizedBox.shrink(),
              failure: (_, __) => const SizedBox.shrink(),
              data: (context, records) {
                final live = [
                  for (final record in records)
                    if (!record.status.isTerminal) pasuyoTaskFromRecord(record),
                ];
                if (live.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: [
                    for (final task in live)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _livePasuyoCard(context, task),
                      ),
                  ],
                );
              },
            ),
          const SizedBox(height: 4),
          SbTintedCard(
            tone: SbTone.brand,
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SbToneIcon(
                  tone: SbTone.brand,
                  icon: Icons.local_offer_outlined,
                  size: 34,
                  iconSize: 17,
                ),
                SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '₱30 off your next 3 rides',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: AppColors.primaryLight,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Use code SURGO30 · Ends in 2 days',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          SbSectionHeader(
            title: 'Recent Bookings',
            actionLabel: 'View All',
            onAction: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ActivityScreen()),
            ),
          ),
          const SizedBox(height: 12),
          RepositoryView<List<RideRecord>>(
            slot: DomainSlot.passengerRecentRides,
            empty: (_) => const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'No bookings yet',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
            data: (context, rides) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final record in rides)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _bookingCard(rideHistoryFromRow(record)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openRide(BuildContext context) {
    final request = AppState.instance.liveRideRequest;
    Navigator.pushNamed(context, request == null ? '/booking' : '/matching');
  }

  /// The renter's current rental, whether it came from the seed or Postgres.
  Widget _rentalCard(BuildContext context, RentalBooking booking) {
    final isPending = booking.status.isPending;
    void openRental() => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ActiveRentalScreen(rentalId: booking.id),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        label:
            'Current rental · ${booking.vehicleName} · ${booking.status.label}',
        onTap: openRental,
        excludeSemantics: true,
        child: SbTintedCard(
          tone: SbTone.rent,
          onTap: openRental,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SbToneIcon(
                    tone: SbTone.rent,
                    icon: booking.icon,
                    size: 38,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          booking.vehicleName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          'Owned by ${booking.ownerName}',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SbTag(booking.status.shortLabel, secondary: !isPending),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (isPending)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(
                          AppColors.primaryLight,
                        ),
                      ),
                    )
                  else
                    const Icon(
                      Icons.check_circle,
                      size: 14,
                      color: AppColors.secondaryLight,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isPending
                          ? 'Waiting for ${booking.ownerName} to approve your rental request…'
                          : 'Your rental is active — tap to view details.',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookingCard(RideHistoryItem b) {
    return SbTintedCard(
      tone: SbTone.activity,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SbToneIcon(
            tone: SbTone.activity,
            icon: Icons.electric_rickshaw_rounded,
            size: 42,
            iconSize: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.route,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${b.date} · ${Money.format(b.fare)}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          SbTag(b.status, secondary: b.status != 'Cancelled'),
        ],
      ),
    );
  }

  /// The passenger's live ride request, tappable to whichever screen owns its
  /// next step. A request that is searching or waiting for the chosen rider
  /// opens the matching screen, which shows who it went to; only a ride the
  /// rider accepted has a trip to open.
  Widget _liveRideCard(BuildContext context, RideRequestItem request) {
    return SbTintedCard(
      tone: SbTone.ride,
      onTap: () => Navigator.pushNamed(context, '/matching'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SbToneIcon(
                tone: SbTone.ride,
                icon: Icons.electric_rickshaw_rounded,
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${request.pickup} → ${request.dropoff}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      request.status.label,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              SbTag(request.status.shortLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${Money.format(request.fare)} · Tap to follow your ride',
            style: const TextStyle(color: AppColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// A trip that just finished. The live card disappears at completion, so
  /// this keeps the receipt reachable from Home.
  Widget _completedRideCard(BuildContext context, RideHistoryItem ride) {
    return SbTintedCard(
      tone: SbTone.ride,
      onTap: () => Navigator.pushNamed(context, '/rate'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SbToneIcon(
                tone: SbTone.ride,
                icon: Icons.receipt_long_outlined,
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ride.route,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Completed · ${ride.date}',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SbTag('Receipt'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${Money.format(ride.fare)} · View receipt and rate your trip',
            style: const TextStyle(color: AppColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// A Pasuyo errand this account posted and is still waiting on. Tapping opens
  /// the customer-side tracker.
  Widget _livePasuyoCard(BuildContext context, PasuyoTask task) {
    return SbTintedCard(
      tone: SbTone.pasuyo,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: task.id)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SbToneIcon(
                tone: SbTone.pasuyo,
                icon: task.category.icon,
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.status.label,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              SbTag(task.status.shortLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${Money.format(task.budget)} · Tap to track your errand',
            style: const TextStyle(color: AppColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
