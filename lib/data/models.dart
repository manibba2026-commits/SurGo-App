import 'package:flutter/material.dart';

import '../state/rental_status.dart';

/// A vehicle option shown on the "choose a vehicle" step of booking.
///
/// [fare] is an integer number of centavos â€” `4500` is â‚±45.00. See [Money].
class RideOption {
  final String name;
  final IconData icon;
  final String etaLabel;
  final String capacityLabel;
  final int fare;

  const RideOption({
    required this.name,
    required this.icon,
    required this.etaLabel,
    required this.capacityLabel,
    required this.fare,
  });
}

/// A driver / rider profile used for matches and live trips.
class Driver {
  final String name;
  final String initials;
  final double rating;
  final int trips;
  final String plate;
  final String vehicleType;

  const Driver({
    required this.name,
    required this.initials,
    required this.rating,
    required this.trips,
    required this.plate,
    required this.vehicleType,
  });
}

/// A past booking shown on the Home screen's "Recent Bookings".
class RecentBooking {
  final String route;
  final String subtitle;
  final int fare;
  final String status;

  const RecentBooking({
    required this.route,
    required this.subtitle,
    required this.fare,
    required this.status,
  });
}

/// A rentable vehicle listing.
///
/// [pricePerDay] and [depositFee] are integer centavos â€” `90000` is â‚±900.00.
class RentalVehicle {
  /// Stable identity for this listing, so a booking can be traced back to the
  /// listing it holds. Availability is checked per listing, and a name is not
  /// an identity: two owners can both list a "Suzuki Multicab".
  final String id;
  final String name;
  final String type;
  final IconData icon;
  final String location;

  /// Availability as a free-text note from the seed, e.g. "Available today".
  /// This is prose, not a bookable state: the authoritative answer to "can I
  /// book this for those days?" comes from [RentalAvailability], which reads
  /// the vehicle's status and every booking against it. Kept for display only.
  final String availability;
  final int pricePerDay;
  final double rating;
  final String ownerName;
  final String ownerInitials;
  final String description;
  final int depositFee;

const RentalVehicle({
    required this.id,
    required this.name,
    required this.type,
    required this.icon,
    required this.location,
    required this.availability,
    required this.pricePerDay,
    required this.rating,
    required this.ownerName,
    required this.ownerInitials,
    required this.description,
    required this.depositFee,
  });
}

/// The passenger's current rental request, created the moment they tap
/// "Request Rental" and tracked in memory from then on â€” this is what
/// powers the pending-request card on the Home tab and the Active Rental
/// screen. Unlike the classes above it isn't seeded from JSON; it's created
/// and mutated at runtime by [AppState].
class RentalBooking {
  final String id;

  /// Links the booking to the vehicle it holds. Availability is checked
  /// against *this* vehicle, so a booking that cannot be traced back to a
  /// listing could never block that listing from being double-booked.
  final String? vehicleId;
  final String vehicleName;
  final String vehicleType;
  final IconData icon;
  final String ownerName;
  final String ownerInitials;
  final String pickupLabel;
  final String returnLabel;

  /// The rental period as real dates. [pickupLabel] and [returnLabel] are the
  /// display strings; these are what overlap checks compare, because "1 Aug"
  /// cannot be ordered reliably against another booking's dates.
  final DateTime pickupDate;
  final DateTime returnDate;
  final int days;
  final int totalFare;

  /// Where the booking sits in [RentalStatus].
  RentalStatus status;
  DateTime requestedAt;

  RentalBooking({
    required this.id,
    this.vehicleId,
    required this.vehicleName,
    required this.vehicleType,
    required this.icon,
    required this.ownerName,
    required this.ownerInitials,
    required this.pickupLabel,
    required this.returnLabel,
    required this.pickupDate,
    required this.returnDate,
    required this.days,
    required this.totalFare,
    required this.status,
    required this.requestedAt,
  });

  /// True when this booking holds the vehicle across the day [day].
  ///
  /// A rental that ends and another that starts on the same day overlap: the
  /// vehicle has to be returned, cleaned and handed over, and treating them as
  /// separate days is how a listing gets double-booked.
  bool occupiesDay(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final start = DateTime(pickupDate.year, pickupDate.month, pickupDate.day);
    final end = DateTime(returnDate.year, returnDate.month, returnDate.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  /// True when [start]..[end] shares any day with this booking.
  bool overlapsDays(DateTime start, DateTime end) {
    var day = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    if (last.isBefore(day)) return false;
    while (!day.isAfter(last)) {
      if (occupiesDay(day)) return true;
      day = day.add(const Duration(days: 1));
    }
    return false;
  }

  /// A booking that still holds or is about to hold the vehicle blocks it.
  bool get blocksAvailability => status.isOnRent || status.isPending;

  bool canAdvanceTo(RentalStatus target) => status.next == target;

  /// Moves to [target] if the path allows it, and reports whether it did.
  ///
  /// The guard lives here so no screen can skip a step â€” most importantly, so
  /// the owner's payout cannot be released on a vehicle that was never
  /// actually returned.
  bool advanceTo(RentalStatus target) {
    if (!canAdvanceTo(target)) return false;
    status = target;
    return true;
  }

  /// Declines from any non-terminal state. Only the owner does this.
  bool decline() {
    if (status.isTerminal) return false;
    status = RentalStatus.declined;
    return true;
  }

  /// Cancels from any non-terminal state. Only the renter does this.
  bool cancel() {
    if (status.isTerminal) return false;
    status = RentalStatus.cancelled;
    return true;
  }
}

/// Static/mock seed data for the whole simulation.
///
/// Every amount here is integer centavos. These lists are `const`, so they
/// carry literals rather than `Money.pesos(...)`, which cannot be const.
class MockData {
  MockData._();

  static const passengerName = 'Jr Derigay';
  static const passengerFirstName = 'Jr';
  static const passengerInitials = 'JD';
  static const passengerRating = 4.9;
  static const memberSince = 2024;
  static const phoneNumber = '+63 917 512 4809';

  static const List<RideOption> rideOptions = [
    RideOption(
      name: 'Tricycle',
      icon: Icons.electric_rickshaw,
      etaLabel: '2 min away',
      capacityLabel: 'Fits 2',
      fare: 4500,
    ),
    RideOption(
      name: 'Motorcycle',
      icon: Icons.two_wheeler,
      etaLabel: '1 min away',
      capacityLabel: 'Fits 1',
      fare: 3000,
    ),
  ];

  static const Driver matchedDriver = Driver(
    name: 'Junel Ramos',
    initials: 'JR',
    rating: 4.9,
    trips: 1240,
    plate: 'NGD 4821',
    vehicleType: 'Tricycle',
  );

  static const List<RecentBooking> recentBookings = [
    RecentBooking(
      route: 'Poblacion â†’ SM Terminal',
      subtitle: 'Yesterday, 6:40 PM Â· â‚±65.00',
      fare: 6500,
      status: 'Done',
    ),
    RecentBooking(
      route: 'Purok 5 â†’ Barangay Hall',
      subtitle: 'Aug 24, 8:12 AM Â· â‚±30.00',
      fare: 3000,
      status: 'Done',
    ),
  ];

  static const List<RentalVehicle> rentalVehicles = [
RentalVehicle(
      id: 'RV006',
      name: 'Suzuki Multicab',
      type: 'Multicab',
      icon: Icons.airport_shuttle,
      location: 'Poblacion',
      availability: 'Available today',
      pricePerDay: 90000,
      rating: 4.8,
      ownerName: 'Rico D.',
      ownerInitials: 'RD',
      description:
          '7-seater, manual, good for barangay fiesta hauling or a group day trip. Full tank required on return.',
      depositFee: 50000,
    ),
RentalVehicle(
      id: 'RV001',
      name: 'Honda Click 125',
      type: 'Motorcycle',
      icon: Icons.two_wheeler,
      location: 'Purok 5',
      availability: 'Available today',
      pricePerDay: 35000,
      rating: 4.9,
      ownerName: 'Alex Tan',
      ownerInitials: 'AT',
      description:
          'Fuel-efficient automatic scooter, easy to handle on barangay roads. Helmet included, full tank required on return.',
      depositFee: 30000,
    ),
RentalVehicle(
      id: 'RV014',
      name: 'Toyota HiAce Van',
      type: 'Van',
      icon: Icons.airport_shuttle,
      location: 'Downtown',
      availability: 'From tomorrow',
      pricePerDay: 320000,
      rating: 4.7,
      ownerName: 'Nena V.',
      ownerInitials: 'NV',
      description:
          '15-seater van, air-conditioned, ideal for out-of-town trips or large group transport. Driver available on request.',
      depositFee: 200000,
    ),
  ];

  static const riderName = 'Jr Derigay';
  static const riderInitials = 'JD';
  static const riderId = 'R001';
  static const riderEarningsToday = 124000;
  static const riderTripsToday = 4;
  static const riderOnlineTime = '5h 20m';

  static const vehicleOwnerName = 'Jr Derigay';
  static const vehicleOwnerInitials = 'JD';
}
