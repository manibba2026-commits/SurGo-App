import 'package:flutter/material.dart';
import '../data/models.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/rental_availability.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import 'active_rental_screen.dart';

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
            Text(label,
                style: const TextStyle(color: AppColors.muted, fontSize: 10.5)),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.calendar_today_outlined,
                    size: 13, color: AppColors.primaryLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12.5),
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

    final color = ok ? AppColors.primaryLight : AppColors.danger;
    final icon = ok ? Icons.check_circle_outline : Icons.error_outline;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            ok
                ? '${_verb(availability)} for these dates.'
                : reason!,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  static String _verb(RentalAvailability a) => switch (a.reason) {
        RentalUnavailabilityReason.currentlyRented => 'Free for later dates',
        _ => 'Available',
      };
}

class _RentalDetailScreenState extends State<RentalDetailScreen> {
  /// The period being considered, as real dates. Null until the passenger
  /// picks them, which is why the request button starts disabled: the screen
  /// never invents a period on the passenger's behalf.
  DateTime? _pickup;
  DateTime? _return;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _pickup = today;
    _return = today.add(const Duration(days: 2));
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
    if (date == null) return;
    setState(() {
      if (isPickup) {
        _pickup = date;
        // Keep the period ordered: a pickup at or after the return date would
        // be a negative-length rental, and the day count refuses to invent one.
        if (_return == null || !_return!.isAfter(date)) {
          _return = date.add(const Duration(days: 1));
        }
      } else {
        _return = date.isAfter(_pickup ?? date) ? date : date.add(const Duration(days: 1));
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
        ? rentalDayCount(_pickup!, _return!)
        : null;
    final total = (days ?? 0) * vehicle.pricePerDay;
    final availability = (_pickup != null && _return != null)
        ? state.rentalAvailability(
            vehicleId: vehicle.id,
            pickupDate: _pickup!,
            returnDate: _return!,
          )
        : const RentalAvailability(canBook: false);
    // One live rental at a time per account: a second booking would overwrite the
    // first and strand it, the same reason a helper can hold only one errand.
    final blockedByExistingRequest = state.activeRentalBooking != null;
    final canRequest = availability.canBook && !blockedByExistingRequest;

    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              Container(
                height: 200,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [AppColors.panel3, AppColors.panel2]),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(vehicle.icon, size: 64, color: AppColors.primaryLight.withValues(alpha: 0.8)),
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
                            SbIconButton(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                            ListenableBuilder(
                              listenable: state,
                              builder: (context, _) {
                                final isFav = state.isFavoriteVehicleName(vehicle.name);
                                return SbIconButton(
                                  icon: isFav ? Icons.favorite : Icons.favorite_border,
                                  onTap: () => state.toggleFavoriteVehicleByListing(
                                    name: vehicle.name,
                                    type: vehicle.type,
                                    pricePerDay: vehicle.pricePerDay,
                                    ownerName: vehicle.ownerName,
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
                              color: i == 0 ? AppColors.primary : AppColors.borderLight,
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
                              Text(vehicle.name,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                              const SizedBox(height: 2),
                              Text('${vehicle.location}, Tandag City',
                                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(Money.format(vehicle.pricePerDay),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, color: AppColors.primaryLight, fontSize: 16)),
                            const Text('/ day', style: TextStyle(color: AppColors.muted, fontSize: 11)),
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
                            Text('Owned by ${vehicle.ownerName}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                            Text('⭐ ${vehicle.rating} · Verified owner',
                                style: const TextStyle(color: AppColors.muted, fontSize: 11)),
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
                    _AvailabilityNotice(
                      availability: availability,
                      blockedByExistingRequest: blockedByExistingRequest,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '${vehicle.description} ${Money.format(vehicle.depositFee)} refundable deposit.',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.7),
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
                        Text(Money.format(total),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        Text(
                          days == null
                              ? 'Pick your dates'
                              : '$days ${days == 1 ? 'day' : 'days'} total',
                          style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
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
                                state.requestRental(
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
                                  days: days!,
                                  totalFare: total,
                                );
                                showDialog(
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
                                        // Cleans the stack instead of popping a
                                        // guessed number of times: the dialog,
                                        // this screen and the list all close and
                                        // Home is left as the only route.
                                        onPressed: () {
                                          Navigator.pop(context);
                                          Navigator.of(context).pushNamedAndRemoveUntil(
                                            '/home',
                                            (route) => false,
                                          );
                                        },
                                        child: const Text('Back to Home'),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context); // close dialog
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(builder: (_) => const ActiveRentalScreen()),
                                          );
                                        },
                                        child: const Text('View Request'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            // Disabled when the period is not free; see the
                            // notice above for which reason applies.
                            : null,
                            // The label has to say which of the reasons it is
                            // disabled: a button that just goes grey teaches
                            // nothing.
                            child: Text(
                          blockedByExistingRequest
                              ? 'Rental Already Requested'
                              : availability.canBook
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
}
