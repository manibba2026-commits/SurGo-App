import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_status.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';

/// Vehicle Owner mode — Bookings tab. Every incoming rental request across
/// the whole fleet, whatever its status.
class VehicleOwnerBookingsScreen extends StatelessWidget {
  final bool embedded;
  const VehicleOwnerBookingsScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    // A hosted owner reads the bookings the database assigned to them; the
    // decision is made by `respond_to_rental_request`, not a local mutation.
    if (AppState.instance.usesHostedIdentity) {
      return _HostedOwnerBookings(embedded: embedded);
    }

    final state = AppState.instance;
    final content = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final bookings = state.ownerBookingRequests;
        return _BookingsList(
          embedded: embedded,
          bookings: bookings,
          onRespond: (request, accepted) =>
              state.respondToOwnerBooking(request, accepted: accepted),
        );
      },
    );
    if (embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(appBar: AppBar(title: const Text('Bookings')), body: content);
  }
}

class _HostedOwnerBookings extends StatefulWidget {
  const _HostedOwnerBookings({required this.embedded});

  final bool embedded;

  @override
  State<_HostedOwnerBookings> createState() => _HostedOwnerBookingsState();
}

class _HostedOwnerBookingsState extends State<_HostedOwnerBookings> {
  final DomainCache _cache = AppState.instance.cache;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _cache.addListener(_onCacheChanged);
    _cache.ensure(DomainSlot.ownerRentalBookings);
  }

  @override
  void dispose() {
    _cache.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _respond(OwnerBookingRequest request, bool accepted) async {
    setState(() => _busyId = request.id);
    try {
      await AppState.instance
          .respondToHostedRentalRequest(request, accepted: accepted);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = RepositoryView<List<RentalRecord>>(
      slot: DomainSlot.ownerRentalBookings,
      data: (context, records) => _BookingsList(
        embedded: widget.embedded,
        bookings: [for (final record in records) ownerBookingFromRecord(record)],
        busyId: _busyId,
        onRespond: _respond,
      ),
      empty: (_) => const SbEmptyState(
        message: 'No booking requests yet.',
        icon: Icons.event_available_outlined,
      ),
    );
    if (widget.embedded) {
      return SafeArea(bottom: false, child: content);
    }
    return Scaffold(appBar: AppBar(title: const Text('Bookings')), body: content);
  }
}

class _BookingsList extends StatelessWidget {
  const _BookingsList({
    required this.embedded,
    required this.bookings,
    required this.onRespond,
    this.busyId,
  });

  final bool embedded;
  final List<OwnerBookingRequest> bookings;
  final void Function(OwnerBookingRequest request, bool accepted) onRespond;
  final String? busyId;

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty) {
      return ListView(
        padding:
            EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
        children: [
          if (embedded) const SbTabHeader(title: 'Bookings'),
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text('No booking requests yet',
                  style: TextStyle(color: AppColors.muted)),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding:
          EdgeInsets.fromLTRB(18, embedded ? 0 : 12, 18, embedded ? 90 : 24),
      children: [
        if (embedded) const SbTabHeader(title: 'Bookings'),
        ...bookings.map((b) {
          final pending = b.status.isPending;
          final busy = busyId == b.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SbCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SbAvatar(initials: b.renterInitials, size: 32),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b.renterName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 13)),
                            Text(b.vehicleName,
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 11.5)),
                          ],
                        ),
                      ),
                      SbTag(b.status.shortLabel,
                          secondary: b.status == RentalStatus.accepted),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('${b.startDate} → ${b.endDate}',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5)),
                  const SizedBox(height: 6),
                  Text('${Money.format(b.totalFare)} total',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.primaryLight)),
                  if (pending) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SbOutlineButton(
                            label: 'Decline',
                            icon: Icons.close,
                            onPressed:
                                busy ? null : () => onRespond(b, false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SbPrimaryButton(
                            label: busy ? 'Saving…' : 'Accept',
                            icon: Icons.check,
                            onPressed: busy ? null : () => onRespond(b, true),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
