import '../data/db_models.dart' show PasuyoCategory;
import '../state/pasuyo_status.dart';
import '../state/rental_status.dart';
import '../state/ride_status.dart';
import 'repository_failure.dart';

// Row-shaped records read from Supabase.
//
// They mirror the deployed schema (snake_case columns, enum tokens, centavos
// integers), not the presentation models in `lib/data/db_models.dart`. Keeping
// them separate means a schema change surfaces here instead of quietly
// altering what a widget renders, and it lets the mock repositories produce
// the same types so both modes are interchangeable behind an interface.

// ---------------------------------------------------------------------------
// Column/value helpers
// ---------------------------------------------------------------------------

String requireText(Map<String, dynamic> row, String column) {
  final value = row[column];
  if (value is String && value.isNotEmpty) return value;
  throw RepositoryFailure.invalidData(
    'Row of ${row['_table'] ?? 'an unknown table'} is missing $column.',
  );
}

String? optionalText(Map<String, dynamic> row, String column) {
  final value = row[column];
  if (value is String && value.trim().isNotEmpty) return value;
  return null;
}

int optionalInt(Map<String, dynamic> row, String column, {int or = 0}) {
  final value = row[column];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  return or;
}

double? optionalDouble(Map<String, dynamic> row, String column) {
  final value = row[column];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

bool optionalBool(Map<String, dynamic> row, String column, {bool or = false}) {
  final value = row[column];
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == 't';
  return or;
}

DateTime? optionalTime(Map<String, dynamic> row, String column) {
  final value = row[column];
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

/// A Postgres `date` rendered as `YYYY-MM-DD`.
DateTime? optionalDay(Map<String, dynamic> row, String column) =>
    optionalTime(row, column);

List<Map<String, dynamic>> embeddedRows(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is List) {
    return [
      for (final e in value)
        if (e is Map<String, dynamic>) e
    ];
  }
  if (value is Map<String, dynamic>) return [value];
  return const [];
}

Map<String, dynamic>? embeddedRow(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is Map<String, dynamic>) return value;
  return null;
}

// ---------------------------------------------------------------------------
// Enum token conversion
// ---------------------------------------------------------------------------

/// Strict status parsing. The Dart enums also expose lenient `fromJson`
/// helpers for the seed vocabulary; a Supabase row must not fall through to a
/// default status, because a wrong status shows the wrong action button and
/// could accept a ride nobody has assigned.
RideStatus rideStatusFromDb(String token) => switch (token) {
      'searching' => RideStatus.searching,
      'awaiting_acceptance' => RideStatus.awaitingAcceptance,
      'accepted' => RideStatus.accepted,
      'heading_to_pickup' => RideStatus.headingToPickup,
      'arrived' => RideStatus.arrived,
      'in_progress' => RideStatus.inProgress,
      'completed' => RideStatus.completed,
      'cancelled' => RideStatus.cancelled,
      _ => throw RepositoryFailure.invalidData('Unknown ride status "$token".'),
    };

RentalStatus rentalStatusFromDb(String token) => switch (token) {
      'requested' => RentalStatus.requested,
      'awaiting_owner' => RentalStatus.awaitingOwner,
      'accepted' => RentalStatus.accepted,
      'active' => RentalStatus.active,
      'returned' => RentalStatus.returned,
      'completed' => RentalStatus.completed,
      'declined' => RentalStatus.declined,
      'cancelled' => RentalStatus.cancelled,
      _ =>
        throw RepositoryFailure.invalidData('Unknown rental status "$token".'),
    };

PasuyoStatus pasuyoStatusFromDb(String token) => switch (token) {
      'available' => PasuyoStatus.available,
      'accepted' => PasuyoStatus.accepted,
      'going_to_pickup' => PasuyoStatus.goingToPickup,
      'at_pickup' => PasuyoStatus.atPickup,
      'picked_up' => PasuyoStatus.pickedUp,
      'delivering' => PasuyoStatus.delivering,
      'at_customer' => PasuyoStatus.atCustomer,
      'delivered' => PasuyoStatus.delivered,
      'cancelled' => PasuyoStatus.cancelled,
      _ =>
        throw RepositoryFailure.invalidData('Unknown errand status "$token".'),
    };

/// The database spells the food errand category `food_delivery`, while the
/// seed vocabulary and [PasuyoCategory.jsonKey] use `food`.
String pasuyoCategoryTokenToDb(PasuyoCategory category) =>
    category == PasuyoCategory.foodDelivery
        ? 'food_delivery'
        : category.jsonKey;

PasuyoCategory pasuyoCategoryFromDb(String token) => switch (token) {
      'groceries' => PasuyoCategory.groceries,
      'food_delivery' || 'food' => PasuyoCategory.foodDelivery,
      'pharmacy' => PasuyoCategory.pharmacy,
      'parcel' => PasuyoCategory.parcel,
      'laundry' => PasuyoCategory.laundry,
      'other' => PasuyoCategory.other,
      _ => throw RepositoryFailure.invalidData(
          'Unknown errand category "$token".'),
    };

// ---------------------------------------------------------------------------
// Identity and profiles
// ---------------------------------------------------------------------------

class ProfileRecord {
  const ProfileRecord({
    required this.id,
    required this.fullName,
    this.firstName,
    this.email,
    this.phone,
    this.avatarPath,
    this.accountStatus = 'active',
    this.rating = 5,
    this.totalRides = 0,
    this.lastSeenAt,
    this.createdAt,
  });

  final String id;
  final String fullName;
  final String? firstName;
  final String? email;
  final String? phone;
  final String? avatarPath;
  final String accountStatus;
  final double rating;
  final int totalRides;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;

  bool get isSuspended => accountStatus == 'suspended';

  factory ProfileRecord.fromRow(Map<String, dynamic> row) => ProfileRecord(
        id: requireText(row, 'id'),
        fullName: requireText(row, 'full_name'),
        firstName: optionalText(row, 'first_name'),
        email: optionalText(row, 'email'),
        phone: optionalText(row, 'phone'),
        avatarPath: optionalText(row, 'avatar_path'),
        accountStatus: optionalText(row, 'account_status') ?? 'active',
        rating: optionalDouble(row, 'rating') ?? 5,
        totalRides: optionalInt(row, 'total_rides'),
        lastSeenAt: optionalTime(row, 'last_seen_at'),
        createdAt: optionalTime(row, 'created_at'),
      );
}

class RoleGrantRecord {
  const RoleGrantRecord({
    required this.role,
    required this.status,
    this.approvedAt,
  });

  /// One of `passenger`, `earner`, `rider`, `vehicle_owner`, `admin`.
  final String role;

  /// One of `pending`, `approved`, `suspended`, `revoked`.
  final String status;
  final DateTime? approvedAt;

  bool get isApproved => status == 'approved';

  factory RoleGrantRecord.fromRow(Map<String, dynamic> row) => RoleGrantRecord(
        role: requireText(row, 'role'),
        status: requireText(row, 'status'),
        approvedAt: optionalTime(row, 'approved_at'),
      );
}

class ProviderProfileRecord {
  const ProviderProfileRecord({
    required this.profileId,
    required this.providerType,
    required this.capabilityTokens,
    this.serviceAreaId,
    this.displayName,
    this.bio,
    this.isAvailable = false,
    this.rating = 5,
    this.totalTrips = 0,
  });

  final String profileId;

  /// `earner` or `vehicle_owner`.
  final String providerType;

  /// Raw `earner_capability` tokens: rides, errands, deliveries.
  final List<String> capabilityTokens;
  final String? serviceAreaId;
  final String? displayName;
  final String? bio;
  final bool isAvailable;
  final double rating;
  final int totalTrips;

  factory ProviderProfileRecord.fromRow(Map<String, dynamic> row) {
    final raw = row['capabilities'];
    return ProviderProfileRecord(
      profileId: requireText(row, 'profile_id'),
      providerType: requireText(row, 'provider_type'),
      capabilityTokens: raw is List
          ? [
              for (final c in raw)
                if (c is String) c
            ]
          : const [],
      serviceAreaId: optionalText(row, 'service_area_id'),
      displayName: optionalText(row, 'display_name'),
      bio: optionalText(row, 'bio'),
      isAvailable: optionalBool(row, 'is_available'),
      rating: optionalDouble(row, 'rating') ?? 5,
      totalTrips: optionalInt(row, 'total_trips'),
    );
  }
}

// ---------------------------------------------------------------------------
// Service geography and pricing
// ---------------------------------------------------------------------------

class ServiceAreaRecord {
  const ServiceAreaRecord({
    required this.id,
    required this.name,
    required this.city,
    required this.province,
    this.countryCode = 'PH',
    this.timezone = 'Asia/Manila',
    this.centerLatitude,
    this.centerLongitude,
    this.isActive = true,
  });

  final String id;
  final String name;
  final String city;
  final String province;
  final String countryCode;
  final String timezone;
  final double? centerLatitude;
  final double? centerLongitude;
  final bool isActive;

  factory ServiceAreaRecord.fromRow(Map<String, dynamic> row) =>
      ServiceAreaRecord(
        id: requireText(row, 'id'),
        name: requireText(row, 'name'),
        city: requireText(row, 'city'),
        province: requireText(row, 'province'),
        countryCode: optionalText(row, 'country_code') ?? 'PH',
        timezone: optionalText(row, 'timezone') ?? 'Asia/Manila',
        centerLatitude: optionalDouble(row, 'center_latitude'),
        centerLongitude: optionalDouble(row, 'center_longitude'),
        isActive: optionalBool(row, 'is_active', or: true),
      );
}

class PurokRecord {
  const PurokRecord({required this.id, required this.name, this.barangayId});

  final String id;
  final String name;
  final String? barangayId;

  factory PurokRecord.fromRow(Map<String, dynamic> row) => PurokRecord(
        id: requireText(row, 'id'),
        name: requireText(row, 'name'),
        barangayId: optionalText(row, 'barangay_id'),
      );
}

class BarangayRecord {
  const BarangayRecord({
    required this.id,
    required this.name,
    required this.serviceAreaId,
    this.puroks = const [],
  });

  final String id;
  final String name;
  final String serviceAreaId;
  final List<PurokRecord> puroks;

  factory BarangayRecord.fromRow(Map<String, dynamic> row) => BarangayRecord(
        id: requireText(row, 'id'),
        name: requireText(row, 'name'),
        serviceAreaId: requireText(row, 'service_area_id'),
        puroks: [
          for (final p in embeddedRows(row, 'puroks')) PurokRecord.fromRow(p),
        ],
      );
}

class PricingPolicyRecord {
  const PricingPolicyRecord({
    required this.id,
    required this.name,
    required this.serviceType,
    required this.isActive,
    this.currency = 'PHP',
    this.baseFareCentavos = 0,
    this.perKmCentavos = 0,
    this.perMinuteCentavos = 0,
    this.minimumFareCentavos = 0,
    this.platformFeeFixedCentavos = 0,
    this.platformFeeBps = 0,
    this.effectiveFrom,
    this.effectiveTo,
  });

  final String id;
  final String name;

  /// `ride`, `rental` or `pasuyo`.
  final String serviceType;
  final bool isActive;
  final String currency;
  final int baseFareCentavos;
  final int perKmCentavos;
  final int perMinuteCentavos;
  final int minimumFareCentavos;
  final int platformFeeFixedCentavos;
  final int platformFeeBps;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;

  factory PricingPolicyRecord.fromRow(Map<String, dynamic> row) =>
      PricingPolicyRecord(
        id: requireText(row, 'id'),
        name: requireText(row, 'name'),
        serviceType: requireText(row, 'service_type'),
        isActive: optionalBool(row, 'is_active'),
        currency: optionalText(row, 'currency') ?? 'PHP',
        baseFareCentavos: optionalInt(row, 'base_fare_centavos'),
        perKmCentavos: optionalInt(row, 'per_km_centavos'),
        perMinuteCentavos: optionalInt(row, 'per_minute_centavos'),
        minimumFareCentavos: optionalInt(row, 'minimum_fare_centavos'),
        platformFeeFixedCentavos:
            optionalInt(row, 'platform_fee_fixed_centavos'),
        platformFeeBps: optionalInt(row, 'platform_fee_bps'),
        effectiveFrom: optionalTime(row, 'effective_from'),
        effectiveTo: optionalTime(row, 'effective_to'),
      );
}

// ---------------------------------------------------------------------------
// Vehicles
// ---------------------------------------------------------------------------

class VehicleRecord {
  const VehicleRecord({
    required this.id,
    required this.ownerProfileId,
    required this.name,
    required this.vehicleType,
    required this.category,
    required this.plateNumber,
    this.serviceAreaId,
    this.make,
    this.model,
    this.modelYear,
    this.color,
    this.pricePerDayCentavos = 0,
    this.status = 'pending_verification',
    this.rating = 5,
    this.totalRentals = 0,
    this.ownerName,
  });

  final String id;
  final String ownerProfileId;
  final String name;
  final String vehicleType;

  /// `2-Wheel`, `3-Wheel`, `4-Wheel` or `Truck`.
  final String category;
  final String plateNumber;
  final String? serviceAreaId;
  final String? make;
  final String? model;
  final int? modelYear;
  final String? color;
  final int pricePerDayCentavos;

  /// Raw `vehicle_status` enum token.
  final String status;
  final double rating;
  final int totalRentals;

  /// Null unless the owner row is visible to the reader under RLS. The pilot
  /// policies only expose a profile to its own user, so a renter browsing
  /// listings cannot see the owner's name and no placeholder is substituted.
  final String? ownerName;

  bool get isListed => status == 'active';

  String get statusLabel => switch (status) {
        'active' => 'Listed',
        'pending_verification' => 'Pending verification',
        'inactive' => 'Unlisted',
        'suspended' => 'Suspended',
        _ => status,
      };

  factory VehicleRecord.fromRow(Map<String, dynamic> row) {
    final owner = embeddedRow(row, 'owner');
    return VehicleRecord(
      id: requireText(row, 'id'),
      ownerProfileId: requireText(row, 'owner_profile_id'),
      name: requireText(row, 'name'),
      vehicleType: requireText(row, 'vehicle_type'),
      category: requireText(row, 'category'),
      plateNumber: requireText(row, 'plate_number'),
      serviceAreaId: optionalText(row, 'service_area_id'),
      make: optionalText(row, 'make'),
      model: optionalText(row, 'model'),
      modelYear: optionalInt(row, 'model_year', or: -1) == -1
          ? null
          : optionalInt(row, 'model_year'),
      color: optionalText(row, 'color'),
      pricePerDayCentavos: optionalInt(row, 'price_per_day_centavos'),
      status: optionalText(row, 'status') ?? 'pending_verification',
      rating: optionalDouble(row, 'rating') ?? 5,
      totalRentals: optionalInt(row, 'total_rentals'),
      ownerName: owner == null ? null : optionalText(owner, 'full_name'),
    );
  }
}

class VehicleDocumentRecord {
  const VehicleDocumentRecord({
    required this.id,
    this.vehicleId,
    required this.documentType,
    required this.status,
    this.documentNumber,
    this.storagePath,
    this.issuedAt,
    this.expiresAt,
    this.rejectionReason,
  });

  final String id;

  /// NOT NULL in Postgres. The seed keeps one paperwork set for the owner's
  /// whole fleet rather than per vehicle, so the mock implementation leaves
  /// this null instead of attaching documents to an arbitrary vehicle.
  final String? vehicleId;
  final String documentType;

  /// `pending`, `approved`, `rejected` or `expired`.
  final String status;
  final String? documentNumber;
  final String? storagePath;
  final DateTime? issuedAt;
  final DateTime? expiresAt;
  final String? rejectionReason;

  factory VehicleDocumentRecord.fromRow(Map<String, dynamic> row) =>
      VehicleDocumentRecord(
        id: requireText(row, 'id'),
        vehicleId: requireText(row, 'vehicle_id'),
        documentType: requireText(row, 'document_type'),
        status: requireText(row, 'status'),
        documentNumber: optionalText(row, 'document_number'),
        storagePath: optionalText(row, 'storage_path'),
        issuedAt: optionalDay(row, 'issued_at'),
        expiresAt: optionalDay(row, 'expires_at'),
        rejectionReason: optionalText(row, 'rejection_reason'),
      );
}

// ---------------------------------------------------------------------------
// Rides
// ---------------------------------------------------------------------------

class RideRecord {
  const RideRecord({
    required this.id,
    this.passengerId,
    required this.serviceAreaId,
    required this.status,
    required this.pickupAddress,
    required this.dropoffAddress,
    this.riderId,
    this.pickupBarangayId,
    this.pickupPurokId,
    this.dropoffBarangayId,
    this.dropoffPurokId,
    this.pickupBarangayName,
    this.dropoffBarangayName,
    this.pickupLatitude,
    this.pickupLongitude,
    this.dropoffLatitude,
    this.dropoffLongitude,
    this.distanceKm = 0,
    this.etaMinutes = 0,
    this.fareCentavos = 0,
    this.platformFeeCentavos = 0,
    this.paymentMethod = 'cash',
    this.note,
    this.requestedAt,
    this.acceptedAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancellationReason,
    this.passengerName,
    this.riderName,
  });

  final String id;

  /// NOT NULL in Postgres. Seeded history and trip rows carry no passenger id,
  /// so the mock implementation leaves this null instead of guessing whose ride
  /// it was.
  final String? passengerId;
  final String? riderId;
  final String serviceAreaId;
  final RideStatus status;

  final String pickupAddress;
  final String? pickupBarangayId;
  final String? pickupPurokId;
  final String? pickupBarangayName;
  final double? pickupLatitude;
  final double? pickupLongitude;

  final String dropoffAddress;
  final String? dropoffBarangayId;
  final String? dropoffPurokId;
  final String? dropoffBarangayName;
  final double? dropoffLatitude;
  final double? dropoffLongitude;

  final double distanceKm;
  final int etaMinutes;
  final int fareCentavos;
  final int platformFeeCentavos;
  final String paymentMethod;
  final String? note;

  final DateTime? requestedAt;
  final DateTime? acceptedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;

  /// Counterparty names are only filled when the other party's profile row is
  /// visible to this reader under RLS.
  final String? passengerName;
  final String? riderName;

  factory RideRecord.fromRow(Map<String, dynamic> row) {
    final passenger = embeddedRow(row, 'passenger');
    final rider = embeddedRow(row, 'rider');
    final pickupBarangay = embeddedRow(row, 'pickup_barangay');
    final dropoffBarangay = embeddedRow(row, 'dropoff_barangay');
    return RideRecord(
      id: requireText(row, 'id'),
      passengerId: requireText(row, 'passenger_id'),
      riderId: optionalText(row, 'rider_id'),
      serviceAreaId: requireText(row, 'service_area_id'),
      status: rideStatusFromDb(requireText(row, 'status')),
      pickupAddress: requireText(row, 'pickup_address'),
      pickupBarangayId: optionalText(row, 'pickup_barangay_id'),
      pickupPurokId: optionalText(row, 'pickup_purok_id'),
      pickupBarangayName:
          pickupBarangay == null ? null : optionalText(pickupBarangay, 'name'),
      pickupLatitude: optionalDouble(row, 'pickup_latitude'),
      pickupLongitude: optionalDouble(row, 'pickup_longitude'),
      dropoffAddress: requireText(row, 'dropoff_address'),
      dropoffBarangayId: optionalText(row, 'dropoff_barangay_id'),
      dropoffPurokId: optionalText(row, 'dropoff_purok_id'),
      dropoffBarangayName: dropoffBarangay == null
          ? null
          : optionalText(dropoffBarangay, 'name'),
      dropoffLatitude: optionalDouble(row, 'dropoff_latitude'),
      dropoffLongitude: optionalDouble(row, 'dropoff_longitude'),
      distanceKm: optionalDouble(row, 'distance_km') ?? 0,
      etaMinutes: optionalInt(row, 'eta_minutes'),
      fareCentavos: optionalInt(row, 'fare_centavos'),
      platformFeeCentavos: optionalInt(row, 'platform_fee_centavos'),
      paymentMethod: optionalText(row, 'payment_method') ?? 'cash',
      note: optionalText(row, 'note'),
      requestedAt: optionalTime(row, 'requested_at'),
      acceptedAt: optionalTime(row, 'accepted_at'),
      startedAt: optionalTime(row, 'started_at'),
      completedAt: optionalTime(row, 'completed_at'),
      cancelledAt: optionalTime(row, 'cancelled_at'),
      cancellationReason: optionalText(row, 'cancellation_reason'),
      passengerName:
          passenger == null ? null : optionalText(passenger, 'full_name'),
      riderName: rider == null ? null : optionalText(rider, 'full_name'),
    );
  }
}

class RideStatusEventRecord {
  const RideStatusEventRecord({
    required this.id,
    required this.rideId,
    required this.status,
    this.actorProfileId,
    this.note,
    this.createdAt,
  });

  final String id;
  final String rideId;
  final RideStatus status;
  final String? actorProfileId;
  final String? note;
  final DateTime? createdAt;

  factory RideStatusEventRecord.fromRow(Map<String, dynamic> row) =>
      RideStatusEventRecord(
        id: requireText(row, 'id'),
        rideId: requireText(row, 'ride_id'),
        status: rideStatusFromDb(requireText(row, 'status')),
        actorProfileId: optionalText(row, 'actor_profile_id'),
        note: optionalText(row, 'note'),
        createdAt: optionalTime(row, 'created_at'),
      );
}

class RideRatingRecord {
  const RideRatingRecord({
    required this.id,
    required this.rideId,
    required this.raterId,
    required this.rateeId,
    required this.stars,
    this.comment,
    this.createdAt,
  });

  final String id;
  final String rideId;
  final String raterId;
  final String rateeId;
  final int stars;
  final String? comment;
  final DateTime? createdAt;

  factory RideRatingRecord.fromRow(Map<String, dynamic> row) =>
      RideRatingRecord(
        id: requireText(row, 'id'),
        rideId: requireText(row, 'ride_id'),
        raterId: requireText(row, 'rater_id'),
        rateeId: requireText(row, 'ratee_id'),
        stars: optionalInt(row, 'stars'),
        comment: optionalText(row, 'comment'),
        createdAt: optionalTime(row, 'created_at'),
      );
}

// ---------------------------------------------------------------------------
// Rentals
// ---------------------------------------------------------------------------

class RentalRecord {
  const RentalRecord({
    required this.id,
    this.renterId,
    this.ownerId,
    this.vehicleId,
    required this.serviceAreaId,
    required this.status,
    this.startAt,
    this.endAt,
    this.durationHours,
    this.pickupLocation,
    this.pickupBarangayId,
    this.pickupPurokId,
    this.pickupLatitude,
    this.pickupLongitude,
    this.currentLocation,
    this.vehicleLatitude,
    this.vehicleLongitude,
    this.totalFareCentavos = 0,
    this.platformFeeCentavos = 0,
    this.paymentMethod = 'cash',
    this.acceptedAt,
    this.startedAt,
    this.returnedAt,
    this.completedAt,
    this.declinedAt,
    this.cancelledAt,
    this.cancellationReason,
    this.vehicleName,
    this.vehiclePlateNumber,
  });

  final String id;

  /// All three are NOT NULL in Postgres, so a Supabase read always fills them.
  /// Seeded booking-request and history rows carry only the names, so the mock
  /// implementation leaves the ids null rather than pointing at a guess.
  final String? renterId;
  final String? ownerId;
  final String? vehicleId;
  final String serviceAreaId;
  final RentalStatus status;

  /// NOT NULL in Postgres, so a Supabase read always carries both. Mock seed
  /// history rows can predate the ISO fields, and their display strings are not
  /// parsed here, so these stay nullable for the mock implementation.
  final DateTime? startAt;
  final DateTime? endAt;
  final int? durationHours;

  final String? pickupLocation;
  final String? pickupBarangayId;
  final String? pickupPurokId;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final String? currentLocation;
  final double? vehicleLatitude;
  final double? vehicleLongitude;

  final int totalFareCentavos;
  final int platformFeeCentavos;
  final String paymentMethod;

  final DateTime? acceptedAt;
  final DateTime? startedAt;
  final DateTime? returnedAt;
  final DateTime? completedAt;
  final DateTime? declinedAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;

  final String? vehicleName;
  final String? vehiclePlateNumber;

  factory RentalRecord.fromRow(Map<String, dynamic> row) {
    final vehicle = embeddedRow(row, 'vehicle');
    return RentalRecord(
      id: requireText(row, 'id'),
      renterId: requireText(row, 'renter_id'),
      ownerId: requireText(row, 'owner_id'),
      vehicleId: requireText(row, 'vehicle_id'),
      serviceAreaId: requireText(row, 'service_area_id'),
      status: rentalStatusFromDb(requireText(row, 'status')),
      startAt: optionalTime(row, 'start_at'),
      endAt: optionalTime(row, 'end_at'),
      durationHours: optionalInt(row, 'duration_hours', or: -1) == -1
          ? null
          : optionalInt(row, 'duration_hours'),
      pickupLocation: optionalText(row, 'pickup_location'),
      pickupBarangayId: optionalText(row, 'pickup_barangay_id'),
      pickupPurokId: optionalText(row, 'pickup_purok_id'),
      pickupLatitude: optionalDouble(row, 'pickup_latitude'),
      pickupLongitude: optionalDouble(row, 'pickup_longitude'),
      currentLocation: optionalText(row, 'current_location'),
      vehicleLatitude: optionalDouble(row, 'vehicle_latitude'),
      vehicleLongitude: optionalDouble(row, 'vehicle_longitude'),
      totalFareCentavos: optionalInt(row, 'total_fare_centavos'),
      platformFeeCentavos: optionalInt(row, 'platform_fee_centavos'),
      paymentMethod: optionalText(row, 'payment_method') ?? 'cash',
      acceptedAt: optionalTime(row, 'accepted_at'),
      startedAt: optionalTime(row, 'started_at'),
      returnedAt: optionalTime(row, 'returned_at'),
      completedAt: optionalTime(row, 'completed_at'),
      declinedAt: optionalTime(row, 'declined_at'),
      cancelledAt: optionalTime(row, 'cancelled_at'),
      cancellationReason: optionalText(row, 'cancellation_reason'),
      vehicleName: vehicle == null ? null : optionalText(vehicle, 'name'),
      vehiclePlateNumber:
          vehicle == null ? null : optionalText(vehicle, 'plate_number'),
    );
  }
}

// ---------------------------------------------------------------------------
// Pasuyo
// ---------------------------------------------------------------------------

class ServiceRequestItemRecord {
  const ServiceRequestItemRecord({
    required this.id,
    required this.serviceRequestId,
    required this.name,
    this.quantity = 1,
    this.unit,
    this.estimatedUnitPriceCentavos,
    this.actualUnitPriceCentavos,
    this.notes,
  });

  final String id;
  final String serviceRequestId;
  final String name;
  final double quantity;
  final String? unit;
  final int? estimatedUnitPriceCentavos;
  final int? actualUnitPriceCentavos;
  final String? notes;

  factory ServiceRequestItemRecord.fromRow(Map<String, dynamic> row) =>
      ServiceRequestItemRecord(
        id: requireText(row, 'id'),
        serviceRequestId: requireText(row, 'service_request_id'),
        name: requireText(row, 'name'),
        quantity: optionalDouble(row, 'quantity') ?? 1,
        unit: optionalText(row, 'unit'),
        estimatedUnitPriceCentavos:
            optionalInt(row, 'estimated_unit_price_centavos', or: -1) == -1
                ? null
                : optionalInt(row, 'estimated_unit_price_centavos'),
        actualUnitPriceCentavos:
            optionalInt(row, 'actual_unit_price_centavos', or: -1) == -1
                ? null
                : optionalInt(row, 'actual_unit_price_centavos'),
        notes: optionalText(row, 'notes'),
      );
}

class ServiceRequestRecord {
  const ServiceRequestRecord({
    required this.id,
    required this.customerId,
    required this.serviceAreaId,
    required this.category,
    required this.status,
    required this.title,
    required this.pickupAddress,
    this.providerId,
    this.description,
    this.pickupBarangayId,
    this.pickupPurokId,
    this.pickupBarangayName,
    this.pickupLatitude,
    this.pickupLongitude,
    this.dropoffAddress,
    this.dropoffBarangayId,
    this.dropoffPurokId,
    this.dropoffBarangayName,
    this.dropoffLatitude,
    this.dropoffLongitude,
    this.budgetCentavos,
    this.quotedFeeCentavos = 0,
    this.platformFeeCentavos = 0,
    this.paymentMethod = 'cash',
    this.requestedAt,
    this.acceptedAt,
    this.pickedUpAt,
    this.deliveredAt,
    this.cancelledAt,
    this.cancellationReason,
    this.items = const [],
    this.customerName,
    this.providerName,
  });

  final String id;
  final String customerId;
  final String? providerId;
  final String serviceAreaId;
  final PasuyoCategory category;
  final PasuyoStatus status;
  final String title;
  final String? description;

  final String pickupAddress;
  final String? pickupBarangayId;
  final String? pickupPurokId;
  final String? pickupBarangayName;
  final double? pickupLatitude;
  final double? pickupLongitude;

  final String? dropoffAddress;
  final String? dropoffBarangayId;
  final String? dropoffPurokId;
  final String? dropoffBarangayName;
  final double? dropoffLatitude;
  final double? dropoffLongitude;

  final int? budgetCentavos;
  final int quotedFeeCentavos;
  final int platformFeeCentavos;
  final String paymentMethod;

  final DateTime? requestedAt;
  final DateTime? acceptedAt;
  final DateTime? pickedUpAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;

  final List<ServiceRequestItemRecord> items;

  final String? customerName;
  final String? providerName;

  bool get isOpen => status.isOpen;
  bool get isActive => status.isActive;

  factory ServiceRequestRecord.fromRow(Map<String, dynamic> row) {
    final customer = embeddedRow(row, 'customer');
    final provider = embeddedRow(row, 'provider');
    final pickupBarangay = embeddedRow(row, 'pickup_barangay');
    final dropoffBarangay = embeddedRow(row, 'dropoff_barangay');
    final budget = optionalInt(row, 'budget_centavos', or: -1);
    return ServiceRequestRecord(
      id: requireText(row, 'id'),
      customerId: requireText(row, 'customer_id'),
      providerId: optionalText(row, 'provider_id'),
      serviceAreaId: requireText(row, 'service_area_id'),
      category: pasuyoCategoryFromDb(requireText(row, 'category')),
      status: pasuyoStatusFromDb(requireText(row, 'status')),
      title: requireText(row, 'title'),
      description: optionalText(row, 'description'),
      pickupAddress: requireText(row, 'pickup_address'),
      pickupBarangayId: optionalText(row, 'pickup_barangay_id'),
      pickupPurokId: optionalText(row, 'pickup_purok_id'),
      pickupBarangayName:
          pickupBarangay == null ? null : optionalText(pickupBarangay, 'name'),
      pickupLatitude: optionalDouble(row, 'pickup_latitude'),
      pickupLongitude: optionalDouble(row, 'pickup_longitude'),
      dropoffAddress: optionalText(row, 'dropoff_address'),
      dropoffBarangayId: optionalText(row, 'dropoff_barangay_id'),
      dropoffPurokId: optionalText(row, 'dropoff_purok_id'),
      dropoffBarangayName: dropoffBarangay == null
          ? null
          : optionalText(dropoffBarangay, 'name'),
      dropoffLatitude: optionalDouble(row, 'dropoff_latitude'),
      dropoffLongitude: optionalDouble(row, 'dropoff_longitude'),
      budgetCentavos: budget == -1 ? null : budget,
      quotedFeeCentavos: optionalInt(row, 'quoted_fee_centavos'),
      platformFeeCentavos: optionalInt(row, 'platform_fee_centavos'),
      paymentMethod: optionalText(row, 'payment_method') ?? 'cash',
      requestedAt: optionalTime(row, 'requested_at'),
      acceptedAt: optionalTime(row, 'accepted_at'),
      pickedUpAt: optionalTime(row, 'picked_up_at'),
      deliveredAt: optionalTime(row, 'delivered_at'),
      cancelledAt: optionalTime(row, 'cancelled_at'),
      cancellationReason: optionalText(row, 'cancellation_reason'),
      items: [
        for (final item in embeddedRows(row, 'items'))
          ServiceRequestItemRecord.fromRow(item),
      ],
      customerName:
          customer == null ? null : optionalText(customer, 'full_name'),
      providerName:
          provider == null ? null : optionalText(provider, 'full_name'),
    );
  }
}

class ServiceStatusEventRecord {
  const ServiceStatusEventRecord({
    required this.id,
    required this.serviceRequestId,
    required this.status,
    this.actorProfileId,
    this.note,
    this.createdAt,
  });

  final String id;
  final String serviceRequestId;
  final PasuyoStatus status;
  final String? actorProfileId;
  final String? note;
  final DateTime? createdAt;

  factory ServiceStatusEventRecord.fromRow(Map<String, dynamic> row) =>
      ServiceStatusEventRecord(
        id: requireText(row, 'id'),
        serviceRequestId: requireText(row, 'service_request_id'),
        status: pasuyoStatusFromDb(requireText(row, 'status')),
        actorProfileId: optionalText(row, 'actor_profile_id'),
        note: optionalText(row, 'note'),
        createdAt: optionalTime(row, 'created_at'),
      );
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

class NotificationRecord {
  const NotificationRecord({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.isRead,
    this.data = const {},
    this.readAt,
    this.createdAt,
  });

  final String id;

  /// One of the ten tokens allowed by the notifications check constraint.
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;

  /// [readAt] is the database truth; [isRead] exists because the seed only
  /// stores a boolean and mock mode has no timestamp to derive it from.
  final bool isRead;
  final DateTime? readAt;
  final DateTime? createdAt;

  factory NotificationRecord.fromRow(Map<String, dynamic> row) {
    final readAt = optionalTime(row, 'read_at');
    final raw = row['data'];
    return NotificationRecord(
      id: requireText(row, 'id'),
      type: requireText(row, 'notification_type'),
      title: requireText(row, 'title'),
      body: requireText(row, 'body'),
      data: raw is Map<String, dynamic> ? raw : const {},
      isRead: readAt != null,
      readAt: readAt,
      createdAt: optionalTime(row, 'created_at'),
    );
  }
}

// ---------------------------------------------------------------------------
// Wallet and settlement
// ---------------------------------------------------------------------------

class WalletAccountRecord {
  const WalletAccountRecord({
    required this.id,
    required this.accountType,
    required this.balanceCentavos,
    this.profileId,
    this.currency = 'PHP',
    this.isActive = true,
  });

  final String id;
  final String? profileId;

  /// `passenger`, `earner`, `provider` or `platform`.
  final String accountType;
  final String currency;
  final int balanceCentavos;
  final bool isActive;

  factory WalletAccountRecord.fromRow(Map<String, dynamic> row) =>
      WalletAccountRecord(
        id: requireText(row, 'id'),
        profileId: optionalText(row, 'profile_id'),
        accountType: requireText(row, 'account_type'),
        currency: optionalText(row, 'currency') ?? 'PHP',
        balanceCentavos: optionalInt(row, 'balance_centavos'),
        isActive: optionalBool(row, 'is_active', or: true),
      );
}

class WalletEntryRecord {
  const WalletEntryRecord({
    required this.id,
    required this.walletAccountId,
    required this.type,
    required this.direction,
    required this.amountCentavos,
    this.balanceAfterCentavos,
    this.description,
    this.externalReference,
    this.serviceTransactionId,
    this.createdAt,
  });

  final String id;
  final String walletAccountId;

  /// `top_up`, `earning`, `payout`, `platform_fee`, `adjustment`, `refund`.
  final String type;

  /// `credit` or `debit`.
  final String direction;
  final int amountCentavos;

  /// NOT NULL in Postgres. The seed stores only a per-row amount, so the mock
  /// implementation leaves this null instead of reconstructing a balance.
  final int? balanceAfterCentavos;
  final String? description;
  final String? externalReference;
  final String? serviceTransactionId;
  final DateTime? createdAt;

  bool get isCredit => direction == 'credit';

  factory WalletEntryRecord.fromRow(Map<String, dynamic> row) =>
      WalletEntryRecord(
        id: requireText(row, 'id'),
        walletAccountId: requireText(row, 'wallet_account_id'),
        type: requireText(row, 'transaction_type'),
        direction: requireText(row, 'direction'),
        amountCentavos: optionalInt(row, 'amount_centavos'),
        balanceAfterCentavos: optionalInt(row, 'balance_after_centavos'),
        description: optionalText(row, 'description'),
        externalReference: optionalText(row, 'external_reference'),
        serviceTransactionId: optionalText(row, 'service_transaction_id'),
        createdAt: optionalTime(row, 'created_at'),
      );
}

class ServiceTransactionRecord {
  const ServiceTransactionRecord({
    required this.id,
    required this.serviceType,
    required this.customerId,
    required this.providerId,
    required this.fareCentavos,
    required this.customerPaysCentavos,
    required this.providerPayoutCentavos,
    required this.platformRevenueCentavos,
    required this.status,
    this.platformFeeCentavos = 0,
    this.currency = 'PHP',
    this.paymentMethod = 'cash',
    this.rideId,
    this.rentalId,
    this.serviceRequestId,
    this.settledAt,
    this.createdAt,
  });

  final String id;

  /// `ride`, `rental` or `pasuyo`.
  final String serviceType;
  final String? rideId;
  final String? rentalId;
  final String? serviceRequestId;
  final String customerId;
  final String providerId;
  final String currency;
  final int fareCentavos;
  final int platformFeeCentavos;
  final int customerPaysCentavos;
  final int providerPayoutCentavos;
  final int platformRevenueCentavos;
  final String paymentMethod;

  /// `pending`, `completed`, `voided`, `refunded` or `failed`.
  final String status;
  final DateTime? settledAt;
  final DateTime? createdAt;

  factory ServiceTransactionRecord.fromRow(Map<String, dynamic> row) =>
      ServiceTransactionRecord(
        id: requireText(row, 'id'),
        serviceType: requireText(row, 'service_type'),
        rideId: optionalText(row, 'ride_id'),
        rentalId: optionalText(row, 'rental_id'),
        serviceRequestId: optionalText(row, 'service_request_id'),
        customerId: requireText(row, 'customer_id'),
        providerId: requireText(row, 'provider_id'),
        currency: optionalText(row, 'currency') ?? 'PHP',
        fareCentavos: optionalInt(row, 'fare_centavos'),
        platformFeeCentavos: optionalInt(row, 'platform_fee_centavos'),
        customerPaysCentavos: optionalInt(row, 'customer_pays_centavos'),
        providerPayoutCentavos: optionalInt(row, 'provider_payout_centavos'),
        platformRevenueCentavos: optionalInt(row, 'platform_revenue_centavos'),
        paymentMethod: optionalText(row, 'payment_method') ?? 'cash',
        status: optionalText(row, 'status') ?? 'pending',
        settledAt: optionalTime(row, 'settled_at'),
        createdAt: optionalTime(row, 'created_at'),
      );
}

class VerificationApplicationRecord {
  const VerificationApplicationRecord({
    required this.id,
    required this.profileId,
    required this.capabilityType,
    required this.status,
    this.submittedAt,
    this.reviewedAt,
    this.decidedAt,
    this.rejectionReason,
    this.documents = const [],
  });

  final String id;
  final String profileId;

  /// `earner`, `rider` or `vehicle_owner` — the three the check allows.
  final String capabilityType;

  /// `draft`, `submitted`, `under_review`, `approved`, `rejected`, `needs_resubmission`.
  final String status;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final DateTime? decidedAt;
  final String? rejectionReason;
  final List<VerificationDocumentRecord> documents;

  factory VerificationApplicationRecord.fromRow(Map<String, dynamic> row) =>
      VerificationApplicationRecord(
        id: requireText(row, 'id'),
        profileId: requireText(row, 'profile_id'),
        capabilityType: requireText(row, 'capability_type'),
        status: requireText(row, 'status'),
        submittedAt: optionalTime(row, 'submitted_at'),
        reviewedAt: optionalTime(row, 'reviewed_at'),
        decidedAt: optionalTime(row, 'decided_at'),
        rejectionReason: optionalText(row, 'rejection_reason'),
        documents: [
          for (final d in embeddedRows(row, 'documents'))
            VerificationDocumentRecord.fromRow(d),
        ],
      );
}

class VerificationDocumentRecord {
  const VerificationDocumentRecord({
    required this.id,
    required this.applicationId,
    required this.documentType,
    required this.status,
    this.label,
    this.documentNumber,
    this.storagePath,
    this.expiresAt,
    this.isRequired = true,
    this.rejectionReason,
  });

  final String id;
  final String applicationId;
  final String documentType;
  final String status;
  final String? label;
  final String? documentNumber;
  final String? storagePath;
  final DateTime? expiresAt;
  final bool isRequired;
  final String? rejectionReason;

  factory VerificationDocumentRecord.fromRow(Map<String, dynamic> row) =>
      VerificationDocumentRecord(
        id: requireText(row, 'id'),
        applicationId: requireText(row, 'application_id'),
        documentType: requireText(row, 'document_type'),
        status: requireText(row, 'status'),
        label: optionalText(row, 'label'),
        documentNumber: optionalText(row, 'document_number'),
        storagePath: optionalText(row, 'storage_path'),
        expiresAt: optionalDay(row, 'expires_at'),
        isRequired: optionalBool(row, 'is_required', or: true),
        rejectionReason: optionalText(row, 'rejection_reason'),
      );
}

class CashFeeRemittanceRecord {
  const CashFeeRemittanceRecord({
    required this.id,
    required this.providerId,
    required this.amountCentavos,
    required this.dueAt,
    this.serviceTransactionId,
    this.currency = 'PHP',

    /// `pending`, `remitted`, `overdue` or `waived`.
    this.status = 'pending',
    this.remittedAt,
    this.remittedToProfileId,
    this.referenceNumber,
    this.notes,
    this.createdAt,
  });

  final String id;
  final String providerId;
  final String? serviceTransactionId;
  final String currency;
  final int amountCentavos;
  final String status;
  final DateTime dueAt;
  final DateTime? remittedAt;
  final String? remittedToProfileId;
  final String? referenceNumber;
  final String? notes;
  final DateTime? createdAt;

  bool get isOutstanding => status == 'pending' || status == 'overdue';

  factory CashFeeRemittanceRecord.fromRow(Map<String, dynamic> row) {
    final dueAt = optionalTime(row, 'due_at');
    if (dueAt == null) {
      throw RepositoryFailure.invalidData(
        'Remittance ${row['id']} has no due date.',
      );
    }
    return CashFeeRemittanceRecord(
      id: requireText(row, 'id'),
      providerId: requireText(row, 'provider_id'),
      serviceTransactionId: optionalText(row, 'service_transaction_id'),
      currency: optionalText(row, 'currency') ?? 'PHP',
      amountCentavos: optionalInt(row, 'amount_centavos'),
      status: optionalText(row, 'status') ?? 'pending',
      dueAt: dueAt,
      remittedAt: optionalTime(row, 'remitted_at'),
      remittedToProfileId: optionalText(row, 'remitted_to_profile_id'),
      referenceNumber: optionalText(row, 'reference_number'),
      notes: optionalText(row, 'notes'),
      createdAt: optionalTime(row, 'created_at'),
    );
  }
}

/// One published position, from `ride_locations`.
///
/// `recorded_at` is the device's own read time, which is the only thing that
/// tells a viewer whether this is where the rider is now or where they were
/// two minutes ago, so it is never filled in from the row's insert time.
class RideLocationRecord {
  const RideLocationRecord({
    required this.id,
    required this.rideId,
    required this.latitude,
    required this.longitude,
    this.riderId,
    this.headingDegrees,
    this.speedKph,
    this.recordedAt,
  });

  final String id;
  final String rideId;
  final String? riderId;
  final double latitude;
  final double longitude;
  final double? headingDegrees;
  final double? speedKph;
  final DateTime? recordedAt;

  bool get isTrustworthy =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  factory RideLocationRecord.fromRow(Map<String, dynamic> row) {
    final latitude = optionalDouble(row, 'latitude');
    final longitude = optionalDouble(row, 'longitude');
    // A point with no coordinates is not a position, and drawing one would put
    // a rider somewhere they are not.
    if (latitude == null || longitude == null) {
      throw RepositoryFailure.invalidData(
        'Location ${row['id']} has no coordinates.',
      );
    }
    return RideLocationRecord(
      id: requireText(row, 'id'),
      rideId: requireText(row, 'ride_id'),
      riderId: optionalText(row, 'rider_id'),
      latitude: latitude,
      longitude: longitude,
      headingDegrees: optionalDouble(row, 'heading_degrees'),
      speedKph: optionalDouble(row, 'speed_kph'),
      recordedAt: optionalTime(row, 'recorded_at'),
    );
  }
}
