import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../data/db_service.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import 'common.dart';
import 'surgo_map.dart';

/// A single incoming-request card on the rider dashboard. Tapping the card
/// (anywhere but the action buttons) expands it in place to show the full
/// pickup/dropoff detail, the passenger's note, and a "View on map" button
/// that opens a bottom sheet with a mock route map.
class SbRideRequestCard extends StatefulWidget {
  final RideRequestItem request;
  const SbRideRequestCard({super.key, required this.request});

  @override
  State<SbRideRequestCard> createState() => _SbRideRequestCardState();
}

class _SbRideRequestCardState extends State<SbRideRequestCard> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final state = AppState.instance;
    return SbCard(
      onTap: () => setState(() => expanded = !expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SbAvatar(initials: r.passengerInitials, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${r.passengerName} wants a ride',
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13)),
                    Text('⭐ ${r.passengerRating} · ${r.requestedAt}',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${r.distanceKm} km',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11)),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.muted,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          _routeLine(r),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: _expandedDetails(context, r),
            crossFadeState:
                expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 220),
            sizeCurve: Curves.easeOutCubic,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(Money.format(r.fare),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryLight)),
              Row(
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9)),
                    onPressed: () => state.respondToRequest(r, accepted: false),
                    child: const Text('Decline'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.secondary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                    ),
                    onPressed: () {
                      state.respondToRequest(r, accepted: true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(
                                "Accepted ${r.passengerName}'s ride (simulated)")),
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

  Widget _routeLine(RideRequestItem r) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
        children: [
          const TextSpan(text: '📍 '),
          TextSpan(
              text: r.pickup,
              style: const TextStyle(
                  color: AppColors.text, fontWeight: FontWeight.w600)),
          const TextSpan(text: ' → 🏁 '),
          TextSpan(
              text: r.dropoff,
              style: const TextStyle(
                  color: AppColors.text, fontWeight: FontWeight.w600)),
          TextSpan(text: ' · ${r.etaMinutes} min'),
        ],
      ),
    );
  }

  Widget _expandedDetails(BuildContext context, RideRequestItem r) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 12),
          _detailRow(Icons.payments_outlined, 'Payment', r.paymentMethod),
          const SizedBox(height: 8),
          _detailRow(Icons.sticky_note_2_outlined, "Passenger's note",
              r.note.isEmpty ? '—' : r.note),
          const SizedBox(height: 12),
          SbOutlineButton(
            label: 'View on Map',
            icon: Icons.map_outlined,
            onPressed: () => _showMapSheet(context, r),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.muted2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }

  void _showMapSheet(BuildContext context, RideRequestItem r) {
    final db = DbService.instance;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              child: SurgoMap(
                height: 260,
                fallbackCenter: db.mapConfig.defaultCenter,
                initialZoom: db.mapConfig.defaultZoom,
                markers: const [],
                interactive: false,
                borderRadius: BorderRadius.zero,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r.passengerName}\'s trip',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 10),
                  _detailRow(Icons.radio_button_checked, 'Pickup',
                      '${r.pickupPurok}, ${r.pickupBarangay}'),
                  const SizedBox(height: 10),
                  _detailRow(Icons.place_outlined, 'Dropoff',
                      '${r.dropoffPurok}, ${r.dropoffBarangay}'),
                  const SizedBox(height: 10),
                  _detailRow(Icons.straighten, 'Distance & ETA',
                      '${r.distanceKm} km · ${r.etaMinutes} min away'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The banner that appears above "Incoming Requests" once the rider has
/// accepted a ride — a purple/green highlight card showing the active trip,
/// labelled with whatever the trip needs next, plus a cancel escape hatch.
class SbActiveRideBanner extends StatelessWidget {
  final RideRequestItem ride;
  const SbActiveRideBanner({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(context, '/livetrip');
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.secondaryDark, AppColors.primaryDark],
          ),
          boxShadow: [
            BoxShadow(
                color: AppColors.secondary.withValues(alpha: 0.3),
                blurRadius: 24,
                offset: const Offset(0, 10)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                const Text('ACTIVE RIDE',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        letterSpacing: 0.6)),
                const Spacer(),
                Text(Money.format(ride.fare),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white24,
                  child: Text(ride.passengerInitials,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ride.passengerName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5)),
                      Text('${ride.pickup} → ${ride.dropoff}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    onPressed: () => state.cancelActiveRide(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                // The label comes from the enum, so the button cannot offer an
                // action the trip is not actually in. [completeActiveRide] is
                // the only step that pays, and it only settles from
                // [RideStatus.inProgress]; treating every press as "complete"
                // is what let this button announce a fare was added while the
                // guard had silently refused the transition.
                if (ride.status.advanceActionLabel != null)
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.onAccent,
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      onPressed: () {
                        if (ride.status == RideStatus.inProgress) {
                          state.completeActiveRide();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Trip completed — fare added to your wallet (simulated)')),
                          );
                        } else {
                          state.advanceRide();
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(ride.status.label)));
                        }
                      },
                      child: Text(ride.status.advanceActionLabel!),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
