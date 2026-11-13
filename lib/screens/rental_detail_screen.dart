import 'package:flutter/material.dart';
import '../data/models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_state.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_availability.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/surfaces.dart';
import 'active_rental_screen.dart';

/// Started 24-hour periods, matching the hosted RPC's elapsed-time pricing.
/// Keep sub-second precision: even one microsecond past 24 hours starts day two.
int? hostedRentalQuoteDays(DateTime start, DateTime end) {
  final elapsed = end.difference(start).inMicroseconds;
  if (elapsed <= 0) return null;
  return (elapsed + Duration.microsecondsPerDay - 1) ~/
      Duration.microsecondsPerDay;
}

class RentalDetailScreen extends StatefulWidget {
  final RentalVehicle vehicle;
  const RentalDetailScreen({super.key, required this.vehicle});

  @override
  State<RentalDetailScreen> createState() => _RentalDetailScreenState();
}

/// A tappable pick-up / return date. Reads like [SbField] but opens a date
/// picker instead of being a dead label.
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 13,
                  color: AppColors.primaryLight,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
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

/// Says whether the selected period can be booked, and why not when it cannot.
///
/// Reads the same [RentalAvailability] the submit button is gated on, so the
/// explanation and the disabled button can never tell different stories.
class _AvailabilityNotice extends StatelessWidget {
  const _AvailabilityNotice({
    required this.availability,
    required this.blockedByExistingRequest,
  });

  final RentalAvailability availability;
  final bool blockedByExistingRequest;

  @override
  Widget build(BuildContext context) {
    // One rental at a time per account: a second live booking would overwrite
    // the first and strand it, which is the same reason the helper can hold
    // only one errand.
    final reason = blockedByExistingRequest && availability.canBook
        ? 'You already have a rental request in progress.'
        : availability.reasonText;
    final ok = availability.canBook && !blockedByExistingRequest;

    return SbStatusBanner(
      tone: ok ? SbTone.success : SbTone.danger,
      icon: ok ? Icons.check_circle_outline : Icons.error_outline,
      title: ok ? '${_verb(availability)} for these dates.' : reason!,
    );
  }

  static String _verb(RentalAvailability a) => switch (a.reason) {
    RentalUnavailabilityReason.currentlyRented => 'Free for later dates',
    _ => 'Available',
  };
}

/// The pick-up barangay, required by the hosted booking function. A hosted
/// booking names the barangay it starts in; the seed's free text cannot.
class _BarangayPicker extends StatelessWidget {
  const _BarangayPicker({
    required this.barangays,
    required this.value,
    required this.onChanged,
  });

  final List<BarangayRecord> barangays;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.panel,
          hint: const Text(
            'Pick-up barangay',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          items: [
            for (final barangay in barangays)
              DropdownMenuItem(
                value: barangay.id,
                child: Text(
                  barangay.name,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ],
          onChanged: barangays.isEmpty ? null : onChanged,
        ),
      ),
    );
  }
}

class _RentalDetailScreenState extends State<RentalDetailScreen> {
  /// The period being considered, as real dates. Null until the passenger
  /// picks them, which is why the request button starts disabled: the screen
  /// never invents a period on the passenger's behalf.
  DateTime? _pickup;
  DateTime? _return;

  final DomainCache _cache = AppState.instance.cache;
  List<BarangayRecord> _barangays = const [];
  List<RentalRecord> _hostedBookings = const [];
  String? _barangayId;
  bool _submitting = false;

  bool get _hosted =>
      AppState.instance.usesHostedIdentity &&
      AppState.instance.repositories.isSupabaseBacked;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onCacheChanged);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _pickup = _hosted ? now : today;
    _return = _pickup!.add(const Duration(days: 2));
    if (_hosted) {
      _cache.addListener(_onCacheChanged);
      _cache.ensure(DomainSlot.barangays);
      _cache.ensure(DomainSlot.passengerRentalBookings);
      _syncHostedReads();
    }
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onCacheChanged);
    _cache.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    setState(() {
      if (_hosted) _syncHostedReads();
    });
  }

  void _syncHostedReads() {
    final barangays = _cache.stateOf<List<BarangayRecord>>(
      DomainSlot.barangays,
    );
    _barangays = barangays.data ?? const [];
    if (!_barangays.any((b) => b.id == _barangayId)) _barangayId = null;
    final bookings = _cache.stateOf<List<RentalRecord>>(
      DomainSlot.passengerRentalBookings,
    );
    _hostedBookings = bookings.data ?? const [];
  }

  /// True when one of this account's own live bookings already holds a day in
  /// the chosen range. RLS hides other renters' bookings, so the server remains
  /// the final word on a clash.
  bool _ownRangeClashes(DateTime start, DateTime end) {
    for (final booking in _hostedBookings) {
      if (booking.status.isTerminal) continue;
      final from = booking.startAt;
      final to = booking.endAt;
      if (from == null || to == null) continue;
      // Hosted RPCs compare half-open timestamp ranges, not inclusive days.
      if (from.isBefore(end) && to.isAfter(start)) return true;
    }
    return false;
  }

  Future<void> _pickRange({required bool isPickup}) async {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day);
    final initial = isPickup ? (_pickup ?? first) : (_return ?? first);
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(first) ? first : initial,
      firstDate: first,
      lastDate: first.add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            surface: AppColors.panel,
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (date == null || !mounted) return;
    setState(() {
      if (isPickup) {
        _pickup = _hosted && date == first ? DateTime.now() : date;
        // Keep the period ordered: a pickup at or after the return date would
        // be a negative-length rental, and the day count refuses to invent one.
        if (_return == null || !_return!.isAfter(_pickup!)) {
          _return = _pickup!.add(const Duration(days: 1));
        }
      } else {
        _return = date.isAfter(_pickup ?? date)
            ? date
            : date.add(const Duration(days: 1));
      }
    });
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmt(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  @override
  Widget build(BuildContext context) {
    final vehicle = widget.vehicle;
    final state = AppState.instance;

    // Recomputed every build so a booking made elsewhere in the app is
    // reflected here without a stale cached "available".
    final days = (_pickup != null && _return != null)
        ? (_hosted
              ? hostedRentalQuoteDays(_pickup!, _return!)
              : rentalDayCount(_pickup!, _return!))
        : null;
    final total = (days ?? 0) * vehicle.pricePerDay;
    final availability = (_pickup != null && _return != null)
        ? state.rentalAvailability(
            vehicleId: vehicle.id,
            pickupDate: _pickup!,
            returnDate: _return!,
          )
        : const RentalAvailability(canBook: false);
    // RLS hides other renters' bookings, so a hosted build can only pre-check
    // this account's own ones; the server makes the final call on a clash.
    final hostedClash =
        _hosted &&
        _pickup != null &&
        _return != null &&
        _ownRangeClashes(_pickup!, _return!);
    // One live rental at a time per account: a second booking would overwrite the
    // first and strand it, the same reason a helper can hold only one errand.
    final blockedByExistingRequest = _hosted
        ? _hostedBookings.any((b) => !b.status.isTerminal)
        : state.activeRentalBooking != null;
    final platformFee = HostedFees.rentalPlatformFee((days ?? 0) * 24);
    final bookingRead = _cache.stateOf<List<RentalRecord>>(
      DomainSlot.passengerRentalBookings,
    );
    final barangayRead = _cache.stateOf<List<BarangayRecord>>(
      DomainSlot.barangays,
    );
    final readsReady =
        (bookingRead.status == RepositoryStatus.data ||
            bookingRead.status == RepositoryStatus.empty) &&
        barangayRead.status == RepositoryStatus.data;
    final readFailure =
        bookingRead.failure?.message ?? barangayRead.failure?.message;
    final periodValid =
        _return!.difference(_pickup!) <= const Duration(days: 30);
    final canRequest =
        !_submitting &&
        (_hosted
            ? days != null &&
                  readsReady &&
                  periodValid &&
                  _barangayId != null &&
                  !blockedByExistingRequest &&
                  !hostedClash
            : availability.canBook && !blockedByExistingRequest);

    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              Container(
                height: 200,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: SbGradients.tint(SbTone.rent.accent, top: 0.22),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(
                        vehicle.icon,
                        size: 64,
                        color: SbTone.rent.accent.withValues(alpha: 0.85),
                      ),
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
                              onTap: () => Navigator.pop(context),
                            ),
                            ListenableBuilder(
                              listenable: state,
                              builder: (context, _) {
                                final isFav = state.isFavoriteVehicleName(
                                  vehicle.name,
                                );
                                return SbIconButton(
                                  icon: isFav
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  onTap: () =>
                                      state.toggleFavoriteVehicleByListing(
                                        name: vehicle.name,
                                        type: vehicle.type,
                                        pricePerDay: vehicle.pricePerDay,
                                        ownerName: vehicle.ownerName,
                                        vehicleId: vehicle.id,
                                      ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Row(
                        children: List.generate(
                          3,
                          (i) => Container(
                            margin: const EdgeInsets.only(left: 5),
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == 0
                                  ? AppColors.primary
                                  : AppColors.borderLight,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                vehicle.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${vehicle.location}, Tandag City',
                                style: const TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              Money.format(vehicle.pricePerDay),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppColors.primaryLight,
                                fontSize: 16,
                              ),
                            ),
                            const Text(
                              '/ day',
                              style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        SbAvatar(initials: vehicle.ownerInitials),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Owned by ${vehicle.ownerName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                            Text(
                              '⭐ ${vehicle.rating} · Verified owner',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _DateField(
                            label: 'Pick-up',
                            value: _fmt(_pickup!),
                            onTap: () => _pickRange(isPickup: true),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _DateField(
                            label: 'Return',
                            value: _fmt(_return!),
                            onTap: () => _pickRange(isPickup: false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_hosted) ...[
                      _BarangayPicker(
                        barangays: _barangays,
                        value: _barangayId,
                        onChanged: (id) => setState(() => _barangayId = id),
                      ),
                      const SizedBox(height: 10),
                      SbStatusBanner(
                        tone: blockedByExistingRequest || hostedClash
                            ? SbTone.danger
                            : SbTone.success,
                        icon: blockedByExistingRequest || hostedClash
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        title:
                            readFailure ??
                            (!readsReady
                                ? 'Checking your rental requests and pick-up barangays…'
                                : !periodValid
                                ? 'A rental cannot exceed 30 days.'
                                : blockedByExistingRequest
                                ? 'You already have a rental request in progress.'
                                : hostedClash
                                ? 'Those dates clash with your current rental.'
                                : _barangayId == null
                                ? 'Choose the pick-up barangay.'
                                : 'The owner will confirm these dates.'),
                      ),
                      if (readFailure != null)
                        TextButton.icon(
                          onPressed: () async {
                            await _cache.retry(DomainSlot.barangays);
                            await _cache.retry(
                              DomainSlot.passengerRentalBookings,
                            );
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh'),
                        ),
                    ] else
                      _AvailabilityNotice(
                        availability: availability,
                        blockedByExistingRequest: blockedByExistingRequest,
                      ),
                    const SizedBox(height: 16),
                    Text(
                      '${vehicle.description} ${Money.format(vehicle.depositFee)} refundable deposit.',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12.5,
                        height: 1.7,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: const BoxDecoration(
                  color: AppColors.bg,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          Money.format(_hosted ? total + platformFee : total),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          days == null
                              ? 'Pick your dates'
                              : _hosted
                              ? '${Money.format(total)} fare + '
                                    '${Money.format(platformFee)} fee'
                              : '$days ${days == 1 ? 'day' : 'days'} total',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: ElevatedButton(
                        // Disabled unless the chosen period is genuinely free:
                        // the passenger can see why via the notice above, so the
                        // button never refuses without explanation.
                        onPressed: canRequest
                            ? () {
                                if (_hosted) {
                                  _submitHosted(vehicle, total);
                                } else {
                                  _submitMock(vehicle, days!, total);
                                }
                              }
                            : null,
                        // The label has to say which of the reasons it is
                        // disabled: a button that just goes grey teaches
                        // nothing.
                        child: Text(
                          _submitting
                              ? 'Sending…'
                              : blockedByExistingRequest
                              ? 'Rental Already Requested'
                              : _hosted || availability.canBook
                              ? 'Request Rental'
                              : 'Unavailable',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submitMock(RentalVehicle vehicle, int days, int total) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    AppState.instance.requestRental(
      vehicleId: vehicle.id,
      vehicleName: vehicle.name,
      vehicleType: vehicle.type,
      icon: vehicle.icon,
      ownerName: vehicle.ownerName,
      ownerInitials: vehicle.ownerInitials,
      pickupLabel: _fmt(_pickup!),
      returnLabel: _fmt(_return!),
      pickupDate: _pickup!,
      returnDate: _return!,
      days: days,
      totalFare: total,
    );
    await _showRequestedDialog(vehicle);
    if (mounted) setState(() => _submitting = false);
  }

  Future<void> _submitHosted(RentalVehicle vehicle, int total) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    bool sameSession() =>
        mounted &&
        state.isSignedIn &&
        identical(state.repositories, registry) &&
        state.identity?.userId == userId;
    try {
      final barangay = _barangays.firstWhere((b) => b.id == _barangayId);
      final location = vehicle.location.isEmpty
          ? barangay.name
          : '${barangay.name}, ${vehicle.location}';
      // The hosted barangay table has no centre coordinate, so the request
      // stores only the named handover area. The active-rental map geocodes
      // that label through Geoapify when it needs a point; it never invents a
      // coordinate from a bundled barangay list.
      final booking = await state.createHostedRentalRequest(
        vehicle: vehicle,
        pickupDate: _pickup!,
        returnDate: _return!,
        pickupBarangayId: barangay.id,
        pickupLocation: location,
      );
      if (!mounted || !sameSession()) return;
      await _showRequestedDialog(vehicle, rentalId: booking.id);
    } on RepositoryFailure catch (failure) {
      if (!mounted || !sameSession()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure.message)));
    } catch (_) {
      if (!mounted || !sameSession()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not request this rental. Refresh and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showRequestedDialog(
    RentalVehicle vehicle, {
    String? rentalId,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Rental requested'),
        content: Text(
          'Your request for the ${vehicle.name} from ${_fmt(_pickup!)} '
          'to ${_fmt(_return!)} has been sent to ${vehicle.ownerName}. '
          'You\'ll see it as pending on your Home tab while they respond.',
        ),
        actions: [
          TextButton(
            // Cleans the stack instead of popping a guessed number of times:
            // the dialog, this screen and the list all close and Home is left
            // as the only route.
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(
                context,
              ).pushNamedAndRemoveUntil('/home', (route) => false);
            },
            child: const Text('Back to Home'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ActiveRentalScreen(rentalId: rentalId),
                ),
              );
            },
            child: const Text('View Request'),
          ),
        ],
      ),
    );
  }
}
