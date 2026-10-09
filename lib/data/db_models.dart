import 'package:flutter/material.dart';

import '../state/pasuyo_status.dart';
import '../state/rental_status.dart';
import '../state/ride_status.dart';

/// Typed wrappers around the raw JSON records in the `assets/db/` seed files.
/// Every model below has a `fromJson` factory so DbService can parse the
/// "temporary database" once at startup. Nothing here talks to a real
/// backend — this is purely an offline UI simulation.
///
/// Every amount in these files is an integer number of centavos.
///
/// Records that used to carry only a display string (e.g. "Aug 28, 2026 ·
/// 6:40 PM") also carry a real ISO 8601 field. Keep the string for rendering
/// and use the parsed `DateTime` for sorting, filtering or grouping — never
/// try to sort by the display string.
DateTime? parseIsoTimestamp(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

class NotificationItem {
  final String id;
  final String type; // promo, ride, payment, system, safety, rating
  final String title;
  final String body;
  final String time;
  bool read;

  NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.time,
    required this.read,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> j) => NotificationItem(
        id: j['id'],
        type: j['type'],
        title: j['title'],
        body: j['body'],
        time: j['time'],
        read: j['read'] ?? false,
      );

  IconData get icon {
    switch (type) {
      case 'promo':
        return Icons.local_offer_outlined;
      case 'ride':
        return Icons.electric_rickshaw;
      case 'payment':
        return Icons.account_balance_wallet_outlined;
      case 'safety':
        return Icons.shield_outlined;
      case 'rating':
        return Icons.star_border_rounded;
      default:
        return Icons.notifications_none;
    }
  }
}

class WalletTransaction {
  final String id;
  final String type; // debit, credit, topup, payout
  final String title;
  final int amount;
  final String date;
  final String status;

  /// Real posting time; null if the seed omitted it.
  final DateTime? createdAt;

  /// Explicit classification for entries that need totalling, e.g. `bonus`.
  ///
  /// Preferred over sniffing [title]: a title is copy the UI may reword, and
  /// matching on it silently changes totals when the wording changes.
  final String? kind;

  const WalletTransaction({
    required this.id,
    required this.type,
    required this.title,
    required this.amount,
    required this.date,
    required this.status,
    this.createdAt,
    this.kind,
  });

  factory WalletTransaction.fromJson(Map<String, dynamic> j) =>
      WalletTransaction(
        id: j['id'],
        type: j['type'],
        title: j['title'],
        amount: j['amount'],
        date: j['date'],
        status: j['status'],
        createdAt: parseIsoTimestamp(j['createdAt']),
        kind: j['kind'],
      );

  bool get isPositive => type == 'topup' || type == 'credit';
}

class PaymentMethodItem {
  final String id;
  final String type; // cash, gcash, maya, card
  final String label;
  final String detail;
  bool isDefault;

  PaymentMethodItem({
    required this.id,
    required this.type,
    required this.label,
    required this.detail,
    required this.isDefault,
  });

  factory PaymentMethodItem.fromJson(Map<String, dynamic> j) =>
      PaymentMethodItem(
        id: j['id'],
        type: j['type'],
        label: j['label'],
        detail: j['detail'],
        isDefault: j['isDefault'] ?? false,
      );

  IconData get icon {
    switch (type) {
      case 'gcash':
        return Icons.qr_code_2_rounded;
      case 'maya':
        return Icons.credit_card;
      case 'card':
        return Icons.credit_card;
      default:
        return Icons.payments_outlined;
    }
  }
}

class SavedPlace {
  final String id;
  final String label;
  final String address;
  final String icon; // home, work, place

  const SavedPlace({
    required this.id,
    required this.label,
    required this.address,
    required this.icon,
  });

  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
        id: j['id'],
        label: j['label'],
        address: j['address'],
        icon: j['icon'],
      );

  IconData get iconData {
    switch (icon) {
      case 'home':
        return Icons.home_outlined;
      case 'work':
        return Icons.work_outline;
      default:
        return Icons.place_outlined;
    }
  }
}

class FavoriteRider {
  final String id;
  final String name;
  final String initials;
  final double rating;
  final int trips;
  final String vehicleType;
  final String plate;

  const FavoriteRider({
    required this.id,
    required this.name,
    required this.initials,
    required this.rating,
    required this.trips,
    required this.vehicleType,
    required this.plate,
  });

  factory FavoriteRider.fromJson(Map<String, dynamic> j) => FavoriteRider(
        id: j['id'],
        name: j['name'],
        initials: j['initials'],
        rating: (j['rating'] as num).toDouble(),
        trips: j['trips'],
        vehicleType: j['vehicleType'],
        plate: j['plate'],
      );
}

class FavoriteVehicle {
  final String id;
  final String name;
  final String type;
  final int pricePerDay;
  final String ownerName;

  const FavoriteVehicle({
    required this.id,
    required this.name,
    required this.type,
    required this.pricePerDay,
    required this.ownerName,
  });

  factory FavoriteVehicle.fromJson(Map<String, dynamic> j) => FavoriteVehicle(
        id: j['id'],
        name: j['name'],
        type: j['type'],
        pricePerDay: j['pricePerDay'],
        ownerName: j['ownerName'],
      );
}

class EmergencyContactItem {
  final String id;
  final String name;
  final String relation;
  final String phone;

  const EmergencyContactItem({
    required this.id,
    required this.name,
    required this.relation,
    required this.phone,
  });

  factory EmergencyContactItem.fromJson(Map<String, dynamic> j) =>
      EmergencyContactItem(
        id: j['id'],
        name: j['name'],
        relation: j['relation'],
        phone: j['phone'],
      );
}

class RideHistoryItem {
  final String id;
  final String route;
  final String date;
  final int fare;
  final String status;
  final String vehicleType;
  final String driverName;
  final int rating;

  /// Real completion time; null if the seed omitted it. See [parseIsoTimestamp].
  final DateTime? completedAt;

  const RideHistoryItem({
    required this.id,
    required this.route,
    required this.date,
    required this.fare,
    required this.status,
    required this.vehicleType,
    required this.driverName,
    required this.rating,
    this.completedAt,
  });

  factory RideHistoryItem.fromJson(Map<String, dynamic> j) => RideHistoryItem(
        id: j['id'],
        route: j['route'],
        date: j['date'],
        fare: j['fare'],
        status: j['status'],
        vehicleType: j['vehicleType'],
        driverName: j['driverName'],
        rating: j['rating'],
        completedAt: parseIsoTimestamp(j['completedAt']),
      );
}

class RentalHistoryItem {
  final String id;
  final String vehicleName;
  final String ownerName;
  final String startDate;
  final String endDate;
  final int totalFare;
  final String status;

  /// Real pickup/return times; null if the seed omitted them.
  final DateTime? startAt;
  final DateTime? endAt;

  const RentalHistoryItem({
    required this.id,
    required this.vehicleName,
    required this.ownerName,
    required this.startDate,
    required this.endDate,
    required this.totalFare,
    required this.status,
    this.startAt,
    this.endAt,
  });

  factory RentalHistoryItem.fromJson(Map<String, dynamic> j) =>
      RentalHistoryItem(
        id: j['id'],
        vehicleName: j['vehicleName'],
        ownerName: j['ownerName'],
        startDate: j['startDate'],
        endDate: j['endDate'],
totalFare: j['totalFare'],
        status: j['status'],
        startAt: parseIsoTimestamp(j['startAt']),
        endAt: parseIsoTimestamp(j['endAt']),
      );
}

class RiderTripItem {
  final String id;
  final String passengerName;
  final String route;
  final String date;
  final int fare;
  final double distanceKm;
  final String status;
  final int rating;

  /// Real completion time; null if the seed omitted it.
  final DateTime? completedAt;

  const RiderTripItem({
    required this.id,
    required this.passengerName,
    required this.route,
    required this.date,
    required this.fare,
    required this.distanceKm,
    required this.status,
    required this.rating,
    this.completedAt,
  });

  factory RiderTripItem.fromJson(Map<String, dynamic> j) => RiderTripItem(
        id: j['id'],
        passengerName: j['passengerName'],
        route: j['route'],
        date: j['date'],
        fare: j['fare'],
        distanceKm: (j['distanceKm'] as num).toDouble(),
        status: j['status'],
        rating: j['rating'],
        completedAt: parseIsoTimestamp(j['completedAt']),
      );
}

class DailyEarning {
  final String day;

  /// Mutable because completing a job credits today's bucket.
  int amount;

  /// Real date behind the [day] weekday label, so the 7-day chart can key on a
  /// date instead of assuming a fixed weekday order. Null if the seed omitted it.
  final DateTime? date;

  DailyEarning({required this.day, required this.amount, this.date});

  factory DailyEarning.fromJson(Map<String, dynamic> j) => DailyEarning(
        day: j['day'],
        amount: j['amount'],
        date: parseIsoTimestamp(j['date']),
      );
}

class PayoutItem {
  final String id;
  final String date;
  final int amount;
  final String method;
  final String status;

  /// Real payout time; null if the seed omitted it.
  final DateTime? createdAt;

  const PayoutItem({
    required this.id,
    required this.date,
    required this.amount,
    required this.method,
    required this.status,
    this.createdAt,
  });

  factory PayoutItem.fromJson(Map<String, dynamic> j) => PayoutItem(
        id: j['id'],
        date: j['date'],
        amount: j['amount'],
        method: j['method'],
        status: j['status'],
        createdAt: parseIsoTimestamp(j['createdAt']),
      );
}

class PassengerProfile {
  final String id;
  final String name;
  final String firstName;
  final String initials;
  final String phone;
  final String email;
  final double rating;
  final int totalRides;
  final int memberSince;
  final bool verified;

  const PassengerProfile({
    required this.id,
    required this.name,
    required this.firstName,
    required this.initials,
    required this.phone,
    required this.email,
    required this.rating,
    required this.totalRides,
    required this.memberSince,
    required this.verified,
  });

  factory PassengerProfile.fromJson(Map<String, dynamic> j) => PassengerProfile(
        id: j['id'],
        name: j['name'],
        firstName: j['firstName'],
        initials: j['initials'],
        phone: j['phone'],
        email: j['email'],
        rating: (j['rating'] as num).toDouble(),
        totalRides: j['totalRides'],
        memberSince: j['memberSince'],
        verified: j['verified'] ?? false,
      );
}

/// What an Earner is willing to take on.
///
/// This is the thing that was missing between "Rider" and the rest of the app.
/// A driver who only accepts ride requests, a courier who only takes errand
/// and delivery work, and someone who will take either are all real, and the
/// app could not tell them apart before: every Earner saw every job.
enum EarnerCapability {
  /// Passenger rides.
  rides,

  /// Errands: shopping, pharmacy, laundry, parcel drop-off.
  errands,

  /// Food and parcel delivery for a buyer who is already waiting.
  deliveries;

  /// Parses a seeded capability key. Unknown keys map to [rides], which is the
  /// capability the role had before this list existed - so an older seed keeps
  /// working instead of loading with nothing enabled.
  static EarnerCapability fromJson(Object? raw) => switch ('$raw') {
        'rides' => EarnerCapability.rides,
        'errands' => EarnerCapability.errands,
        'deliveries' => EarnerCapability.deliveries,
        _ => EarnerCapability.rides,
      };

  String get jsonKey => switch (this) {
        EarnerCapability.rides => 'rides',
        EarnerCapability.errands => 'errands',
        EarnerCapability.deliveries => 'deliveries',
      };

  /// Label for the capability toggles, e.g. "Passenger rides".
  String get label => switch (this) {
        EarnerCapability.rides => 'Passenger rides',
        EarnerCapability.errands => 'Errands',
        EarnerCapability.deliveries => 'Deliveries',
      };

  /// One line explaining what the capability covers, for the toggle's subtitle.
  String get hint => switch (this) {
        EarnerCapability.rides => 'Drive passengers around Tandag.',
        EarnerCapability.errands =>
          'Shop, pick up medicine, drop off parcels.',
        EarnerCapability.deliveries => 'Bring food and parcels to a buyer.',
      };
}

/// Whether one [EarnerCapability] is switched on for a given earner.
class EarnerAvailability {
  final EarnerCapability capability;
  final bool enabled;

  const EarnerAvailability({
    required this.capability,
    required this.enabled,
  });

  EarnerAvailability copyWith({bool? enabled}) => EarnerAvailability(
        capability: capability,
        enabled: enabled ?? this.enabled,
      );
}

/// The signed-in Earner: their identity, their vehicle, and what they take.
///
/// Renamed from `Rider` because the role is no longer only about driving
/// passengers. `capabilities` carries the change: it is the reason an Earner
/// can be offered an errand at all, and the reason a Vehicle Owner - who has
/// no such list - never is.
class EarnerProfile {
  final String id;
  final String name;
  final String initials;
  final String phone;
  final String email;
  final double rating;
  final int totalTrips;
  final int memberSince;
  final bool verified;

  /// The vehicle used for [EarnerCapability.rides].
  final String vehicleType;
  final String vehicleModel;
  final String vehiclePlate;
  final String documentsStatus;

  /// One entry per capability, so a capability the seed never mentions has a
  /// defined state instead of being absent from the map.
  final Map<EarnerCapability, EarnerAvailability> capabilities;

  EarnerProfile({
    required this.id,
    required this.name,
    required this.initials,
    required this.phone,
    required this.email,
    required this.rating,
    required this.totalTrips,
    required this.memberSince,
    required this.verified,
    required this.vehicleType,
    required this.vehicleModel,
    required this.vehiclePlate,
    required this.documentsStatus,
    required Map<EarnerCapability, EarnerAvailability> capabilities,
  }) : capabilities = {
          for (final c in EarnerCapability.values)
            c: capabilities[c] ??
                EarnerAvailability(capability: c, enabled: false),
        };

  /// Whether this Earner takes [capability].
  bool accepts(EarnerCapability capability) =>
      capabilities[capability]?.enabled ?? false;

  /// The capabilities this Earner has switched on, in enum order.
  List<EarnerCapability> get activeCapabilities =>
      EarnerCapability.values.where(accepts).toList();

  /// Turns one capability on or off.
  ///
  /// Refuses to switch off the last active capability: an Earner with nothing
  /// enabled is offline by another name, and the app has no way to show that
  /// state honestly.
  bool setCapability(EarnerCapability capability, bool enabled) {
    if (!enabled && accepts(capability) && activeCapabilities.length <= 1) {
      return false;
    }
    capabilities[capability] =
        capabilities[capability]!.copyWith(enabled: enabled);
    return true;
  }

  factory EarnerProfile.fromJson(Map<String, dynamic> j) {
    final raw = (j['capabilities'] as List?) ?? const [];
    return EarnerProfile(
      id: j['id'],
      name: j['name'],
      initials: j['initials'],
      phone: j['phone'],
      email: j['email'],
      rating: (j['rating'] as num).toDouble(),
      totalTrips: j['totalTrips'],
      memberSince: j['memberSince'],
      verified: j['verified'] ?? false,
      vehicleType: j['vehicleType'],
      vehicleModel: j['vehicleModel'],
      vehiclePlate: j['vehiclePlate'],
      documentsStatus: j['documentsStatus'],
      capabilities: {
        for (final c in EarnerCapability.values)
          c: EarnerAvailability(
            capability: c,
            enabled: raw.any((k) => EarnerCapability.fromJson(k) == c),
          ),
      },
    );
  }
}

class VehicleOwnerProfile {
  final String id;
  final String name;
  final String initials;
  final String phone;
  final String email;
  final double rating;
  final int totalVehicles;
  final int totalRentals;
  final int memberSince;
  final bool verified;

  const VehicleOwnerProfile({
    required this.id,
    required this.name,
    required this.initials,
    required this.phone,
    required this.email,
    required this.rating,
    required this.totalVehicles,
    required this.totalRentals,
    required this.memberSince,
    required this.verified,
  });

  factory VehicleOwnerProfile.fromJson(Map<String, dynamic> j) =>
      VehicleOwnerProfile(
        id: j['id'],
        name: j['name'],
        initials: j['initials'],
        phone: j['phone'],
        email: j['email'],
        rating: (j['rating'] as num).toDouble(),
        totalVehicles: j['totalVehicles'],
        totalRentals: j['totalRentals'],
        memberSince: j['memberSince'],
        verified: j['verified'] ?? false,
      );
}

/// The kinds of work an [Account] can be approved to do on SurGo.
///
/// Distinct from [UserMode] (a login shell): an Earner is approved for
/// `earner` and/or `rider`, so a driver who only takes passenger rides and a
/// courier who only runs errands are different capabilities here even though
/// they share the same Earner shell.
enum CapabilityType {
  passenger,
  earner,
  rider,
  vehicleOwner;

  static CapabilityType fromJson(Object? raw) => switch ('$raw') {
        'passenger' => CapabilityType.passenger,
        'earner' => CapabilityType.earner,
        'rider' => CapabilityType.rider,
        'vehicleOwner' => CapabilityType.vehicleOwner,
        _ => CapabilityType.passenger,
      };

  String get jsonKey => switch (this) {
        CapabilityType.passenger => 'passenger',
        CapabilityType.earner => 'earner',
        CapabilityType.rider => 'rider',
        CapabilityType.vehicleOwner => 'vehicleOwner',
      };

  String get label => switch (this) {
        CapabilityType.passenger => 'Passenger',
        CapabilityType.earner => 'Earner',
        CapabilityType.rider => 'Rider',
        CapabilityType.vehicleOwner => 'Vehicle Owner',
      };
}

/// Whether an [Account] may sign in and use its approved capabilities at all.
enum AccountStatus {
  active,
  suspended;

  static AccountStatus fromJson(Object? raw) =>
      '$raw' == 'suspended' ? AccountStatus.suspended : AccountStatus.active;

  String get label => switch (this) {
        AccountStatus.active => 'Active',
        AccountStatus.suspended => 'Suspended',
      };
}

/// How far verification for one [CapabilityType] has progressed.
enum VerificationStatus {
  draft,
  submitted,
  underReview,
  approved,
  rejected,
  needsResubmission;

  static VerificationStatus fromJson(Object? raw) => switch ('$raw') {
        'submitted' => VerificationStatus.submitted,
        'underReview' => VerificationStatus.underReview,
        'approved' => VerificationStatus.approved,
        'rejected' => VerificationStatus.rejected,
        'needsResubmission' => VerificationStatus.needsResubmission,
        _ => VerificationStatus.draft,
      };

  String get jsonKey => switch (this) {
        VerificationStatus.draft => 'draft',
        VerificationStatus.submitted => 'submitted',
        VerificationStatus.underReview => 'underReview',
        VerificationStatus.approved => 'approved',
        VerificationStatus.rejected => 'rejected',
        VerificationStatus.needsResubmission => 'needsResubmission',
      };

  String get label => switch (this) {
        VerificationStatus.draft => 'Draft',
        VerificationStatus.submitted => 'Submitted',
        VerificationStatus.underReview => 'Under review',
        VerificationStatus.approved => 'Approved',
        VerificationStatus.rejected => 'Rejected',
        VerificationStatus.needsResubmission => 'Action needed',
      };
}

/// One sign-in identity for the local mock.
///
/// This is deliberately not real authentication: [password] is stored in the
/// seed in plaintext and compared in memory. An account can hold any mix of
/// roles, each pointing at the profile it acts as, so one person can be a
/// passenger, an earner and a vehicle owner at the same time.
///
/// What an account may *do* is separate from which profiles it links to:
/// [approvedCapabilities] is the gate the screens enforce, [eligibleCapabilities]
/// is what it may still apply for, and [status] suspends everything at once.
class Account {
  final String id;
  final String name;
  final String phone;
  final String email;
  final String password;

  /// Profile ids this account can act as; null when it lacks the role.
  final String? passengerId;
  final String? riderId;
  final String? ownerId;

  /// The capabilities this account is approved to use right now. This is the
  /// gate the app enforces: eligibility alone never unlocks a mode, and a
  /// reverted document removes the capability here before any screen is shown.
  final Set<CapabilityType> approvedCapabilities;

  /// What this account can apply for. Kept apart from
  /// [approvedCapabilities] so "eligible to become" and "already approved to
  /// act as" are two facts the app can tell apart.
  final Set<CapabilityType> eligibleCapabilities;

  /// Whether the account can sign in. A suspended account is refused at login
  /// even though its capabilities above are unchanged.
  final AccountStatus status;

  Account({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.password,
    this.passengerId,
    this.riderId,
    this.ownerId,
    Set<CapabilityType>? approvedCapabilities,
    Set<CapabilityType>? eligibleCapabilities,
    this.status = AccountStatus.active,
  })  : approvedCapabilities = approvedCapabilities ??
            Account._defaultApprovedFor(passengerId, riderId, ownerId),
        eligibleCapabilities = eligibleCapabilities ??
            {
              for (final c in CapabilityType.values)
                if (!(approvedCapabilities ?? const {}).contains(c)) c,
            };

  bool get isActive => status == AccountStatus.active;

  bool get hasPassengerRole => passengerId != null;
  bool get hasRiderRole => riderId != null;
  bool get hasOwnerRole => ownerId != null;

  /// The capabilities usable while the account is active. A suspended account
  /// returns nothing for the same [approvedCapabilities].
  Set<CapabilityType> get usableCapabilities =>
      isActive ? approvedCapabilities : const {};

  /// Whether [type] is approved *and* the account is active enough to use it.
  bool authorizedFor(CapabilityType type) =>
      isActive && approvedCapabilities.contains(type);

  /// Whether the account may apply for [type]. Approval is a separate fact —
  /// see [authorizedFor].
  bool canApplyFor(CapabilityType type) => eligibleCapabilities.contains(type);

  /// True when [identifier] is this account's phone or email, case-insensitive.
  bool matches(String identifier) {
    final needle = identifier.trim().toLowerCase();
    return needle.isNotEmpty &&
        (phone.toLowerCase() == needle || email.toLowerCase() == needle);
  }

  /// The approved set an old-style seed (roles only, no `capabilities` block)
  /// implies: every role it links to, plus errand work for whoever has an
  /// earner profile — before this list an earner profile could always enter
  /// rider mode.
  static Set<CapabilityType> _defaultApprovedFor(
      String? passengerId, String? riderId, String? ownerId) {
    return {
      if (passengerId != null) CapabilityType.passenger,
      if (riderId != null) CapabilityType.rider,
      if (riderId != null) CapabilityType.earner,
      if (ownerId != null) CapabilityType.vehicleOwner,
    };
  }

  factory Account.fromJson(Map<String, dynamic> j) {
    final roles = j['roles'] is Map<String, dynamic>
        ? j['roles'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final passengerId = roles['passenger'] as String?;
    final riderId = roles['earner'] as String?;
    final ownerId = roles['vehicleOwner'] as String?;

    final caps = j['capabilities'] is Map<String, dynamic>
        ? j['capabilities'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final approvedRaw = caps['approved'];
    final eligibleRaw = caps['eligible'];
    final approved = approvedRaw is List
        ? {for (final c in approvedRaw) CapabilityType.fromJson(c)}
        : Account._defaultApprovedFor(passengerId, riderId, ownerId);

    return Account(
      id: j['id'],
      name: j['name'],
      phone: j['phone'],
      email: j['email'],
      password: j['password'] ?? '',
      passengerId: passengerId,
      riderId: riderId,
      ownerId: ownerId,
      approvedCapabilities: approved,
      eligibleCapabilities: eligibleRaw is List
          ? {for (final c in eligibleRaw) CapabilityType.fromJson(c)}
          : {
              for (final c in CapabilityType.values)
                if (!approved.contains(c)) c,
            },
      status: AccountStatus.fromJson(j['accountStatus']),
    );
  }
}

/// One document in a [VerificationApplication]. Only metadata: the prototype
/// never stores real document bytes, just each requirement plus what has been
/// "uploaded" for it in the demo.
class VerificationDocumentItem {
  final String id;

  /// Which capability this document proves. Binds the requirement to a single
  /// application because an NBI clearance proves an errand applicant's record,
  /// not their drive-to-park-at-night fitness.
  final CapabilityType capabilityType;
  final String label;
  final String hint;
  final bool required;
  bool uploaded;
  String? fileName;

  VerificationDocumentItem({
    required this.id,
    required this.capabilityType,
    required this.label,
    this.hint = '',
    this.required = true,
    this.uploaded = false,
    this.fileName,
  });

  factory VerificationDocumentItem.fromJson(Map<String, dynamic> j) =>
      VerificationDocumentItem(
        id: j['id'],
        capabilityType: CapabilityType.fromJson(j['capability']),
        label: j['label'],
        hint: j['hint'] ?? '',
        required: j['required'] ?? true,
        uploaded: j['uploaded'] ?? false,
        fileName: j['fileName'],
      );
}

/// An application for one [CapabilityType], from document collection through
/// review to approval. Approval here is what moves a capability out of
/// [Account.eligibleCapabilities] and into [Account.approvedCapabilities].
class VerificationApplication {
  final String id;
  final String accountId;
  final CapabilityType capabilityType;
  VerificationStatus status;
  DateTime? submittedAt;
  DateTime? reviewedAt;
  String? reviewerNote;
  final List<VerificationDocumentItem> documents;

  VerificationApplication({
    required this.id,
    required this.accountId,
    required this.capabilityType,
    this.status = VerificationStatus.draft,
    this.submittedAt,
    this.reviewedAt,
    this.reviewerNote,
    required this.documents,
  });

  /// Whether every required document has been uploaded. An application cannot
  /// be submitted until this is true.
  bool get isComplete => documents.every((d) => !d.required || d.uploaded);

  /// Whether the account can submit for review right now.
  bool get canSubmit => isComplete && status == VerificationStatus.draft;

  bool get isApproved => status == VerificationStatus.approved;

  factory VerificationApplication.fromJson(Map<String, dynamic> j) =>
      VerificationApplication(
        id: j['id'],
        accountId: j['accountId'],
        capabilityType: CapabilityType.fromJson(j['capability']),
        status: VerificationStatus.fromJson(j['status']),
        submittedAt: parseIsoTimestamp(j['submittedAt']),
        reviewedAt: parseIsoTimestamp(j['reviewedAt']),
        reviewerNote: j['reviewerNote'],
        documents: [
          for (final d in (j['documents'] as List? ?? const []))
            if (d is Map<String, dynamic>) VerificationDocumentItem.fromJson(d),
        ],
      );

  /// Serialized for the local JSON server; the seed file uses the same shape.
  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'capability': capabilityType.jsonKey,
        'status': status.jsonKey,
        'submittedAt': submittedAt?.toIso8601String(),
        'reviewedAt': reviewedAt?.toIso8601String(),
        'reviewerNote': reviewerNote,
        'documents': [
          for (final d in documents)
            {
              'id': d.id,
              'capability': d.capabilityType.jsonKey,
              'label': d.label,
              'hint': d.hint,
              'required': d.required,
              'uploaded': d.uploaded,
              'fileName': d.fileName,
            },
        ],
      };
}

/// One barangay in Tandag City, together with its puroks — used to power
/// the pickup/destination barangay + purok picker.
class Barangay {
  final String name;
  final List<String> puroks;

  const Barangay({required this.name, required this.puroks});

factory Barangay.fromJson(Map<String, dynamic> j) => Barangay(
        name: j['barangay'],
        puroks: (j['puroks'] as List).map((e) => e.toString()).toList(),
      );
}

/// A named landmark with coordinates, from `locations.json`.
///
/// This is the map's own list of places: it is what a pickup/dropoff picker can
/// search, so [label] is what gets shown and [latitude]/[longitude] are what
/// gets passed to the map. Distinct from [SavedPlace], which is a per-person
/// favourite rather than part of the city's geography.
class PlaceItem {
  final String id;
  final String label;
  final String address;
  final String barangay;
  final String purok;
  final double latitude;
  final double longitude;

  /// One of: mall, market, terminal, restaurant, hospital, civic, school,
  /// port, bank. Drives the marker icon on the map.
  final String category;

  const PlaceItem({
    required this.id,
    required this.label,
    required this.address,
    required this.barangay,
    required this.purok,
    required this.latitude,
    required this.longitude,
    required this.category,
  });

  factory PlaceItem.fromJson(Map<String, dynamic> j) => PlaceItem(
        id: j['id'],
        label: j['label'],
        address: j['address'] ?? '',
        barangay: j['barangay'] ?? '',
        purok: j['purok'] ?? '',
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        category: j['category'] ?? 'other',
      );

  IconData get icon {
    switch (category) {
      case 'mall':
        return Icons.shopping_bag_outlined;
      case 'market':
        return Icons.storefront_outlined;
      case 'terminal':
        return Icons.directions_bus_outlined;
      case 'restaurant':
        return Icons.restaurant_outlined;
      case 'hospital':
        return Icons.local_hospital_outlined;
      case 'civic':
        return Icons.account_balance_outlined;
      case 'school':
        return Icons.school_outlined;
      case 'port':
        return Icons.sailing_outlined;
      case 'bank':
        return Icons.payments_outlined;
      default:
        return Icons.place_outlined;
    }
  }
}

/// A rich incoming ride request shown to a rider, with enough detail to
/// support an expandable "view details / map" card.
class RideRequestItem {
  final String id;
  final String? passengerId;

  /// The proposed or accepted rider. Mutable because assignment is a real step
  /// in the flow: [RideStatus.searching] has nobody, confirming a match sets
  /// this, and declining clears it again.
  String? riderId;

  /// The vehicle *type* the passenger chose on the booking screen, stored as
  /// the option's name (e.g. "Tricycle"). Set once when the request is created
  /// and left alone afterwards: matching compares it to a rider's
  /// `MapRider.vehicleType`, while the assigned rider lives in [riderId].
  String? vehicleId;
  final String passengerName;
  final String passengerInitials;
  final double passengerRating;
  final String pickupBarangay;
  final String pickupPurok;
  final String pickup;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final String dropoffBarangay;
  final String dropoffPurok;
  final String dropoff;
  final double? dropoffLatitude;
  final double? dropoffLongitude;
  final double distanceKm;
  final int etaMinutes;
  final int fare;
  final String paymentMethod;
  final String note;
  final String requestedAt;

  /// Where the request sits in [RideStatus]. Never a free-text string: the
  /// enum owns every legal transition, so a status cannot drift out of the
  /// path it is supposed to be on.
  RideStatus status;

  RideRequestItem({
    required this.id,
    this.passengerId,
    this.riderId,
    this.vehicleId,
    required this.passengerName,
    required this.passengerInitials,
    required this.passengerRating,
    required this.pickupBarangay,
    required this.pickupPurok,
    required this.pickup,
    this.pickupLatitude,
    this.pickupLongitude,
    required this.dropoffBarangay,
    required this.dropoffPurok,
    required this.dropoff,
    this.dropoffLatitude,
    this.dropoffLongitude,
    required this.distanceKm,
    required this.etaMinutes,
    required this.fare,
    required this.paymentMethod,
    required this.note,
    required this.requestedAt,
    this.status = RideStatus.searching,
  });

  factory RideRequestItem.fromJson(Map<String, dynamic> j) => RideRequestItem(
        id: j['id'],
        passengerId: j['passengerId'] ?? j['passenger_id'],
        riderId: j['riderId'] ?? j['rider_id'],
        vehicleId: j['vehicleId'] ?? j['vehicle_id'],
        passengerName: j['passengerName'],
        passengerInitials: j['passengerInitials'],
        passengerRating: (j['passengerRating'] as num).toDouble(),
        pickupBarangay: j['pickupBarangay'],
        pickupPurok: j['pickupPurok'],
        pickup: j['pickup'],
        pickupLatitude: (j['pickupLatitude'] as num?)?.toDouble(),
        pickupLongitude: (j['pickupLongitude'] as num?)?.toDouble(),
        dropoffBarangay: j['dropoffBarangay'],
        dropoffPurok: j['dropoffPurok'],
        dropoff: j['dropoff'],
        dropoffLatitude: (j['dropoffLatitude'] as num?)?.toDouble(),
        dropoffLongitude: (j['dropoffLongitude'] as num?)?.toDouble(),
        distanceKm: (j['distanceKm'] as num).toDouble(),
        etaMinutes: j['etaMinutes'],
        fare: j['fare'],
        paymentMethod: j['paymentMethod'],
        note: j['note'] ?? '',
        requestedAt: j['requestedAt'] ?? 'Just now',
        status: RideStatus.fromJson(j['status'] ?? 'Pending'),
      );

  /// True when [target] is this request's one legal next status.
  bool canAdvanceTo(RideStatus target) => status.next == target;

  /// Moves to [target] if the path allows it, and reports whether it did.
  ///
  /// The check lives here rather than at each call site so no screen can offer
  /// or apply an illegal jump. Cancellation is handled separately by [cancel],
  /// because it is reachable from anywhere but a terminal state.
  bool advanceTo(RideStatus target) {
    if (!canAdvanceTo(target)) return false;
    status = target;
    return true;
  }

  /// Cancels from any non-terminal state.
  bool cancel() {
    if (status.isTerminal) return false;
    status = RideStatus.cancelled;
    return true;
  }

  /// The status this request moves to next, or null at a terminal state.
  RideStatus? get nextStatus => status.next;

  String get statusLabel => status.label;
}

/// A verified rider/vehicle compliance document (driver's license, OR/CR).
class VehicleDocumentItem {
  final String id;
  final String title;
  final String number;
  final String status;
  final String expiry;
  final String icon;

  const VehicleDocumentItem({
    required this.id,
    required this.title,
    required this.number,
    required this.status,
    required this.expiry,
    required this.icon,
  });

  factory VehicleDocumentItem.fromJson(Map<String, dynamic> j) =>
      VehicleDocumentItem(
        id: j['id'],
        title: j['title'],
        number: j['number'],
        status: j['status'],
        expiry: j['expiry'],
        icon: j['icon'] ?? 'file',
      );

  IconData get iconData {
    switch (icon) {
      case 'license':
        return Icons.badge_outlined;
      case 'orcr':
        return Icons.description_outlined;
      case 'insurance':
        return Icons.shield_outlined;
      case 'clearance':
        return Icons.verified_user_outlined;
      case 'nbi':
        return Icons.fingerprint;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

/// A vehicle owned by the current user in Vehicle Owner mode.
class OwnedVehicle {
  final String id;
  final String name;
  final String type;
  final String category; // 2-Wheel, 3-Wheel, 4-Wheel, Truck
  final String plate;
  final int pricePerDay;
  String status; // Listed, Rented, Maintenance
  final double rating;
  final int totalRentals;

  OwnedVehicle({
    required this.id,
    required this.name,
    required this.type,
    required this.category,
    required this.plate,
    required this.pricePerDay,
    required this.status,
    required this.rating,
    required this.totalRentals,
  });

  factory OwnedVehicle.fromJson(Map<String, dynamic> j) => OwnedVehicle(
        id: j['id'],
        name: j['name'],
        type: j['type'],
        category: j['category'] ?? categoryForType(j['type']),
        plate: j['plate'],
        pricePerDay: j['pricePerDay'],
        status: j['status'],
        rating: (j['rating'] as num).toDouble(),
        totalRentals: j['totalRentals'],
      );

  /// Best-guess category for vehicles that predate the `category` field.
  static String categoryForType(String type) {
    switch (type) {
      case 'Motorcycle':
      case 'Scooter':
      case 'E-bike':
        return '2-Wheel';
      case 'Tricycle':
        return '3-Wheel';
      case 'Truck':
      case 'Pickup':
        return 'Truck';
      default:
        return '4-Wheel';
    }
  }

  static const categories = ['2-Wheel', '3-Wheel', '4-Wheel', 'Truck'];

  static const typesByCategory = {
    '2-Wheel': ['Motorcycle', 'Scooter', 'E-bike'],
    '3-Wheel': ['Tricycle'],
    '4-Wheel': ['Car', 'Sedan', 'SUV', 'Van', 'Multicab'],
    'Truck': ['Truck', 'Pickup'],
  };

  IconData get icon {
    switch (category) {
      case '2-Wheel':
        return Icons.two_wheeler;
      case '3-Wheel':
        return Icons.electric_rickshaw;
      case 'Truck':
        return Icons.local_shipping_outlined;
      default:
        return type == 'Van' || type == 'Multicab'
            ? Icons.airport_shuttle
            : Icons.directions_car;
    }
  }
}

/// An incoming rental booking request for one of the owner's vehicles.
class OwnerBookingRequest {
  final String id;
  final String? renterId;
  final String? ownerId;
  final String? vehicleId;
  final String renterName;
  final String renterInitials;
  final String vehicleName;
  final String startDate;
  final String endDate;
  final String? startTime;
  final String? endTime;
  final int? durationHours;
  final int totalFare;
  final String? paymentMethod;
  final String? pickupLocation;
  final String? currentLocation;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final double? vehicleLatitude;
  final double? vehicleLongitude;
/// Where this request sits in [RentalStatus]. Seeded requests only ever reach
  /// [RentalStatus.requested] or [RentalStatus.declined]; the later states are
  /// the renter's booking advancing, not this request.
  RentalStatus status;

  /// Real pickup/return times; null if the seed omitted them.
  final DateTime? startAt;
  final DateTime? endAt;

  OwnerBookingRequest({
    required this.id,
    this.renterId,
    this.ownerId,
    this.vehicleId,
    required this.renterName,
    required this.renterInitials,
    required this.vehicleName,
    required this.startDate,
    required this.endDate,
    this.startTime,
    this.endTime,
    this.durationHours,
    required this.totalFare,
    this.paymentMethod,
    this.pickupLocation,
    this.currentLocation,
    this.pickupLatitude,
    this.pickupLongitude,
    this.vehicleLatitude,
    this.vehicleLongitude,
    required this.status,
    this.startAt,
    this.endAt,
  });

  factory OwnerBookingRequest.fromJson(Map<String, dynamic> j) =>
      OwnerBookingRequest(
        id: j['id'],
        renterId: j['renterId'] ?? j['renter_id'],
        ownerId: j['ownerId'] ?? j['owner_id'],
        vehicleId: j['vehicleId'] ?? j['vehicle_id'],
        renterName: j['renterName'],
        renterInitials: j['renterInitials'],
        vehicleName: j['vehicleName'],
        startDate: j['startDate'],
        endDate: j['endDate'],
        startTime: j['startTime'],
        endTime: j['endTime'],
        durationHours: j['durationHours'] as int?,
        totalFare: j['totalFare'],
        paymentMethod: j['paymentMethod'],
        pickupLocation: j['pickupLocation'],
        currentLocation: j['currentLocation'],
        pickupLatitude: (j['pickupLatitude'] as num?)?.toDouble(),
        pickupLongitude: (j['pickupLongitude'] as num?)?.toDouble(),
        vehicleLatitude: (j['vehicleLatitude'] as num?)?.toDouble(),
        vehicleLongitude: (j['vehicleLongitude'] as num?)?.toDouble(),
status: RentalStatus.fromJson(j['status'] ?? 'Pending'),
        startAt: parseIsoTimestamp(j['startAt']),
        endAt: parseIsoTimestamp(j['endAt']),
      );
}

class AccountSettingsData {
  bool pushNotifications;
  bool smsAlerts;
  bool autoAcceptNearby;
  bool lowDataMode;
  String language;

  AccountSettingsData({
    required this.pushNotifications,
    this.smsAlerts = false,
    this.autoAcceptNearby = false,
    required this.lowDataMode,
    required this.language,
  });

  factory AccountSettingsData.fromJson(Map<String, dynamic> j) =>
      AccountSettingsData(
        pushNotifications: j['pushNotifications'] ?? true,
        smsAlerts: j['smsAlerts'] ?? false,
        autoAcceptNearby: j['autoAcceptNearby'] ?? false,
        lowDataMode: j['lowDataMode'] ?? false,
        language: j['language'] ?? 'English',
      );
}

// ============================================================================
// Map V1 — typed wrappers around assets/data/surgo_map_v1_mock_data.json.
// Fixed mock coordinates for riders/rentals/passengers/ride-requests; the
// live device GPS position is resolved separately at runtime by
// LocationService and is never read from this file.
// ============================================================================

/// A point on the map. Kept as a plain lat/lng pair (instead of pulling in
/// latlong2's LatLng here) so this model file has no Flutter-map dependency.
class MapPoint {
  final double latitude;
  final double longitude;
  const MapPoint(this.latitude, this.longitude);

  factory MapPoint.fromJson(Map<String, dynamic> j) => MapPoint(
        (j['latitude'] as num).toDouble(),
        (j['longitude'] as num).toDouble(),
      );
}

class MapConfigData {
  final MapPoint defaultCenter;
  final double defaultZoom;
  final String city;
  final String province;

  const MapConfigData({
    required this.defaultCenter,
    required this.defaultZoom,
    required this.city,
    required this.province,
  });

  factory MapConfigData.fromJson(Map<String, dynamic> j) => MapConfigData(
        defaultCenter: MapPoint.fromJson(j['default_center']),
        defaultZoom: (j['default_zoom'] as num).toDouble(),
        city: j['city'] ?? 'Tandag City',
        province: j['province'] ?? 'Surigao del Sur',
      );
}

/// A fixed mock rider/driver shown on the map (motorcycle or tricycle).
class MapRider {
  final String id;
  final String name;
  final String vehicleType; // motorcycle, tricycle
  final String vehicleModel;
  final String markerType;
  final MapPoint position;
  final String barangay;
  final String purok;
  final double rating;
  final bool available;
  final bool verified;
  final int estimatedFare;

  /// Real plate, carried in the map seed so the live trip screen can show the
  /// assigned rider's vehicle. The matching card uses a vehicle-type monogram
  /// only because it has no plate; once a rider is assigned, they do.
  final String vehiclePlate;

  /// Completed trips, shown next to the rating as social proof.
  final int totalTrips;

  const MapRider({
    required this.id,
    required this.name,
    required this.vehicleType,
    required this.vehicleModel,
    required this.markerType,
    required this.position,
    required this.barangay,
    required this.purok,
    required this.rating,
    required this.available,
    required this.verified,
    required this.estimatedFare,
    this.vehiclePlate = '',
    this.totalTrips = 0,
  });

  /// Two-letter monogram for the avatar, derived the same way as
  /// [RideMatchProposal.initials] - `substring` rather than `characters`,
  /// which is not a declared dependency.
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  factory MapRider.fromJson(Map<String, dynamic> j) => MapRider(
        id: j['id'],
        name: j['name'],
        vehicleType: j['vehicle_type'],
        vehicleModel: j['vehicle_model'],
        markerType: j['marker_type'] ?? j['vehicle_type'],
        position: MapPoint(
          (j['latitude'] as num).toDouble(),
          (j['longitude'] as num).toDouble(),
        ),
        barangay: j['barangay'] ?? '',
        purok: j['purok'] ?? '',
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        available: j['available'] ?? false,
        verified: j['verified'] ?? false,
        estimatedFare: (j['estimated_fare'] as num?)?.toInt() ?? 0,
        vehiclePlate: j['vehicle_plate'] ?? '',
        totalTrips: (j['total_trips'] as num?)?.toInt() ?? 0,
      );
}

/// A fixed mock rental vehicle shown on the map.
class MapRentalVehicle {
  final String id;
  final String ownerId;
  final String name;
  final String vehicleType; // motorcycle, tricycle, van, multicab
  final String markerType;
  final MapPoint position;
  final String barangay;
  final String purok;
  final int pricePerDay;
  final int pricePerHour;
  final double rating;
  final bool available;
  final bool verified;

  const MapRentalVehicle({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.vehicleType,
    required this.markerType,
    required this.position,
    required this.barangay,
    required this.purok,
    required this.pricePerDay,
    required this.pricePerHour,
    required this.rating,
    required this.available,
    required this.verified,
  });

  factory MapRentalVehicle.fromJson(Map<String, dynamic> j) => MapRentalVehicle(
        id: j['id'],
        ownerId: j['owner_id'] ?? '',
        name: j['name'],
        vehicleType: j['vehicle_type'],
        markerType: j['marker_type'] ?? 'rental',
        position: MapPoint(
          (j['latitude'] as num).toDouble(),
          (j['longitude'] as num).toDouble(),
        ),
        barangay: j['barangay'] ?? '',
        purok: j['purok'] ?? '',
        pricePerDay: (j['price_per_day'] as num?)?.toInt() ?? 0,
        pricePerHour: (j['price_per_hour'] as num?)?.toInt() ?? 0,
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        available: j['available'] ?? false,
        verified: j['verified'] ?? false,
      );
}

/// A fixed mock passenger shown on the map (rider-mode view).
class MapPassenger {
  final String id;
  final String name;
  final MapPoint position;
  final String barangay;
  final String purok;
  final double rating;
  final bool verified;
  final String requestStatus;

  const MapPassenger({
    required this.id,
    required this.name,
    required this.position,
    required this.barangay,
    required this.purok,
    required this.rating,
    required this.verified,
    required this.requestStatus,
  });

  factory MapPassenger.fromJson(Map<String, dynamic> j) => MapPassenger(
        id: j['id'],
        name: j['name'],
        position: MapPoint(
          (j['latitude'] as num).toDouble(),
          (j['longitude'] as num).toDouble(),
        ),
        barangay: j['barangay'] ?? '',
        purok: j['purok'] ?? '',
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        verified: j['verified'] ?? false,
        requestStatus: j['request_status'] ?? 'waiting',
      );
}

/// A fixed mock incoming ride request, linked to a [MapPassenger] by id.
class MapRideRequest {
  final String id;
  final String passengerId;
  final String preferredVehicleType;
  final MapPoint pickup;
  final String pickupBarangay;
  final String pickupPurok;
  final String destinationBarangay;
  final String destinationPurok;
  final double estimatedDistanceKm;
  final int estimatedFare;
  final String paymentMethod;
  final String status;

  const MapRideRequest({
    required this.id,
    required this.passengerId,
    required this.preferredVehicleType,
    required this.pickup,
    required this.pickupBarangay,
    required this.pickupPurok,
    required this.destinationBarangay,
    required this.destinationPurok,
    required this.estimatedDistanceKm,
    required this.estimatedFare,
    required this.paymentMethod,
    required this.status,
  });

  factory MapRideRequest.fromJson(Map<String, dynamic> j) {
    final pickup = j['pickup'] as Map<String, dynamic>;
    final dest = j['destination'] as Map<String, dynamic>;
    return MapRideRequest(
      id: j['id'],
      passengerId: j['passenger_id'],
      preferredVehicleType: j['preferred_vehicle_type'] ?? '',
      pickup: MapPoint(
        (pickup['latitude'] as num).toDouble(),
        (pickup['longitude'] as num).toDouble(),
      ),
      pickupBarangay: pickup['barangay'] ?? '',
      pickupPurok: pickup['purok'] ?? '',
      destinationBarangay: dest['barangay'] ?? '',
      destinationPurok: dest['purok'] ?? '',
      estimatedDistanceKm:
          (j['estimated_distance_km'] as num?)?.toDouble() ?? 0,
      estimatedFare: (j['estimated_fare'] as num?)?.toInt() ?? 0,
      paymentMethod: j['payment_method'] ?? 'cash',
      status: j['status'] ?? 'incoming',
    );
  }
}

/// The kind of errand a Pasuyo task covers. [budget] is what the helper is
/// paid for the errand itself; SurGo's service fee is charged on top and is
/// derived through FeeCalculator rather than stored.
enum PasuyoCategory {
  groceries,
  foodDelivery,
  pharmacy,
  parcel,
  laundry,
  other;

  static PasuyoCategory fromJson(String? value) {
    switch (value) {
      case 'groceries':
        return PasuyoCategory.groceries;
      case 'food':
        return PasuyoCategory.foodDelivery;
      case 'pharmacy':
        return PasuyoCategory.pharmacy;
      case 'parcel':
        return PasuyoCategory.parcel;
      case 'laundry':
        return PasuyoCategory.laundry;
      default:
        return PasuyoCategory.other;
    }
  }

  String get label {
    switch (this) {
      case PasuyoCategory.groceries:
        return 'Groceries';
      case PasuyoCategory.foodDelivery:
        return 'Food delivery';
      case PasuyoCategory.pharmacy:
        return 'Pharmacy';
      case PasuyoCategory.parcel:
        return 'Parcel';
      case PasuyoCategory.laundry:
        return 'Laundry';
      case PasuyoCategory.other:
        return 'Other';
    }
  }

  String get jsonKey {
    switch (this) {
      case PasuyoCategory.groceries:
        return 'groceries';
      case PasuyoCategory.foodDelivery:
        return 'food';
      case PasuyoCategory.pharmacy:
        return 'pharmacy';
      case PasuyoCategory.parcel:
        return 'parcel';
      case PasuyoCategory.laundry:
        return 'laundry';
      case PasuyoCategory.other:
        return 'other';
    }
  }

  IconData get icon {
    switch (this) {
      case PasuyoCategory.groceries:
        return Icons.shopping_basket_outlined;
      case PasuyoCategory.foodDelivery:
        return Icons.fastfood_outlined;
      case PasuyoCategory.pharmacy:
        return Icons.local_pharmacy_outlined;
      case PasuyoCategory.parcel:
        return Icons.inventory_2_outlined;
      case PasuyoCategory.laundry:
        return Icons.local_laundry_service_outlined;
      case PasuyoCategory.other:
        return Icons.handyman_outlined;
    }
  }
}

/// One SurGo Pasuyo errand, from the customer's post through to payment.
///
/// Ids follow the same canonical scheme as the rest of the app: customer and
/// helper are `P00x` / `R00x` ids that resolve against the shared passenger and
/// rider records, so a task links to real people on the map.
class PasuyoTask {
  final String id;
  final String customerId;
  String? helperId;
  final PasuyoCategory category;
  final String title;
  final List<String> items;
  final String pickupBarangay;
  final String pickupPurok;
  final String pickup;
  final String dropoffBarangay;
  final String dropoffPurok;
  final String dropoff;
  final int budget;
  final String note;

  /// Display label for when the errand was posted, e.g. "Just now".
  final String requestedAt;

  /// Real post time; null if the seed omitted it. Use this for ordering and
  /// age checks rather than trying to parse [requestedAt].
  final DateTime? requestedAtIso;

  /// Where the errand sits in [PasuyoStatus]. Never a free-text string: the
  /// enum owns the path, so the feed and the details screen cannot disagree
  /// about which action is legal.
  PasuyoStatus status;
  int rating;
  bool rated;

  PasuyoTask({
    required this.id,
    required this.customerId,
    this.helperId,
    required this.category,
    required this.title,
    required this.items,
    required this.pickupBarangay,
    required this.pickupPurok,
    required this.pickup,
    required this.dropoffBarangay,
    required this.dropoffPurok,
    required this.dropoff,
    required this.budget,
    this.note = '',
    this.requestedAt = 'Just now',
    this.requestedAtIso,
    this.status = PasuyoStatus.available,
    this.rating = 0,
    this.rated = false,
  });

  factory PasuyoTask.fromJson(Map<String, dynamic> j) => PasuyoTask(
        id: j['id'],
        customerId: j['customerId'] ?? j['customer_id'] ?? '',
        helperId: j['helperId'] ?? j['helper_id'],
        category: PasuyoCategory.fromJson(j['category']),
        title: j['title'] ?? '',
        items: ((j['items'] as List?) ?? const []).map((e) => '$e').toList(),
        pickupBarangay: j['pickupBarangay'] ?? '',
        pickupPurok: j['pickupPurok'] ?? '',
        pickup: j['pickup'] ?? '',
        dropoffBarangay: j['dropoffBarangay'] ?? '',
        dropoffPurok: j['dropoffPurok'] ?? '',
        dropoff: j['dropoff'] ?? '',
        budget: j['budget'] ?? 0,
        note: j['note'] ?? '',
        requestedAt: j['requestedAt'] ?? 'Just now',
        requestedAtIso: parseIsoTimestamp(j['requestedAtIso']),
        status: PasuyoStatus.fromJson(j['status'] ?? 'available'),
        rating: j['rating'] ?? 0,
        rated: j['rated'] ?? false,
      );

  /// Position in [PasuyoStatus.flow], or -1 for a cancelled errand.
  int get stepIndex => status.stepIndex;

  String get statusLabel => status.label;

  /// A delivered errand is complete. There is no separate `completed` state:
  /// "Mark delivered" is the terminal action, and the customer rating that
  /// follows is a flag rather than a step.
  bool get isComplete => status == PasuyoStatus.delivered;

  /// Unclaimed, so it belongs in the public feed.
  bool get isOpen => status.isOpen;

  bool get isCancelled => status == PasuyoStatus.cancelled;

  /// Claimed and unfinished. An unclaimed errand is not active: treating it as
  /// active would let one helper hold two open errands as "busy" while having
  /// accepted neither.
  bool get isActive => status.isActive;

  /// The status this task moves to next, or null when there is nowhere left
  /// to go (delivered or cancelled).
  PasuyoStatus? get nextStatus => status.next;

  /// Progress label for the stepper, e.g. "Step 2 of 8".
  String get stepLabel => status.stepLabel;

  /// True when [target] is this task's one legal next status.
  bool canAdvanceTo(PasuyoStatus target) => status.next == target;

  /// Moves to [target] if the path allows it, and reports whether it did.
  ///
  /// Rejecting illegal jumps at the model means a screen cannot mark a task
  /// delivered straight from `available`, which would pay out for work never
  /// done. Cancellation is handled by [cancel], reachable from anywhere but a
  /// terminal state.
  bool advanceTo(PasuyoStatus target) {
    if (!canAdvanceTo(target)) return false;
    status = target;
    return true;
  }

  /// Cancels from any non-terminal state.
  bool cancelTask() {
    if (status.isTerminal) return false;
    status = PasuyoStatus.cancelled;
    return true;
  }
}
