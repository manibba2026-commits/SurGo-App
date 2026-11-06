import 'package:flutter/material.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';

class RiderTripsScreen extends StatelessWidget {
  final bool embedded;
  const RiderTripsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
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
                    Text('${t.date} · ${t.distanceKm} km',
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
