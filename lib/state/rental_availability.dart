import 'dart:math' as math;

import '../data/db_models.dart';
import '../data/models.dart';
import 'rental_status.dart';

/// Whether a listing can be booked for a given period, and if not, why.
///
/// Availability is derived, never stored. [AppState.rentalAvailability]
/// combines the two things that can actually make a vehicle unavailable:
///
/// - the listing's own status (`Maintenance` takes it out of service
///   entirely, `Rented` means it is out now but has free days ahead), and
/// - the bookings already held against it.
///
/// Deriving it means a booking cannot disagree with the listing: there is one
/// calculation, and every screen reads the same answer.
enum RentalUnavailabilityReason {
  none,

  /// The listing is in the workshop, so no dates work.
  maintenance,

  /// The listing is out with a renter right now, so only future dates work.
  currentlyRented,

  /// Another booking already holds the requested days.
  datesBooked,
}

/// A listing's bookability as shown in the browse list, before any dates have
/// been chosen.
///
/// Separate from [RentalAvailability] because that type answers a question
/// about a specific period, and the list has no period yet. Showing the
/// listing's real state here - rather than the seed's free-text `availability`
/// note - means the list and the detail screen cannot disagree about whether a
/// vehicle can be booked.
enum RentalListingState {
  /// Free to book for a future period.
  available,

  /// Out on rent now, but with free days ahead.
  rented,

  /// In the workshop: no dates work.
  maintenance,

  /// No seeded record backs this listing, so nothing can be claimed about it.
  unknown,
}

/// What the list shows for a listing.
extension RentalListingStateLabel on RentalListingState {
  String get label => switch (this) {
        RentalListingState.available => 'Available',
        RentalListingState.rented => 'Rented now',
        RentalListingState.maintenance => 'Maintenance',
        RentalListingState.unknown => 'Ask the owner',
      };

  /// True when the listing can still be booked for a future period. Only
  /// [RentalListingState.maintenance] is a hard no; a rented vehicle has free
  /// days ahead, so tapping through to dates is still the right move.
  bool get isBookable => this != RentalListingState.maintenance &&
      this != RentalListingState.unknown;
}

/// The bookable windows of one listing, for a proposed period.
class RentalAvailability {
  const RentalAvailability({
    required this.canBook,
    this.reason = RentalUnavailabilityReason.none,

    /// The conflicting booking, when [reason] is [RentalUnavailabilityReason.datesBooked].
    this.conflict,

    /// The conflicting window when the clash came from a seeded owner-facing
    /// request rather than a live [RentalBooking].
    this.conflictWindowLabel,
  });

  final bool canBook;
  final RentalUnavailabilityReason reason;

  /// The booking that blocks the requested dates, so the screen can show
  /// *which* dates are taken rather than just refusing.
  final RentalBooking? conflict;

  /// A booking held in the seeded owner-facing records, which is not a
  /// [RentalBooking]. Kept as a plain label pair so the caller can name the
  /// dates without depending on the seed type.
  final String? conflictWindowLabel;

  /// Human-readable explanation for the detail screen. Returns null when the
  /// listing can be booked, so a caller can use it as the error text.
  String? get reasonText => switch (reason) {
        RentalUnavailabilityReason.none => null,
        RentalUnavailabilityReason.maintenance =>
          'This vehicle is in the workshop and cannot be booked yet.',
        RentalUnavailabilityReason.currentlyRented =>
          'This vehicle is out on rent right now. Pick a later pickup date.',
        RentalUnavailabilityReason.datesBooked =>
          'Those dates are already booked${conflictWindowLabel != null ? ' ($conflictWindowLabel)' : ''}. '
              'Try a different period.',
      };
}

/// Works out whether [vehicleId] is free for [pickupDate]..[returnDate].
///
/// [bookings] are this listing's live [RentalBooking]s, [ownerRequests] the
/// seeded owner-facing requests, and [vehicle] the listing itself. All three
/// are checked because all three can block a date: a listing can be `Rented`
/// while carrying no booking of its own, and a seeded request can hold days
/// that a fresh booking would collide with.
///
/// A day counts as taken when it falls inside either period, inclusive at both
/// ends — a return day is still occupied by cleaning and handover.
RentalAvailability checkRentalAvailability({
  required OwnedVehicle? vehicle,
  required DateTime pickupDate,
  required DateTime returnDate,
  List<RentalBooking> bookings = const [],
  List<OwnerBookingRequest> ownerRequests = const [],
}) {
  if (returnDate.isBefore(pickupDate)) {
    return const RentalAvailability(
      canBook: false,
      reason: RentalUnavailabilityReason.datesBooked,
    );
  }

  // A vehicle in the workshop is out of service for every date, so this is
  // checked before any date arithmetic.
  if (vehicle != null && vehicle.status == 'Maintenance') {
    return const RentalAvailability(
      canBook: false,
      reason: RentalUnavailabilityReason.maintenance,
    );
  }

  // A booking that holds or will hold the vehicle blocks those days.
  for (final b in bookings) {
    if (!b.blocksAvailability) continue;
    if (b.overlapsDays(pickupDate, returnDate)) {
      return RentalAvailability(
        canBook: false,
        reason: RentalUnavailabilityReason.datesBooked,
        conflict: b,
      );
    }
  }

  // Seeded owner-facing requests only ever sit at requested/declined, but a
  // pending request still contests the dates: letting two renters hold the same
  // weekend and sorting it out later is how a listing gets double-booked.
  for (final r in ownerRequests) {
    if (r.status != RentalStatus.requested) continue;
    if (r.startAt == null || r.endAt == null) continue;
    final start = r.startAt!;
    final end = r.endAt!;
    if (end.isBefore(pickupDate) || start.isAfter(returnDate)) continue;
    return RentalAvailability(
      canBook: false,
      reason: RentalUnavailabilityReason.datesBooked,
      conflictWindowLabel: '${r.startDate} – ${r.endDate}',
    );
  }

  // No date clash. The listing being out *now* only matters if the requested
  // window has already started: future days are genuinely free.
  final today = _todayOnly();
  final startsInPast = pickupDate.isBefore(today);
  if (vehicle != null && vehicle.status == 'Rented' && startsInPast) {
    return const RentalAvailability(
      canBook: false,
      reason: RentalUnavailabilityReason.currentlyRented,
    );
  }

  return const RentalAvailability(canBook: true);
}

/// Number of nights/days between two dates, counting the pickup day and
/// excluding the return day.
///
/// Returns null when the period is invalid, so a caller cannot compute a total
/// from a reversed range. `end.difference(start).inDays` is 0 for a same-day
/// rental, which would look free, so a same-day rental is charged as one day.
int? rentalDayCount(DateTime start, DateTime end) {
  if (end.isBefore(start)) return null;
  final days = _dateOnly(end).difference(_dateOnly(start)).inDays;
  return math.max(1, days);
}

DateTime _todayOnly() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);