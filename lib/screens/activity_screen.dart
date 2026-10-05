import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';

class ActivityScreen extends StatefulWidget {
  final bool embedded;
  const ActivityScreen({super.key, this.embedded = false});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  bool showRides = true;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return Column(
          children: [
            if (widget.embedded) const SbTabHeader(title: 'Activity'),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
              child: Row(
                children: [
                  Expanded(
                    child: SbChip('Rides', active: showRides, onTap: () => setState(() => showRides = true)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SbChip('Rentals', active: !showRides, onTap: () => setState(() => showRides = false)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: showRides ? _rideList(state) : _rentalList(state),
            ),
          ],
        );
      },
    );
    if (widget.embedded) return SafeArea(bottom: false, child: body);
    return Scaffold(appBar: AppBar(title: const Text('Activity')), body: body);
  }

  Widget _rideList(AppState state) {
    final rides = state.rideHistory;
    if (rides.isEmpty) {
      return const Center(child: Text('No rides yet', style: TextStyle(color: AppColors.muted)));
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(18, 10, 18, widget.embedded ? 90 : 24),
      itemCount: rides.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final r = rides[i];
        final cancelled = r.status == 'Cancelled';
        return SbCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    r.vehicleType == 'Motorcycle' ? Icons.two_wheeler : Icons.electric_rickshaw,
                    size: 18,
                    color: AppColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(r.route, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  SbTag(r.status, secondary: !cancelled),
                ],
              ),
              const SizedBox(height: 6),
              Text(r.date, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('₱${r.fare}',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.primaryLight)),
                  if (!cancelled)
                    Row(
                      children: [
                        Text(r.driverName, style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                        const SizedBox(width: 6),
                        const Icon(Icons.star_rounded, size: 14, color: AppColors.yellow),
                        Text('${r.rating}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _rentalList(AppState state) {
    final rentals = state.rentalHistory;
    if (rentals.isEmpty) {
      return const Center(child: Text('No rentals yet', style: TextStyle(color: AppColors.muted)));
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(18, 10, 18, widget.embedded ? 90 : 24),
      itemCount: rentals.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final r = rentals[i];
        return SbCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(r.vehicleName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  SbTag(r.status, secondary: true),
                ],
              ),
              const SizedBox(height: 6),
              Text('Owner: ${r.ownerName}', style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
              const SizedBox(height: 2),
              Text('${r.startDate} → ${r.endDate}', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              const SizedBox(height: 8),
              Text('₱${r.totalFare} total',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.primaryLight)),
            ],
          ),
        );
      },
    );
  }
}
