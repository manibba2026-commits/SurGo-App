import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_registry.dart';
import '../services/money.dart';
import '../services/ride_tracking.dart';
import '../state/app_state.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/flow_scaffold.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

class LiveTripScreen extends StatefulWidget {
  const LiveTripScreen({super.key});

  @override
  State<LiveTripScreen> createState() => _LiveTripScreenState();
}

class _LiveTripScreenState extends State<LiveTripScreen> {
  RideTracking? _tracking;
  RepositoryRegistry? _trackedRepositories;
  String? _trackedRideId;
  String? _trackedRiderId;
  String? _trackedUserId;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_scheduleTrackingSync);
    _scheduleTrackingSync();
  }

  void _scheduleTrackingSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTracking();
    });
  }

  void _syncTracking() {
    final state = AppState.instance;
    final ride = state.activeRide;
    if (_trackedRideId == ride?.id &&
        _trackedRiderId == ride?.riderId &&
        identical(_trackedRepositories, state.repositories) &&
        _trackedUserId == state.identity?.userId) {
      return;
    }
    _tracking?.dispose();
    _tracking = null;
    _trackedRepositories = state.repositories;
    _trackedRideId = ride?.id;
    _trackedRiderId = ride?.riderId;
    _trackedUserId = state.identity?.userId;
    if (ride != null) {
      state.syncRideRoute(ride);
      final locations = state.repositories.rideLocations;
      if (state.usesHostedRideDispatch &&
          state.identity != null &&
          locations != null &&
          ride.riderId != null) {
        _tracking = RideTracking(
          rides: state.repositories.rides,
          locations: locations,
          realtime: state.repositories.realtime,
        )..addListener(_trackingChanged);
        _tracking!.start(ride.id, ride.riderId!);
      }
    }
    setState(() {});
  }

  void _trackingChanged() {
    if (!mounted) return;
    final state = AppState.instance;
    final latest = _tracking?.latestRide;
    if (latest != null &&
        latest.id == state.activeRide?.id &&
        (latest.status != state.activeRide?.status ||
            latest.riderId != state.activeRide?.riderId)) {
      state.applyHostedRideUpdate(latest);
    }
    setState(() {});
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_scheduleTrackingSync);
    _tracking?.dispose();
    super.dispose();
  }

  void _showSosDialog(BuildContext context) {
    final contacts = AppState.instance.emergencyContacts;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFFFB3B3),
              size: 20,
            ),
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
            child: const Text('Cancel'),
          ),
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
              child: const Text(
                'Send Alert',
                style: TextStyle(color: Color(0xFFFFB3B3)),
              ),
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
            const Text(
              'No active trip',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text(
              'Book a ride to start a trip.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            SbOutlineButton(
              label: 'Back to Home',
              block: false,
              onPressed: () => Navigator.of(
                context,
              ).pushNamedAndRemoveUntil('/home', (route) => false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trip(
    BuildContext context,
    AppState state,
    RideRequestItem activeRide,
  ) {
    final db = DbService.instance;
    final earner = db.earner;
    final hosted = state.usesHostedRideDispatch;
    final myRiderId = state.currentAccount?.riderId;
    final iAmTheRider =
        hosted && myRiderId != null && activeRide.riderId == myRiderId;
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
    final passenger =
        matchById ??
        matchByName ??
        (db.mapPassengers.isNotEmpty ? db.mapPassengers.first : null);

    final rideMatch = db.mapRideRequests
        .where(
          (request) =>
              request.id == activeRide.id ||
              (activeRide.passengerId != null &&
                  request.passengerId == activeRide.passengerId),
        )
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
    final driverName = hosted
        ? (iAmTheRider ? (state.currentAccount?.name ?? 'You') : 'Your rider')
        : assignedRider?.name ?? earner.name;
    final driverInitials = hosted
        ? _initialsFor(driverName)
        : assignedRider?.initials ?? earner.initials;
    final driverModel = hosted
        ? ''
        : assignedRider?.vehicleModel ?? earner.vehicleModel;
    final driverVehicleLabel = hosted
        ? 'Vehicle details are shared after the trip'
        : (assignedRider != null
              ? '${assignedRider.vehicleType} · ${assignedRider.vehiclePlate}'
              : '${earner.vehicleType} · ${earner.vehiclePlate}');
    final driverRating = assignedRider?.rating ?? earner.rating;
    final driverTrips = assignedRider?.totalTrips ?? earner.totalTrips;
    final driverPosition =
        (assignedRider ?? (db.mapRiders.isNotEmpty ? db.mapRiders.first : null))
            ?.position ??
        db.mapConfig.defaultCenter;
    final pickupPoint =
        activeRide.pickupLatitude != null && activeRide.pickupLongitude != null
        ? MapPoint(activeRide.pickupLatitude!, activeRide.pickupLongitude!)
        : hosted
        ? db.mapConfig.defaultCenter
        : matchedRequest?.pickup ??
              passenger?.position ??
              db.mapConfig.defaultCenter;
    // Without a rider fix the route is still the honest thing to draw, so the
    // destination falls back to the pickup pin rather than a seeded driver.
    final destinationPoint =
        activeRide.dropoffLatitude != null &&
            activeRide.dropoffLongitude != null
        ? MapPoint(activeRide.dropoffLatitude!, activeRide.dropoffLongitude!)
        : pickupPoint;
    final demoDriverPosition = switch (activeRide.status) {
      RideStatus.arrived => pickupPoint,
      RideStatus.inProgress => pickupPoint,
      _ => driverPosition,
    };

    final trackedPosition = _tracking?.position;
    final presence = _tracking?.presence;
    final hostedPosition = trackedPosition != null
        ? MapPoint(trackedPosition.latitude, trackedPosition.longitude)
        : presence?.hasPosition == true
        ? MapPoint(presence!.latitude!, presence.longitude!)
        : null;
    final trackingLabel = trackedPosition != null
        ? 'Live rider GPS'
        : presence?.isSimulated == true
        ? 'Simulated rider position'
        : presence != null
        ? 'Last shared presence · trip GPS unavailable'
        : 'Rider location unavailable';

    final markers = <SurgoMapMarker>[
      if (hosted && hostedPosition != null)
        SurgoMapMarker(
          id: 'driver',
          position: hostedPosition,
          icon: surgoMarkerIcon(presence?.vehicleType ?? 'motorcycle'),
          title: driverName,
          subtitle: trackingLabel,
          faded: trackedPosition == null && presence?.isSimulated != true,
          details: [
            MapEntry('Location', trackingLabel),
            if (presence?.vehicleLabel != null)
              MapEntry('Vehicle', presence!.vehicleLabel!),
          ],
        ),
      if (!hosted)
        SurgoMapMarker(
          id: 'driver',
          position: demoDriverPosition,
          icon: surgoMarkerIcon(
            assignedRider?.vehicleType ?? earner.vehicleType,
          ),
          title: driverName,
          subtitle: 'Demo rider · $driverVehicleLabel',
          details: [
            MapEntry('Name', driverName),
            MapEntry('Vehicle', driverModel),
          ],
        ),
      if (!hosted ||
          (activeRide.pickupLatitude != null &&
              activeRide.pickupLongitude != null))
        SurgoMapMarker(
          id: 'pickup',
          position: pickupPoint,
          icon: surgoMarkerIcon('passenger'),
          title: activeRide.passengerName,
          subtitle: '${activeRide.pickupBarangay} · ${activeRide.pickupPurok}',
          details: [
            MapEntry('Pick-up', activeRide.pickup),
            MapEntry('Provider fare', Money.format(activeRide.fare)),
          ],
        ),
      if (activeRide.dropoffLatitude != null &&
          activeRide.dropoffLongitude != null)
        SurgoMapMarker(
          id: 'destination',
          position: destinationPoint,
          icon: Icons.place_outlined,
          color: const Color(0xFFFFB84D),
          title: 'Destination',
          subtitle:
              '${activeRide.dropoffBarangay} · ${activeRide.dropoffPurok}',
          details: [
            MapEntry('ETA', '${activeRide.etaMinutes} min'),
            MapEntry('Payment', activeRide.paymentMethod),
          ],
        ),
    ];

    return SbFlowScaffold(
      title: 'Live trip',
      stateKey: activeRide.status,
      sheetFraction: 0.54,
      actions: [
        SbIconButton(
          icon: Icons.warning_amber_rounded,
          color: AppColors.danger,
          onTap: () => _showSosDialog(context),
        ),
      ],
      map: SurgoMap(
        height: MediaQuery.sizeOf(context).height,
        borderRadius: BorderRadius.zero,
        fallbackCenter: pickupPoint,
        initialZoom: db.mapConfig.defaultZoom,
        markers: markers,
        showUserLocation: false,
        interactive: true,
        cameraPadding: EdgeInsets.fromLTRB(
          24,
          80,
          24,
          MediaQuery.sizeOf(context).height * 0.54 + 20,
        ),
        route:
            state.rideRouting.route?.points ??
            (activeRide.pickupLatitude != null &&
                    activeRide.pickupLongitude != null &&
                    activeRide.dropoffLatitude != null &&
                    activeRide.dropoffLongitude != null
                ? [pickupPoint, destinationPoint]
                : const []),
        routeIsEstimate: state.rideRouting.route == null,
      ),
      sheet: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
        child: Column(
          children: [
            if (hosted) ...[
              Text(
                trackingLabel,
                style: const TextStyle(color: AppColors.muted),
              ),
              Text(
                _tracking == null
                    ? 'Hosted tracking unavailable'
                    : _tracking!.realtimeConnected
                    ? 'Realtime connected'
                    : 'Realtime unavailable · checking every 15 seconds',
                style: const TextStyle(color: AppColors.muted2, fontSize: 12),
              ),
              if (_tracking?.failure != null)
                Text(
                  _tracking!.failure!.message,
                  style: const TextStyle(color: AppColors.muted),
                ),
              const SizedBox(height: 12),
            ],
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
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          driverVehicleLabel,
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
                      SbAvatar(initials: driverInitials),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              driverName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                            if (hosted)
                              Text(
                                iAmTheRider
                                    ? 'Signed in as the rider for this trip'
                                    : 'Rider details are shared after the trip',
                                style: const TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 11.5,
                                ),
                              )
                            else
                              Row(
                                children: [
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 12,
                                    color: AppColors.primaryLight,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      '$driverRating · $driverTrips trips',
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
                        onTap: () => Navigator.pushNamed(context, '/ride_chat'),
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
            if (state.rideRouting.route != null) ...[
              Text(
                '${(state.rideRouting.route!.distanceMeters / 1000).toStringAsFixed(1)} km by road · ${(state.rideRouting.route!.durationSeconds / 60).ceil()} min estimated travel',
                style: const TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 12),
            ],
            SbCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Trip status',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                      const Spacer(),
                      SbTag(activeRide.status.shortLabel, secondary: true),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _RideStatusStepper(status: activeRide.status),
                  const SizedBox(height: 12),
                  Text(
                    activeRide.status == RideStatus.inProgress
                        ? 'The trip is under way. Complete it to settle '
                              'the fare and rate your rider.'
                        : hosted
                        ? 'The trip moves one step at a time. The '
                              'database refuses any step that is not '
                              'legal for your side of the trip.'
                        : 'Rider progress is simulated in this '
                              'prototype. Advance the trip to see the '
                              'next state.',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                      height: 1.5,
                    ),
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
                foreground: Colors.white,
                onPressed: () async {
                  if (state.usesHostedRideDispatch) {
                    try {
                      final next = await state.advanceHostedRide();
                      if (!context.mounted) return;
                      if (next == null) {
                        SurgoNotice.show(
                          context,
                          'The trip cannot move forward yet.',
                          tone: SbNoticeTone.warning,
                        );
                        return;
                      }
                      SurgoNotice.show(
                        context,
                        next.label,
                        tone: next == RideStatus.completed
                            ? SbNoticeTone.success
                            : SbNoticeTone.info,
                      );
                      if (next == RideStatus.completed) {
                        Navigator.of(
                          context,
                        ).pushNamedAndRemoveUntil('/home', (route) => false);
                      }
                    } on RepositoryFailure catch (failure) {
                      if (!context.mounted) return;
                      SurgoNotice.show(
                        context,
                        failure.message,
                        tone: SbNoticeTone.warning,
                        title: 'Trip update failed',
                      );
                    }
                    return;
                  }
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
    );
  }
}

class _RideStatusStepper extends StatelessWidget {
  final RideStatus status;
  const _RideStatusStepper({required this.status});

  @override
  Widget build(BuildContext context) => SbFlowStepper(
    labels: const ['Assigned', 'Pickup', 'Arrived', 'Trip', 'Done'],
    activeStep: switch (status) {
      RideStatus.headingToPickup => 1,
      RideStatus.arrived => 2,
      RideStatus.inProgress => 3,
      RideStatus.completed => 4,
      _ => 0,
    },
  );
}

/// Initials for a display name, matching the seed convention: the first
/// letter of the first and last word.
String _initialsFor(String name) {
  final parts = name.trim().split(RegExp(r"\s+"));
  if (parts.isEmpty || parts.first.isEmpty) return "?";
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first)
      .toUpperCase();
}
