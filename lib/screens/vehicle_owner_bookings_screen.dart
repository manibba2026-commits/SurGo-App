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
import 'active_rental_screen.dart';

/// Vehicle Owner mode — Bookings tab. Every incoming rental request across
/// the whole fleet, whatever its status.
class VehicleOwnerBookingsScreen extends StatelessWidget {
  final bool embedded;
  const VehicleOwnerBookingsScreen({super.key, this.embedded = true});

  @override
  Widget build(BuildContext context) {
    // A hosted owner reads the bookings the database assigned to them; the
    // decision is made by `respond_to_rental_request`, not a local mutation.
    if (AppState.instance.usesHostedIdentity &&
        AppState.instance.repositories.isSupabaseBacked) {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Bookings')),
      body: content,
    );
  }
}

class _HostedOwnerBookings extends StatefulWidget {
  const _HostedOwnerBookings({required this.embedded});

  final bool embedded;

  @override
  State<_HostedOwnerBookings> createState() => _HostedOwnerBookingsState();
}

class _HostedOwnerBookingsState extends State<_HostedOwnerBookings> {
  String? _busyId;

  Future<void> _respond(OwnerBookingRequest request, bool accepted) async {
    if (_busyId != null || !request.status.isPending) return;
    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    setState(() => _busyId = request.id);
    try {
      await state.respondToHostedRentalRequest(request, accepted: accepted);
    } on RepositoryFailure catch (failure) {
      if (!mounted ||
          !state.isSignedIn ||
          !identical(state.repositories, registry) ||
          state.identity?.userId != userId) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure.message)));
    } catch (_) {
      if (!mounted ||
          !state.isSignedIn ||
          !identical(state.repositories, registry) ||
          state.identity?.userId != userId) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not respond to this rental. Refresh and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) => RentalRefreshScope(
    owner: true,
    builder: (context, refresh, refreshing, failure) {
      final content = Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: refreshing ? null : refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(refreshing ? 'Refreshing…' : 'Refresh'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(
                    context,
                    AppState.instance.homeRoute,
                    (_) => false,
                  ),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Home'),
                ),
              ],
            ),
          ),
          if (failure != null)
            Padding(padding: const EdgeInsets.all(18), child: Text(failure)),
          Expanded(
            child: RepositoryView<List<RentalRecord>>(
              slot: DomainSlot.ownerRentalBookings,
              data: (context, records) => _BookingsList(
                embedded: widget.embedded,
                hosted: true,
                bookings: [
                  for (final record in records) ownerBookingFromRecord(record),
                ],
                busyId: _busyId,
                onRespond: _respond,
              ),
              empty: (_) => _BookingsList(
                embedded: widget.embedded,
                bookings: const [],
                onRespond: _respond,
              ),
            ),
          ),
        ],
      );
      if (widget.embedded) return SafeArea(bottom: false, child: content);
      return Scaffold(
        appBar: AppBar(title: const Text('Bookings')),
        body: content,
      );
    },
  );
}

class _BookingsList extends StatelessWidget {
  const _BookingsList({
    required this.embedded,
    required this.bookings,
    required this.onRespond,
    this.busyId,
    this.hosted = false,
  });

  final bool embedded;
  final List<OwnerBookingRequest> bookings;
  final void Function(OwnerBookingRequest request, bool accepted) onRespond;
  final String? busyId;
  final bool hosted;

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          embedded ? 0 : 12,
          18,
          embedded ? 90 : 24,
        ),
        children: [
          if (embedded) const SbTabHeader(title: 'Bookings'),
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                'No booking requests yet',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        embedded ? 0 : 12,
        18,
        embedded ? 90 : 24,
      ),
      children: [
        if (embedded) const SbTabHeader(title: 'Bookings'),
        ...bookings.map((b) {
          final pending = b.status.isPending;
          final busy = busyId != null;
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
                            Text(
                              b.renterName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              b.vehicleName,
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SbTag(
                        b.status.shortLabel,
                        secondary: b.status == RentalStatus.accepted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${b.startDate} → ${b.endDate}',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${Money.format(b.totalFare)} owner fare',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryLight,
                    ),
                  ),
                  if (hosted && !pending) ...[
                    const SizedBox(height: 8),
                    Text(
                      b.status.label,
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          settings: RouteSettings(arguments: b),
                          builder: (_) => ActiveRentalScreen(rentalId: b.id),
                        ),
                      ),
                      child: Text(
                        b.status == RentalStatus.returned
                            ? 'Confirm return & complete'
                            : b.status == RentalStatus.completed
                            ? 'View receipt'
                            : 'View rental',
                      ),
                    ),
                  ],
                  if (pending) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SbOutlineButton(
                            label: 'Decline',
                            icon: Icons.close,
                            onPressed: busy ? null : () => onRespond(b, false),
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
