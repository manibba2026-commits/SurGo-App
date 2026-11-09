import 'package:flutter/material.dart';
import '../data/db_models.dart';
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RepositoryInline<ProfileRecord>(
                      slot: DomainSlot.passengerProfile,
                      placeholder: const Text('Hello there 👋',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800)),
                      data: (context, profile) => Text(
                          'Hello, ${profile.firstName ?? profile.fullName} 👋',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(height: 2),
                    const Text('Where are we headed today?',
                        style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  ],
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
                                builder: (_) => const NotificationsScreen()),
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
          const SizedBox(height: 18),
          SbTintedCard(
            tone: SbTone.brand,
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            onTap: () => Navigator.pushNamed(context, '/booking'),
            child: const Row(
              children: [
                Icon(Icons.search, size: 18, color: AppColors.primaryLight),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Where are you going?',
                      style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
                Icon(Icons.arrow_forward_rounded,
                    size: 16, color: AppColors.primaryLight),
              ],
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
                    title: 'Ride',
                    subtitle: 'Book a nearby ride',
                    onTap: () => Navigator.pushNamed(context, '/booking'),
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
                    title: 'Rent',
                    subtitle: 'Vehicles by the day',
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
                    subtitle: 'Errands, delivered',
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
                    title: 'For Someone Else',
                    subtitle: 'Book a ride for them',
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const AssistedBookingScreen())),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Live requests created this run, above the seeded history so the
          // dashboard reflects what the account is actually doing right now.
          ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final ride = state.liveRideRequest;
              final orders = state.livePasuyoOrders;
              if (ride == null && orders.isEmpty) {
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  if (ride != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _liveRideCard(context, ride),
                    ),
                  for (final t in orders)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _livePasuyoCard(context, t),
                    ),
                ],
              );
            },
          ),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final booking = state.activeRentalBooking;
              if (booking == null) return const SizedBox.shrink();
              final isPending = booking.status.isPending;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SbTintedCard(
                  tone: SbTone.rent,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ActiveRentalScreen()),
                  ),
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
                                Text(booking.vehicleName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12.5)),
                                Text('Owned by ${booking.ownerName}',
                                    style: const TextStyle(
                                        color: AppColors.muted, fontSize: 11)),
                              ],
                            ),
                          ),
                          SbTag(booking.status.shortLabel,
                              secondary: !isPending),
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
                                    AppColors.primaryLight),
                              ),
                            )
                          else
                            const Icon(Icons.check_circle,
                                size: 14, color: AppColors.secondaryLight),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isPending
                                  ? 'Waiting for ${booking.ownerName} to approve your rental request…'
                                  : 'Your rental is active — tap to view details.',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 11.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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
                      Text('₱30 off your next 3 rides',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              color: AppColors.primaryLight)),
                      SizedBox(height: 2),
                      Text('Use code SURGO30 · Ends in 2 days',
                          style: TextStyle(
                              color: AppColors.muted, fontSize: 11.5)),
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
            onAction: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ActivityScreen())),
          ),
          const SizedBox(height: 12),
          RepositoryView<List<RideRecord>>(
            slot: DomainSlot.passengerRecentRides,
            empty: (_) => const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('No bookings yet',
                  style: TextStyle(color: AppColors.muted)),
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
                Text(b.route,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text('${b.date} · ${Money.format(b.fare)}',
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          SbTag(b.status, secondary: b.status != 'Cancelled'),
        ],
      ),
    );
  }

  /// The passenger's live ride request, tappable to whichever screen owns its
  /// next step. Rendered by the home tab so a request just created is visible
  /// without opening Activity.
  Widget _liveRideCard(BuildContext context, RideRequestItem request) {
    return SbTintedCard(
      tone: SbTone.ride,
      onTap: () => Navigator.pushNamed(
        context,
        request.status.isOpen ? '/matching' : '/livetrip',
      ),
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
                    Text('${request.pickup} → ${request.dropoff}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12.5)),
                    const SizedBox(height: 2),
                    Text(request.status.label,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11)),
                  ],
                ),
              ),
              SbTag(request.status.shortLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text('${Money.format(request.fare)} · Tap to follow your ride',
              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
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
                    Text(task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12.5)),
                    const SizedBox(height: 2),
                    Text(task.status.label,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11)),
                  ],
                ),
              ),
              SbTag(task.status.shortLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text('${Money.format(task.budget)} · Tap to track your errand',
              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
        ],
      ),
    );
  }
}
