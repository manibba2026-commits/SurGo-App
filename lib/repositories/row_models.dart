/// Backend row models.
///
/// These types mirror the Supabase schema one-to-one. They deliberately do not
/// import `package:flutter` or the presentation models in `lib/data`: a
/// repository maps a row to the model a screen already knows, so a column
/// rename never leaks into the widget tree.
///
/// Every money field is named `*Centavos` and is an integer. The UI never sees
/// a double for money.
///
/// These models are a parallel candidate for a later presentation-mapping pass;
/// the repository reads currently use the records in `backend_rows.dart`.
library;

int asInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double asDouble(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

String? asString(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value;
  return null;
}

DateTime? asDate(Object? value) {
  if (value is DateTime) return value;
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

Map<String, dynamic>? asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries) '${entry.key}': entry.value,
    };
  }
  return null;
}

List<Map<String, dynamic>> asRows(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (asMap(item) != null) asMap(item)!,
  ];
}

class ProfileRow {
  const ProfileRow({
    required this.id,
    required this.fullName,
    this.firstName,
    this.email,
    this.phone,
    this.avatarPath,
    this.accountStatus = 'active',
    this.rating = 0,
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

  bool get isActive => accountStatus == 'active';

  factory ProfileRow.fromMap(Map<String, dynamic> map) => ProfileRow(
        id: '${map['id']}',
        fullName: asString(map['full_name']) ?? '',
        firstName: asString(map['first_name']),
        email: asString(map['email']),
        phone: asString(map['phone']),
        avatarPath: asString(map['avatar_path']),
        accountStatus: asString(map['account_status']) ?? 'active',
        rating: asDouble(map['rating']),
        totalRides: asInt(map['total_rides']),
        lastSeenAt: asDate(map['last_seen_at']),
        createdAt: asDate(map['created_at']),
      );
}

class UserRoleRow {
  const UserRoleRow({
    required this.id,
    required this.profileId,
    required this.role,
    required this.status,
    this.approvedAt,
  });

  final String id;
  final String profileId;
  final String role;
  final String status;
  final DateTime? approvedAt;

  bool get isApproved => status == 'approved';

  factory UserRoleRow.fromMap(Map<String, dynamic> map) => UserRoleRow(
        id: '${map['id']}',
        profileId: '${map['profile_id']}',
        role: '${map['role']}',
        status: '${map['status']}',
        approvedAt: asDate(map['approved_at']),
      );
}

class ProviderProfileRow {
  const ProviderProfileRow({
    required this.id,
    required this.profileId,
    required this.providerType,
    this.serviceAreaId,
    this.displayName,
    this.bio,
    this.capabilities = const [],
    this.isAvailable = false,
    this.rating = 0,
    this.totalTrips = 0,
  });

  final String id;
  final String profileId;
  final String providerType;
  final String? serviceAreaId;
  final String? displayName;
  final String? bio;
  final List<String> capabilities;
  final bool isAvailable;
  final double rating;
  final int totalTrips;

  factory ProviderProfileRow.fromMap(Map<String, dynamic> map) =>
      ProviderProfileRow(
        id: '${map['id']}',
        profileId: '${map['profile_id']}',
        providerType: '${map['provider_type']}',
        serviceAreaId: asString(map['service_area_id']),
        displayName: asString(map['display_name']),
        bio: asString(map['bio']),
        capabilities: [
          for (final value
              in (map['capabilities'] is List ? map['capabilities'] : const []))
            '$value',
        ],
        isAvailable: map['is_available'] == true,
        rating: asDouble(map['rating']),
        totalTrips: asInt(map['total_trips']),
      );
}

class VehicleRow {
  const VehicleRow({
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
    this.rating = 0,
    this.totalRentals = 0,
    this.owner,
    this.serviceArea,
  });

  final String id;
  final String ownerProfileId;
  final String? serviceAreaId;
  final String name;
  final String vehicleType;
  final String category;
  final String? make;
  final String? model;
  final int? modelYear;
  final String? color;
  final String plateNumber;
  final int pricePerDayCentavos;
  final String status;
  final double rating;
  final int totalRentals;

  /// Optional embedded `profiles` row.
  final Map<String, dynamic>? owner;

  /// Optional embedded `service_areas` row.
  final Map<String, dynamic>? serviceArea;

  String? get ownerName => asString(owner?['full_name']);

  factory VehicleRow.fromMap(Map<String, dynamic> map) => VehicleRow(
        id: '${map['id']}',
        ownerProfileId: '${map['owner_profile_id']}',
        serviceAreaId: asString(map['service_area_id']),
        name: asString(map['name']) ?? '',
        vehicleType: asString(map['vehicle_type']) ?? '',
        category: asString(map['category']) ?? '4-Wheel',
        make: asString(map['make']),
        model: asString(map['model']),
        modelYear: map['model_year'] == null ? null : asInt(map['model_year']),
        color: asString(map['color']),
        plateNumber: asString(map['plate_number']) ?? '',
        pricePerDayCentavos: asInt(map['price_per_day_centavos']),
        status: asString(map['status']) ?? 'pending_verification',
        rating: asDouble(map['rating']),
        totalRentals: asInt(map['total_rentals']),
        owner: asMap(map['owner']),
        serviceArea: asMap(map['service_area']),
      );
}

class VehicleDocumentRow {
  const VehicleDocumentRow({
    required this.id,
    required this.vehicleId,
    required this.documentType,
    this.documentNumber,
    this.storagePath,
    this.issuedAt,
    this.expiresAt,
    this.status = 'pending',
    this.rejectionReason,
  });

  final String id;
  final String vehicleId;
  final String documentType;
  final String? documentNumber;
  final String? storagePath;
  final DateTime? issuedAt;
  final DateTime? expiresAt;
  final String status;
  final String? rejectionReason;

  factory VehicleDocumentRow.fromMap(Map<String, dynamic> map) =>
      VehicleDocumentRow(
        id: '${map['id']}',
        vehicleId: '${map['vehicle_id']}',
        documentType: '${map['document_type']}',
        documentNumber: asString(map['document_number']),
        storagePath: asString(map['storage_path']),
        issuedAt: asDate(map['issued_at']),
        expiresAt: asDate(map['expires_at']),
        status: asString(map['status']) ?? 'pending',
        rejectionReason: asString(map['rejection_reason']),
      );
}

class RideRequestRow {
  const RideRequestRow({
    required this.id,
    required this.passengerId,
    this.riderId,
    required this.serviceAreaId,
    required this.status,
    required this.pickupAddress,
    this.pickupBarangayId,
    this.pickupPurokId,
    this.pickupLatitude,
    this.pickupLongitude,
    this.dropoffAddress,
    this.dropoffBarangayId,
    this.dropoffPurokId,
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
    this.passenger,
    this.rider,
    this.pickupBarangay,
    this.pickupPurok,
    this.dropoffBarangay,
    this.dropoffPurok,
  });

  final String id;
  final String passengerId;
  final String? riderId;
  final String serviceAreaId;
  final String status;
  final String pickupAddress;
  final String? pickupBarangayId;
  final String? pickupPurokId;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final String? dropoffAddress;
  final String? dropoffBarangayId;
  final String? dropoffPurokId;
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

  /// Optional embedded `profiles` row for the passenger.
  final Map<String, dynamic>? passenger;

  /// Optional embedded `profiles` row for the assigned rider.
  final Map<String, dynamic>? rider;

  /// Optional embedded `barangays` / `puroks` rows.
  final Map<String, dynamic>? pickupBarangay;
  final Map<String, dynamic>? pickupPurok;
  final Map<String, dynamic>? dropoffBarangay;
  final Map<String, dynamic>? dropoffPurok;

  factory RideRequestRow.fromMap(Map<String, dynamic> map) => RideRequestRow(
        id: '${map['id']}',
        passengerId: '${map['passenger_id']}',
        riderId: asString(map['rider_id']),
        serviceAreaId: '${map['service_area_id']}',
        status: asString(map['status']) ?? 'searching',
        pickupAddress: asString(map['pickup_address']) ?? '',
        pickupBarangayId: asString(map['pickup_barangay_id']),
        pickupPurokId: asString(map['pickup_purok_id']),
        pickupLatitude: map['pickup_latitude'] == null
            ? null
            : asDouble(map['pickup_latitude']),
        pickupLongitude: map['pickup_longitude'] == null
            ? null
            : asDouble(map['pickup_longitude']),
        dropoffAddress: asString(map['dropoff_address']),
        dropoffBarangayId: asString(map['dropoff_barangay_id']),
        dropoffPurokId: asString(map['dropoff_purok_id']),
        dropoffLatitude: map['dropoff_latitude'] == null
            ? null
            : asDouble(map['dropoff_latitude']),
        dropoffLongitude: map['dropoff_longitude'] == null
            ? null
            : asDouble(map['dropoff_longitude']),
        distanceKm: asDouble(map['distance_km']),
        etaMinutes: asInt(map['eta_minutes']),
        fareCentavos: asInt(map['fare_centavos']),
        platformFeeCentavos: asInt(map['platform_fee_centavos']),
        paymentMethod: asString(map['payment_method']) ?? 'cash',
        note: asString(map['note']),
        requestedAt: asDate(map['requested_at']),
        acceptedAt: asDate(map['accepted_at']),
        startedAt: asDate(map['started_at']),
        completedAt: asDate(map['completed_at']),
        cancelledAt: asDate(map['cancelled_at']),
        cancellationReason: asString(map['cancellation_reason']),
        passenger: asMap(map['passenger']),
        rider: asMap(map['rider']),
        pickupBarangay: asMap(map['pickup_barangay']),
        pickupPurok: asMap(map['pickup_purok']),
        dropoffBarangay: asMap(map['dropoff_barangay']),
        dropoffPurok: asMap(map['dropoff_purok']),
      );
}

class RentalBookingRow {
  const RentalBookingRow({
    required this.id,
    required this.renterId,
    required this.ownerId,
    required this.vehicleId,
    required this.serviceAreaId,
    required this.status,
    required this.startAt,
    required this.endAt,
    this.durationHours,
    this.pickupLocation,
    this.currentLocation,
    this.totalFareCentavos = 0,
    this.platformFeeCentavos = 0,
    this.paymentMethod = 'cash',
    this.acceptedAt,
    this.startedAt,
    this.returnedAt,
    this.completedAt,
    this.declinedAt,
    this.cancelledAt,
    this.renter,
    this.owner,
    this.vehicle,
  });

  final String id;
  final String renterId;
  final String ownerId;
  final String vehicleId;
  final String serviceAreaId;
  final String status;
  final DateTime? startAt;
  final DateTime? endAt;
  final int? durationHours;
  final String? pickupLocation;
  final String? currentLocation;
  final int totalFareCentavos;
  final int platformFeeCentavos;
  final String paymentMethod;
  final DateTime? acceptedAt;
  final DateTime? startedAt;
  final DateTime? returnedAt;
  final DateTime? completedAt;
  final DateTime? declinedAt;
  final DateTime? cancelledAt;

  /// Optional embedded `profiles` rows.
  final Map<String, dynamic>? renter;
  final Map<String, dynamic>? owner;

  /// Optional embedded `vehicles` row.
  final Map<String, dynamic>? vehicle;

  String? get vehicleName => asString(vehicle?['name']);
  String? get vehicleType => asString(vehicle?['vehicle_type']);
  String? get renterName => asString(renter?['full_name']);
  String? get ownerName => asString(owner?['full_name']);

  factory RentalBookingRow.fromMap(Map<String, dynamic> map) =>
      RentalBookingRow(
        id: '${map['id']}',
        renterId: '${map['renter_id']}',
        ownerId: '${map['owner_id']}',
        vehicleId: '${map['vehicle_id']}',
        serviceAreaId: '${map['service_area_id']}',
        status: asString(map['status']) ?? 'requested',
        startAt: asDate(map['start_at']),
        endAt: asDate(map['end_at']),
        durationHours:
            map['duration_hours'] == null ? null : asInt(map['duration_hours']),
        pickupLocation: asString(map['pickup_location']),
        currentLocation: asString(map['current_location']),
        totalFareCentavos: asInt(map['total_fare_centavos']),
        platformFeeCentavos: asInt(map['platform_fee_centavos']),
        paymentMethod: asString(map['payment_method']) ?? 'cash',
        acceptedAt: asDate(map['accepted_at']),
        startedAt: asDate(map['started_at']),
        returnedAt: asDate(map['returned_at']),
        completedAt: asDate(map['completed_at']),
        declinedAt: asDate(map['declined_at']),
        cancelledAt: asDate(map['cancelled_at']),
        renter: asMap(map['renter']),
        owner: asMap(map['owner']),
        vehicle: asMap(map['vehicle']),
      );
}

class ServiceRequestItemRow {
  const ServiceRequestItemRow({
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

  factory ServiceRequestItemRow.fromMap(Map<String, dynamic> map) =>
      ServiceRequestItemRow(
        id: '${map['id']}',
        serviceRequestId: '${map['service_request_id']}',
        name: asString(map['name']) ?? '',
        quantity: asDouble(map['quantity'], fallback: 1),
        unit: asString(map['unit']),
        estimatedUnitPriceCentavos: map['estimated_unit_price_centavos'] == null
            ? null
            : asInt(map['estimated_unit_price_centavos']),
        actualUnitPriceCentavos: map['actual_unit_price_centavos'] == null
            ? null
            : asInt(map['actual_unit_price_centavos']),
        notes: asString(map['notes']),
      );
}

class ServiceRequestRow {
  const ServiceRequestRow({
    required this.id,
    required this.customerId,
    this.providerId,
    required this.serviceAreaId,
    required this.category,
    required this.status,
    required this.title,
    this.description,
    required this.pickupAddress,
    this.pickupBarangayId,
    this.pickupPurokId,
    this.pickupLatitude,
    this.pickupLongitude,
    this.dropoffAddress,
    this.dropoffBarangayId,
    this.dropoffPurokId,
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
    this.pickupBarangay,
    this.pickupPurok,
    this.dropoffBarangay,
    this.dropoffPurok,
    this.customer,
    this.provider,
    this.items = const [],
  });

  final String id;
  final String customerId;
  final String? providerId;
  final String serviceAreaId;
  final String category;
  final String status;
  final String title;
  final String? description;
  final String pickupAddress;
  final String? pickupBarangayId;
  final String? pickupPurokId;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final String? dropoffAddress;
  final String? dropoffBarangayId;
  final String? dropoffPurokId;
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

  /// Optional embedded rows.
  final Map<String, dynamic>? pickupBarangay;
  final Map<String, dynamic>? pickupPurok;
  final Map<String, dynamic>? dropoffBarangay;
  final Map<String, dynamic>? dropoffPurok;
  final Map<String, dynamic>? customer;
  final Map<String, dynamic>? provider;

  /// Loaded separately from `service_request_items` and attached by the
  /// repository. Empty for list queries that do not need line items.
  final List<ServiceRequestItemRow> items;

  ServiceRequestRow withItems(List<ServiceRequestItemRow> value) =>
      ServiceRequestRow(
        id: id,
        customerId: customerId,
        providerId: providerId,
        serviceAreaId: serviceAreaId,
        category: category,
        status: status,
        title: title,
        description: description,
        pickupAddress: pickupAddress,
        pickupBarangayId: pickupBarangayId,
        pickupPurokId: pickupPurokId,
        pickupLatitude: pickupLatitude,
        pickupLongitude: pickupLongitude,
        dropoffAddress: dropoffAddress,
        dropoffBarangayId: dropoffBarangayId,
        dropoffPurokId: dropoffPurokId,
        dropoffLatitude: dropoffLatitude,
        dropoffLongitude: dropoffLongitude,
        budgetCentavos: budgetCentavos,
        quotedFeeCentavos: quotedFeeCentavos,
        platformFeeCentavos: platformFeeCentavos,
        paymentMethod: paymentMethod,
        requestedAt: requestedAt,
        acceptedAt: acceptedAt,
        pickedUpAt: pickedUpAt,
        deliveredAt: deliveredAt,
        cancelledAt: cancelledAt,
        pickupBarangay: pickupBarangay,
        pickupPurok: pickupPurok,
        dropoffBarangay: dropoffBarangay,
        dropoffPurok: dropoffPurok,
        customer: customer,
        provider: provider,
        items: value,
      );

  factory ServiceRequestRow.fromMap(Map<String, dynamic> map) =>
      ServiceRequestRow(
        id: '${map['id']}',
        customerId: '${map['customer_id']}',
        providerId: asString(map['provider_id']),
        serviceAreaId: '${map['service_area_id']}',
        category: asString(map['category']) ?? 'other',
        status: asString(map['status']) ?? 'available',
        title: asString(map['title']) ?? '',
        description: asString(map['description']),
        pickupAddress: asString(map['pickup_address']) ?? '',
        pickupBarangayId: asString(map['pickup_barangay_id']),
        pickupPurokId: asString(map['pickup_purok_id']),
        pickupLatitude: map['pickup_latitude'] == null
            ? null
            : asDouble(map['pickup_latitude']),
        pickupLongitude: map['pickup_longitude'] == null
            ? null
            : asDouble(map['pickup_longitude']),
        dropoffAddress: asString(map['dropoff_address']),
        dropoffBarangayId: asString(map['dropoff_barangay_id']),
        dropoffPurokId: asString(map['dropoff_purok_id']),
        dropoffLatitude: map['dropoff_latitude'] == null
            ? null
            : asDouble(map['dropoff_latitude']),
        dropoffLongitude: map['dropoff_longitude'] == null
            ? null
            : asDouble(map['dropoff_longitude']),
        budgetCentavos: map['budget_centavos'] == null
            ? null
            : asInt(map['budget_centavos']),
        quotedFeeCentavos: asInt(map['quoted_fee_centavos']),
        platformFeeCentavos: asInt(map['platform_fee_centavos']),
        paymentMethod: asString(map['payment_method']) ?? 'cash',
        requestedAt: asDate(map['requested_at']),
        acceptedAt: asDate(map['accepted_at']),
        pickedUpAt: asDate(map['picked_up_at']),
        deliveredAt: asDate(map['delivered_at']),
        cancelledAt: asDate(map['cancelled_at']),
        pickupBarangay: asMap(map['pickup_barangay']),
        pickupPurok: asMap(map['pickup_purok']),
        dropoffBarangay: asMap(map['dropoff_barangay']),
        dropoffPurok: asMap(map['dropoff_purok']),
        customer: asMap(map['customer']),
        provider: asMap(map['provider']),
        items: [
          for (final item in asRows(map['items']))
            ServiceRequestItemRow.fromMap(item),
        ],
      );
}

class WalletAccountRow {
  const WalletAccountRow({
    required this.id,
    this.profileId,
    required this.accountType,
    this.currency = 'PHP',
    this.balanceCentavos = 0,
    this.isActive = true,
  });

  final String id;
  final String? profileId;
  final String accountType;
  final String currency;
  final int balanceCentavos;
  final bool isActive;

  factory WalletAccountRow.fromMap(Map<String, dynamic> map) =>
      WalletAccountRow(
        id: '${map['id']}',
        profileId: asString(map['profile_id']),
        accountType: asString(map['account_type']) ?? 'passenger',
        currency: asString(map['currency']) ?? 'PHP',
        balanceCentavos: asInt(map['balance_centavos']),
        isActive: map['is_active'] != false,
      );
}

class WalletTransactionRow {
  const WalletTransactionRow({
    required this.id,
    required this.walletAccountId,
    required this.transactionType,
    required this.direction,
    required this.amountCentavos,
    required this.balanceAfterCentavos,
    this.serviceTransactionId,
    this.externalReference,
    this.description,
    this.createdAt,
  });

  final String id;
  final String walletAccountId;
  final String transactionType;
  final String direction;
  final int amountCentavos;
  final int balanceAfterCentavos;
  final String? serviceTransactionId;
  final String? externalReference;
  final String? description;
  final DateTime? createdAt;

  factory WalletTransactionRow.fromMap(Map<String, dynamic> map) =>
      WalletTransactionRow(
        id: '${map['id']}',
        walletAccountId: '${map['wallet_account_id']}',
        transactionType: asString(map['transaction_type']) ?? 'adjustment',
        direction: asString(map['direction']) ?? 'credit',
        amountCentavos: asInt(map['amount_centavos']),
        balanceAfterCentavos: asInt(map['balance_after_centavos']),
        serviceTransactionId: asString(map['service_transaction_id']),
        externalReference: asString(map['external_reference']),
        description: asString(map['description']),
        createdAt: asDate(map['created_at']),
      );
}

class NotificationRow {
  const NotificationRow({
    required this.id,
    required this.profileId,
    required this.notificationType,
    required this.title,
    required this.body,
    this.data = const {},
    this.readAt,
    this.createdAt,
  });

  final String id;
  final String profileId;
  final String notificationType;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final DateTime? createdAt;

  bool get isRead => readAt != null;

  factory NotificationRow.fromMap(Map<String, dynamic> map) => NotificationRow(
        id: '${map['id']}',
        profileId: '${map['profile_id']}',
        notificationType: asString(map['notification_type']) ?? 'system',
        title: asString(map['title']) ?? '',
        body: asString(map['body']) ?? '',
        data: asMap(map['data']) ?? const {},
        readAt: asDate(map['read_at']),
        createdAt: asDate(map['created_at']),
      );
}

class VerificationDocumentRow {
  const VerificationDocumentRow({
    required this.id,
    required this.applicationId,
    required this.documentType,
    this.label,
    this.documentNumber,
    this.storagePath,
    this.expiresAt,
    this.isRequired = true,
    this.status = 'pending',
    this.rejectionReason,
  });

  final String id;
  final String applicationId;
  final String documentType;
  final String? label;
  final String? documentNumber;
  final String? storagePath;
  final DateTime? expiresAt;
  final bool isRequired;
  final String status;
  final String? rejectionReason;

  bool get isUploaded => storagePath != null && storagePath!.isNotEmpty;

  factory VerificationDocumentRow.fromMap(Map<String, dynamic> map) =>
      VerificationDocumentRow(
        id: '${map['id']}',
        applicationId: '${map['application_id']}',
        documentType: '${map['document_type']}',
        label: asString(map['label']),
        documentNumber: asString(map['document_number']),
        storagePath: asString(map['storage_path']),
        expiresAt: asDate(map['expires_at']),
        isRequired: map['is_required'] != false,
        status: asString(map['status']) ?? 'pending',
        rejectionReason: asString(map['rejection_reason']),
      );
}

class VerificationApplicationRow {
  const VerificationApplicationRow({
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
  final String capabilityType;
  final String status;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final DateTime? decidedAt;
  final String? rejectionReason;
  final List<VerificationDocumentRow> documents;

  factory VerificationApplicationRow.fromMap(Map<String, dynamic> map) =>
      VerificationApplicationRow(
        id: '${map['id']}',
        profileId: '${map['profile_id']}',
        capabilityType: '${map['capability_type']}',
        status: asString(map['status']) ?? 'draft',
        submittedAt: asDate(map['submitted_at']),
        reviewedAt: asDate(map['reviewed_at']),
        decidedAt: asDate(map['decided_at']),
        rejectionReason: asString(map['rejection_reason']),
        documents: [
          for (final row in asRows(map['documents']))
            VerificationDocumentRow.fromMap(row),
        ],
      );
}
