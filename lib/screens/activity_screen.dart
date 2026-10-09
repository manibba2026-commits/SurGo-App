import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import 'pasuyo_task_screen.dart';

/// Which service the Activity list is showing.
enum _ActivityTab { rides, rentals, pasuyo }

class ActivityScreen extends StatefulWidget {
  final bool embedded;
  const ActivityScreen({super.key, this.embedded = false});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  _ActivityTab _tab = _ActivityTab.rides;

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
                  for (final tab in _ActivityTab.values) ...[
                    if (tab != _ActivityTab.values.first)
                      const SizedBox(width: 8),
                    Expanded(
                      child: SbChip(
                        _tabLabel(tab),
                        active: _tab == tab,
                        onTap: () => setState(() => _tab = tab),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: switch (_tab) {
                _ActivityTab.rides => _rideList(state),
                _ActivityTab.rentals => _rentalList(state),
                _ActivityTab.pasuyo => _pasuyoList(state),
              },
            ),
          ],
        );
      },
    );
    if (widget.embedded) return SafeArea(bottom: false, child: body);
    return Scaffold(appBar: AppBar(title: const Text('Activity')), body: body);
  }

  String _tabLabel(_ActivityTab tab) => switch (tab) {
        _ActivityTab.rides => 'Rides',
        _ActivityTab.rentals => 'Rentals',
        _ActivityTab.pasuyo => 'Pasuyo',
      };

  Widget _rideList(AppState state) {
    final live = state.liveRideRequest;
    final rides = state.rideHistory;
    if (live == null && rides.isEmpty) {
      return const Center(
          child:
              Text('No rides yet', style: TextStyle(color: AppColors.muted)));
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(18, 10, 18, widget.embedded ? 90 : 24),
      children: [
        // The request this run created comes first: it is the only row whose
        // state is still moving, so it belongs above the finished history.
        if (live != null) ...[
          _LiveRideCard(request: live),
          const SizedBox(height: 10),
        ],
        for (var i = 0; i < rides.length; i++) ...[
          _rideCard(rides[i]),
          if (i != rides.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _rideCard(RideHistoryItem r) {
    final cancelled = r.status == 'Cancelled';
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                r.vehicleType == 'Motorcycle'
                    ? Icons.two_wheeler
                    : Icons.electric_rickshaw,
                size: 18,
                color: AppColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(r.route,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag(r.status, secondary: !cancelled),
            ],
          ),
          const SizedBox(height: 6),
          Text(r.date,
              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(Money.format(r.fare),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryLight)),
              if (!cancelled)
                Text('${r.driverName} · ★ ${r.rating}',
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rentalList(AppState state) {
    final rentals = state.rentalHistory;
    if (rentals.isEmpty) {
      return const Center(
          child:
              Text('No rentals yet', style: TextStyle(color: AppColors.muted)));
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
                    child: Text(r.vehicleName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  SbTag(r.status, secondary: true),
                ],
              ),
              const SizedBox(height: 6),
              Text('Owner: ${r.ownerName}',
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 11.5)),
              const SizedBox(height: 2),
              Text('${r.startDate} → ${r.endDate}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              const SizedBox(height: 8),
              Text('${Money.format(r.totalFare)} total',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryLight)),
            ],
          ),
        );
      },
    );
  }

  Widget _pasuyoList(AppState state) {
    final orders = state.myPasuyoOrders;
    if (orders.isEmpty) {
      return const Center(
          child:
              Text('No errands yet', style: TextStyle(color: AppColors.muted)));
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(18, 10, 18, widget.embedded ? 90 : 24),
      itemCount: orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _pasuyoCard(context, orders[i]),
    );
  }

  Widget _pasuyoCard(BuildContext context, PasuyoTask t) {
    final done = t.status.isTerminal;
    return SbCard(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PasuyoTaskScreen(taskId: t.id)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(t.category.icon, size: 17, color: AppColors.yellow),
              const SizedBox(width: 9),
              Expanded(
                child: Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag(t.status.shortLabel, secondary: done),
            ],
          ),
          const SizedBox(height: 6),
          Text('${t.pickup} → ${t.dropoff}',
              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 8),
          Text(Money.format(t.budget),
              style: const TextStyle(
                  fontWeight: FontWeight.w800, color: AppColors.primaryLight)),
        ],
      ),
    );
  }
}

/// The run's live ride request, shown above the history because it is the only
/// row still changing. Tapping follows it to whichever screen owns its next
/// step: the matching screen while it is still open, the live trip once a rider
/// is committed.
class _LiveRideCard extends StatelessWidget {
  final RideRequestItem request;
  const _LiveRideCard({required this.request});

  @override
  Widget build(BuildContext context) {
    return SbCard(
      borderColor: AppColors.primary.withValues(alpha: 0.4),
      onTap: () => Navigator.pushNamed(
        context,
        request.status.isOpen ? '/matching' : '/livetrip',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.electric_rickshaw,
                  size: 18, color: AppColors.primaryLight),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${request.pickup} → ${request.dropoff}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag(request.status.shortLabel),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(AppColors.primaryLight),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${request.status.label} · ${Money.format(request.fare)}',
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
