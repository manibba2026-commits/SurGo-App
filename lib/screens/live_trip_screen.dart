import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';

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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text(
                          'Alert sent to your emergency contacts (simulated)')),
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
    final db = DbService.instance;
    final activeRide = state.activeRide;
    final rider = db.rider;
    MapPassenger? matchById;
    MapPassenger? matchByName;
    if (activeRide != null) {
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
    }
    final passenger = matchById ??
        matchByName ??
        (activeRide == null && db.mapPassengers.isNotEmpty
            ? db.mapPassengers.first
            : null);
    if (passenger == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live Trip')),
        body: const Center(child: Text('No passenger selected yet.')),
      );
    }

    final rideMatch = activeRide != null
        ? db.mapRideRequests
            .where((request) =>
                request.id == activeRide.id ||
                (activeRide.passengerId != null &&
                    request.passengerId == activeRide.passengerId))
            .toList()
        : <MapRideRequest>[];
    final matchedRequest = rideMatch.isNotEmpty ? rideMatch.first : null;

    MapRider? assignedRider;
    for (final r in db.mapRiders) {
      if (activeRide?.riderId != null && r.id == activeRide!.riderId) {
        assignedRider = r;
        break;
      }
    }
    final driverPosition = (assignedRider ??
            (db.mapRiders.isNotEmpty ? db.mapRiders.first : null))
        ?.position ??
        db.mapConfig.defaultCenter;
    final pickupPoint = matchedRequest?.pickup ??
        (activeRide?.pickupLatitude != null
            ? MapPoint(activeRide!.pickupLatitude!, activeRide.pickupLongitude!)
            : passenger.position);
    final destinationPoint = activeRide?.dropoffLatitude != null
        ? MapPoint(activeRide!.dropoffLatitude!, activeRide.dropoffLongitude!)
        : driverPosition;

    final markers = <SurgoMapMarker>[
      SurgoMapMarker(
        id: 'driver',
        position: driverPosition,
        icon: surgoMarkerIcon('motorcycle'),
        title: 'You',
        subtitle: '${rider.vehicleType} · ${rider.vehiclePlate}',
        details: [
          MapEntry('Name', rider.name),
          MapEntry('Vehicle', rider.vehicleModel),
        ],
      ),
      SurgoMapMarker(
        id: 'pickup',
        position: pickupPoint,
        icon: surgoMarkerIcon('passenger'),
        title: activeRide?.passengerName ?? passenger.name,
        subtitle: activeRide != null
            ? '${activeRide.pickupBarangay} · ${activeRide.pickupPurok}'
            : '${passenger.barangay} · ${passenger.purok}',
        details: [
          MapEntry('Pick-up', activeRide?.pickup ?? passenger.barangay),
          MapEntry('Fare', '₱${activeRide?.fare ?? 0}'),
        ],
      ),
      SurgoMapMarker(
        id: 'destination',
        position: destinationPoint,
        icon: surgoMarkerIcon('rental'),
        title: 'Destination',
        subtitle: activeRide != null
            ? '${activeRide.dropoffBarangay} · ${activeRide.dropoffPurok}'
            : 'Trip destination',
        details: [
          MapEntry('ETA', '${activeRide?.etaMinutes ?? 0} min'),
          MapEntry('Payment', activeRide?.paymentMethod ?? 'Cash'),
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
                              activeRide != null
                                  ? 'On the way · ${activeRide.etaMinutes} min'
                                  : 'Ride details',
                              secondary: true,
                            ),
                            Text(
                              '${rider.vehicleType} · ${rider.vehiclePlate}',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 11.5),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            SbAvatar(initials: rider.initials),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(rider.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14)),
                                  Text(
                                      '⭐ ${rider.rating} · ${rider.totalTrips} trips',
                                      style: const TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 11.5)),
                                ],
                              ),
                            ),
                            SbIconButton(
                              icon: Icons.call_outlined,
                              onTap: () =>
                                  ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Call ${rider.name}')),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SbIconButton(
                              icon: Icons.message_outlined,
                              onTap: () =>
                                  ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Chat is not wired up in this simulation')),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SbOutlineButton(
                    label: 'Share this trip',
                    icon: Icons.shield_outlined,
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Trip link copied (simulated)')),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SbPrimaryButton(
                    label: 'Complete Trip',
                    onPressed: () =>
                        Navigator.pushReplacementNamed(context, '/rate'),
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
