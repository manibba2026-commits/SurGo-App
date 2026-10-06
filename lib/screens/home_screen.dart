import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/models.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import 'active_rental_screen.dart';
import 'activity_screen.dart';
import 'assisted_booking_screen.dart';
import 'notifications_screen.dart';

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
    final firstName = state.ready
        ? state.db.passenger.firstName
        : MockData.passengerFirstName;
    final recentRides =
        state.ready ? state.rideHistory.take(3).toList() : <RideHistoryItem>[];
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
                    Text('Hello, $firstName 👋',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
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
                        if (state.unreadNotifications > 0)
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              width: 15,
                              height: 15,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '${state.unreadNotifications}',
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.onAccent,
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
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.pushNamed(context, '/booking'),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.search, size: 18, color: AppColors.muted),
                    SizedBox(width: 10),
                    Text('Where are you going?',
                        style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SbCard(
                  onTap: () => Navigator.pushNamed(context, '/booking'),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.electric_rickshaw, color: AppColors.primary),
                      SizedBox(height: 8),
                      Text('Ride',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SbCard(
                  onTap: () => Navigator.pushNamed(context, '/rental'),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.directions_car, color: AppColors.secondary),
                      SizedBox(height: 8),
                      Text('Rent',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SbCard(
                  onTap: () => Navigator.pushNamed(context, '/pasuyo'),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.shopping_basket_outlined,
                          color: AppColors.yellow),
                      SizedBox(height: 8),
                      Text('Pasuyo',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SbCard(
                  onTap: () => Navigator.pushNamed(context, '/pasuyo_post'),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.auto_awesome, color: AppColors.primaryLight),
                      SizedBox(height: 8),
                      Text('Ask Sugo',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SbCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AssistedBookingScreen())),
            child: const Row(
              children: [
                Icon(Icons.family_restroom, size: 18, color: AppColors.muted),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Book for Someone Else',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12.5)),
                ),
                Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final booking = state.activeRentalBooking;
              if (booking == null) return const SizedBox.shrink();
              final isPending = booking.status.isPending;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SbCard(
                  borderColor:
                      (isPending ? AppColors.primary : AppColors.secondary)
                          .withValues(alpha: 0.35),
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
                          Container(
                            width: 38,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isPending
                                  ? AppColors.primarySoft
                                  : AppColors.secondarySoft,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(booking.icon,
                                size: 18, color: AppColors.primaryLight),
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
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
              gradient: LinearGradient(
                colors: [AppColors.primarySoft, Colors.transparent],
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('₱30 off your next 3 rides',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: AppColors.primaryLight)),
                SizedBox(height: 2),
                Text('Use code SURGO30 · Ends in 2 days',
                    style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Recent Bookings',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ActivityScreen())),
                child: const Text('View All',
                    style: TextStyle(
                        color: AppColors.primaryLight,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...recentRides.map(
            (b) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SbCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.panel2,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(Icons.electric_rickshaw,
                          size: 20, color: AppColors.muted),
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
