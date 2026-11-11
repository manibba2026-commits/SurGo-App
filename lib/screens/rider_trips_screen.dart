import 'package:flutter/material.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../services/ride_pricing.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';

class RiderTripsScreen extends StatelessWidget {
  final bool embedded;
  const RiderTripsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    // A hosted rider's trips are the rows the database assigned to them; the
    // seeded trip list belongs to the mock account and must not stand in.
    if (state.usesHostedIdentity) return _HostedRiderTrips(embedded: embedded);
    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final trips = state.riderTrips;
        if (trips.isEmpty) {
          return Column(
            children: [
              if (embedded) const SbTabHeader(title: 'My Trips'),
              const Expanded(
                child: Center(child: Text('No trips yet', style: TextStyle(color: AppColors.muted))),
              ),
            ],
          );
        }
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
          itemCount: trips.length + (embedded ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            if (embedded) {
              if (i == 0) return const SbTabHeader(title: 'My Trips');
              i -= 1;
            }
            final t = trips[i];
              final cancelled = t.status == 'Cancelled';
              return SbCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(t.passengerName,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        ),
                        SbTag(t.status, secondary: !cancelled),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(t.route, style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                    const SizedBox(height: 2),
                    Text('${t.date} · ${distanceLabelKm(t.distanceKm)}',
                        style: const TextStyle(color: AppColors.muted2, fontSize: 10.5)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(Money.format(t.fare),
                            style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.secondaryLight)),
                        if (!cancelled)
                          Row(
                            children: [
                              const Icon(Icons.star_rounded, size: 14, color: AppColors.yellow),
                              Text('${t.rating}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    if (embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('My Trips')), body: body);
  }
}

/// The hosted rider's trips, read from the requests assigned to them.
///
/// RLS hides the passenger's profile from the rider, so a missing name falls
/// back to the role word rather than inventing one.
class _HostedRiderTrips extends StatefulWidget {
  const _HostedRiderTrips({required this.embedded});

  final bool embedded;

  @override
  State<_HostedRiderTrips> createState() => _HostedRiderTripsState();
}

class _HostedRiderTripsState extends State<_HostedRiderTrips> {
  final DomainCache _cache = AppState.instance.cache;

  @override
  void initState() {
    super.initState();
    _cache.addListener(_onCacheChanged);
    _cache.ensure(DomainSlot.riderIncomingRides);
  }

  @override
  void dispose() {
    _cache.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final body = RepositoryView<List<RideRecord>>(
      slot: DomainSlot.riderIncomingRides,
      empty: (_) => Column(
        children: [
          if (widget.embedded) const SbTabHeader(title: 'My Trips'),
          const Expanded(
            child: Center(
              child: Text('No trips yet',
                  style: TextStyle(color: AppColors.muted)),
            ),
          ),
        ],
      ),
      data: (context, rides) => ListView.separated(
        padding: EdgeInsets.fromLTRB(
            18, widget.embedded ? 0 : 12, 18, widget.embedded ? 90 : 24),
        itemCount: rides.length + (widget.embedded ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (widget.embedded) {
            if (i == 0) return const SbTabHeader(title: 'My Trips');
            i -= 1;
          }
          return _tripCard(rides[i]);
        },
      ),
    );
    if (widget.embedded) return SafeArea(bottom: false, child: body);
    return Scaffold(appBar: AppBar(title: const Text('My Trips')), body: body);
  }

  Widget _tripCard(RideRecord ride) {
    final cancelled = ride.status == RideStatus.cancelled;
    final active = !cancelled && ride.status != RideStatus.completed;
    final when = ride.completedAt ?? ride.cancelledAt ?? ride.requestedAt;
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(ride.passengerName ?? 'Passenger',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag(ride.status.label, secondary: !cancelled),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            ride.dropoffAddress.isEmpty
                ? ride.pickupAddress
                : '${ride.pickupAddress} → ${ride.dropoffAddress}',
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (when != null) displayTimestamp(when),
              if (ride.distanceKm > 0) distanceLabelKm(ride.distanceKm),
            ].join(' · '),
            style: const TextStyle(color: AppColors.muted2, fontSize: 10.5),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(Money.format(ride.fareCentavos),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.secondaryLight)),
              if (active)
                Text('In progress',
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}
