import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

class LiveTripScreen extends StatelessWidget {
  const LiveTripScreen({super.key});

  void _showSosDialog(BuildContext context) {
    final contacts = AppState.instance.emergencyContacts;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Color(0xFFFFB3B3), size: 20),
            SizedBox(width: 8),
            Text('Send SOS alert?'),
          ],
        ),
        content: Text(
          contacts.isEmpty
              ? 'You have no emergency contacts saved yet. Add one from your profile so we know who to alert.'
              : 'This will share your live location and trip details with:\n\n'
                  '${contacts.map((c) => '• ${c.name} (${c.relation})').join('\n')}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          if (contacts.isNotEmpty)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                SurgoNotice.show(
                  context,
                  'Alert sent to your emergency contacts (simulated)',
                  tone: SbNoticeTone.success,
                );
              },
              child: const Text('Send Alert',
                  style: TextStyle(color: Color(0xFFFFB3B3))),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    // The trip status changes from the rider's side (or from the simulated
    // progress action below), so the screen has to listen rather than read the
    // status once and keep rendering the frame it was built with.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final activeRide = state.activeRide;
        if (activeRide == null) return _noActiveTrip(context);
        return _trip(context, state, activeRide);
      },
    );
  }

  /// Shown when the trip ended elsewhere — a rider cancel, say — or the screen
  /// was opened with nothing assigned.
  Widget _noActiveTrip(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Trip')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.route_outlined, size: 40, color: AppColors.muted2),
            const SizedBox(height: 14),
            const Text('No active trip',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('Book a ride to start a trip.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
            const SizedBox(height: 20),
            SbOutlineButton(
              label: 'Back to Home',
              block: false,
              onPressed: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil('/home', (route) => false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trip(BuildContext context, AppState state, RideRequestItem activeRide) {
    final db = DbService.instance;
    final earner = db.earner;
    MapPassenger? matchById;
    MapPassenger? matchByName;
    for (final p in db.mapPassengers) {
      if (p.id == activeRide.passengerId) {
        matchById = p;
        break;
      }
    }
    for (final p in db.mapPassengers) {
      if (p.name == activeRide.passengerName) {
        matchByName = p;
        break;
      }
    }
    final passenger = matchById ??
        matchByName ??
        (db.mapPassengers.isNotEmpty ? db.mapPassengers.first : null);

    final rideMatch = db.mapRideRequests
        .where((request) =>
            request.id == activeRide.id ||
            (activeRide.passengerId != null &&
                request.passengerId == activeRide.passengerId))
        .toList();
    final matchedRequest = rideMatch.isNotEmpty ? rideMatch.first : null;

    MapRider? assignedRider;
    for (final r in db.mapRiders) {
      if (activeRide.riderId != null && r.id == activeRide.riderId) {
        assignedRider = r;
        break;
      }
    }
    // The trip belongs to whoever the matching actually assigned, not the
    // signed-in earner - all three roles run on the same account, so the
    // signed-in earner is frequently not the driver. Fall back to the earner
    // only while nothing is assigned, so the card is never blank.
    final driverName = assignedRider?.name ?? earner.name;
    final driverInitials = assignedRider?.initials ?? earner.initials;
    final driverModel = assignedRider?.vehicleModel ?? earner.vehicleModel;
    final driverVehicleLabel = assignedRider != null
        ? '${assignedRider.vehicleType} · ${assignedRider.vehiclePlate}'
        : '${earner.vehicleType} · ${earner.vehiclePlate}';
    final driverRating = assignedRider?.rating ?? earner.rating;
    final driverTrips = assignedRider?.totalTrips ?? earner.totalTrips;
    final driverPosition = (assignedRider ??
            (db.mapRiders.isNotEmpty ? db.mapRiders.first : null))
        ?.position ??
        db.mapConfig.defaultCenter;
    final pickupPoint = matchedRequest?.pickup ??
        (activeRide.pickupLatitude != null
            ? MapPoint(activeRide.pickupLatitude!, activeRide.pickupLongitude!)
            : (passenger?.position ?? db.mapConfig.defaultCenter));
    final destinationPoint = activeRide.dropoffLatitude != null
        ? MapPoint(activeRide.dropoffLatitude!, activeRide.dropoffLongitude!)
        : driverPosition;

    final markers = <SurgoMapMarker>[
      SurgoMapMarker(
        id: 'driver',
        position: driverPosition,
        icon: surgoMarkerIcon('motorcycle'),
        title: 'You',
        subtitle: driverVehicleLabel,
        details: [
          MapEntry('Name', driverName),
          MapEntry('Vehicle', driverModel),
        ],
      ),
      SurgoMapMarker(
        id: 'pickup',
        position: pickupPoint,
        icon: surgoMarkerIcon('passenger'),
        title: activeRide.passengerName,
        subtitle:
            '${activeRide.pickupBarangay} · ${activeRide.pickupPurok}',
        details: [
          MapEntry('Pick-up', activeRide.pickup),
          MapEntry('Provider fare', Money.format(activeRide.fare)),
        ],
      ),
      SurgoMapMarker(
        id: 'destination',
        position: destinationPoint,
        icon: surgoMarkerIcon('rental'),
        title: 'Destination',
        subtitle:
            '${activeRide.dropoffBarangay} · ${activeRide.dropoffPurok}',
        details: [
          MapEntry('ETA', '${activeRide.etaMinutes} min'),
          MapEntry('Payment', activeRide.paymentMethod),
        ],
      ),
    ];

    final mapHeight = MediaQuery.of(context).size.height * 0.5;
    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: mapHeight,
            child: Stack(
              children: [
                SurgoMap(
                  height: mapHeight,
                  borderRadius: BorderRadius.zero,
                  fallbackCenter: db.mapConfig.defaultCenter,
                  initialZoom: db.mapConfig.defaultZoom,
                  markers: markers,
                  interactive: false,
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        SbIconButton(
                            icon: Icons.arrow_back,
                            onTap: () => Navigator.pop(context)),
                        GestureDetector(
                          onTap: () => _showSosDialog(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: AppColors.dangerSoft,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                  color:
                                      AppColors.danger.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: const [
                                Icon(Icons.warning_amber_rounded,
                                    size: 14, color: Color(0xFFFFB3B3)),
                                SizedBox(width: 6),
                                Text('SOS',
                                    style: TextStyle(
                                        color: Color(0xFFFFB3B3),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
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
                    borderColor: AppColors.secondary.withValues(alpha: 0.3),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            SbTag(
                              '${activeRide.status.shortLabel} · ${activeRide.etaMinutes} min',
                              secondary: true,
                            ),
                            Text(
                              driverVehicleLabel,
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 11.5),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            SbAvatar(initials: driverInitials),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(driverName,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14)),
                                  Text(
                                      '⭐ $driverRating · $driverTrips trips',
                                      style: const TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 11.5)),
                                ],
                              ),
                            ),
                            SbIconButton(
                              icon: Icons.call_outlined,
                              onTap: () =>
                                  SurgoNotice.show(context, 'Call $driverName'),
                            ),
                            const SizedBox(width: 8),
                            SbIconButton(
                              icon: Icons.message_outlined,
                              // Gated by the ride's own status, not by whether
                              // a trip happens to be on screen: the chat screen
                              // explains itself when the thread is closed, so a
                              // tap is never a dead end.
                              onTap: () => Navigator.pushNamed(
                                  context, '/ride_chat'),
                              color: state.canChatOnRide
                                  ? AppColors.primaryLight
                                  : AppColors.muted2,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SbCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('Trip status',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12.5)),
                            const Spacer(),
                            SbTag(activeRide.status.shortLabel,
                                secondary: true),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _RideStatusStepper(status: activeRide.status),
                        const SizedBox(height: 12),
                        Text(
                          activeRide.status == RideStatus.inProgress
                              ? 'The trip is under way. Complete it to settle '
                                  'the fare and rate your rider.'
                              : 'Rider progress is simulated in this '
                                  'prototype. Advance the trip to see the next '
                                  'state.',
                          style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 11.5,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SbOutlineButton(
                    label: 'Share this trip',
                    icon: Icons.shield_outlined,
                    onPressed: () => SurgoNotice.show(
                      context,
                      'Trip link copied (simulated)',
                      tone: SbNoticeTone.success,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (activeRide.status.advanceActionLabel != null)
                    SbPrimaryButton(
                      label: activeRide.status.advanceActionLabel!,
                      onPressed: () {
                        // One action follows the trip's own state machine: the
                        // earlier steps move it along, and only the last live
                        // state settles. Settling here (not from `accepted`)
                        // is what lets a passenger-only demo finish a trip.
                        if (activeRide.status == RideStatus.inProgress) {
                          // The rating screen reads the completed ride and its
                          // fare from state, so settle before navigating.
                          if (!state.completeActiveRide()) {
                            SurgoNotice.show(
                              context,
                              'The trip cannot be completed yet.',
                              tone: SbNoticeTone.warning,
                            );
                            return;
                          }
                          Navigator.pushReplacementNamed(context, '/rate');
                        } else {
                          state.advanceRide();
                          SurgoNotice.show(
                            context,
                            activeRide.status.label,
                            tone: SbNoticeTone.info,
                          );
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
  }
}

/// Progress along [RideStatus] from acceptance to the trip starting.
///
/// The dots come from the same enum the action button reads, so the stepper
/// cannot show a step the trip has not reached or hide one it has.
class _RideStatusStepper extends StatelessWidget {
  final RideStatus status;
  const _RideStatusStepper({required this.status});

  static const _milestones = [
    RideStatus.accepted,
    RideStatus.headingToPickup,
    RideStatus.arrived,
    RideStatus.inProgress,
  ];

  @override
  Widget build(BuildContext context) {
    final current = status.index;
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < _milestones.length; i++) ...[
              _dot(_milestones[i], current),
              if (i != _milestones.length - 1) _line(_milestones[i], current),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final milestone in _milestones)
              Expanded(
                child: Text(
                  milestone.shortLabel,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: milestone.index <= current
                        ? AppColors.secondaryLight
                        : AppColors.muted2,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _dot(RideStatus milestone, int current) {
    final done = milestone.index <= current;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? AppColors.secondary
            : AppColors.muted2.withValues(alpha: 0.35),
        border: Border.all(
          color: milestone.index == current
              ? AppColors.secondaryLight
              : Colors.transparent,
          width: 2,
        ),
      ),
    );
  }

  Widget _line(RideStatus milestone, int current) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        color: milestone.index < current
            ? AppColors.secondary
            : AppColors.muted2.withValues(alpha: 0.35),
      ),
    );
  }
}
