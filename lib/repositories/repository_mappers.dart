import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../data/models.dart';
import '../state/pasuyo_status.dart';
import '../state/rental_status.dart';
import '../state/ride_status.dart';
import 'backend_rows.dart';
import 'row_models.dart';

/// Maps backend rows to the presentation models the existing screens already
/// use. Kept in one file so the conversion rules are visible and testable.
///
/// No mapper invents money: every `*Centavos` row field lands unchanged in the
/// model's integer `fare` / `amount` / `totalFare` field.
///
/// A mapper wired to a migrated read takes the record the repository returns
/// (`backend_rows.dart`); the row-shaped mappers below it wait for their reads.

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `Aug 28, 2026 · 6:40 PM`, matching the seed's display strings.
String displayTimestamp(DateTime? value, {String fallback = '—'}) {
  if (value == null) return fallback;
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${_monthNames[local.month - 1]} ${local.day}, ${local.year} · '
      '$hour:$minute $period';
}

String displayDateOnly(DateTime? value, {String fallback = '—'}) {
  if (value == null) return fallback;
  final local = value.toLocal();
  return '${_monthNames[local.month - 1]} ${local.day}, ${local.year}';
}

/// "2 min ago", in the words the seed's own labels use.
///
/// A repository read returns a real timestamp instead of a hand-written string,
/// so the notification feed renders ages from it. [now] is a test hook.
String displayAge(DateTime? value, {DateTime? now, String fallback = '—'}) {
  if (value == null) return fallback;
  final elapsed = (now ?? DateTime.now()).difference(value);
  final age = elapsed.isNegative ? Duration.zero : elapsed;
  if (age.inMinutes < 1) return 'Just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} hr ago';
  if (age.inDays == 1) return 'Yesterday';
  if (age.inDays < 7) return '${age.inDays} days ago';
  if (age.inDays < 14) return '1 week ago';
  return displayDateOnly(value);
}

/// The fleet and catalogue glyph for a vehicle.
///
/// `vehicle_type` is free text in the database, so the category picks the
/// shape and the type only separates the van-like vehicles.
IconData iconForVehicle(String category, String vehicleType) =>
    switch (category) {
      '2-Wheel' => Icons.two_wheeler,
      '3-Wheel' => Icons.electric_rickshaw,
      'Truck' => Icons.local_shipping_outlined,
      _ => vehicleType == 'Van' || vehicleType == 'Multicab'
          ? Icons.airport_shuttle
          : Icons.directions_car,
    };

/// The glyph for a notification type token.
///
/// The seed and the `notifications` check constraint use the same ten tokens,
/// so both modes can share this mapping.
IconData iconForNotificationType(String type) => switch (type) {
      'promo' => Icons.local_offer_outlined,
      'ride' => Icons.electric_rickshaw,
      'rental' => Icons.two_wheeler,
      'pasuyo' => Icons.delivery_dining,
      'payment' || 'wallet' => Icons.account_balance_wallet_outlined,
      'verification' => Icons.badge_outlined,
      'safety' => Icons.shield_outlined,
      'rating' => Icons.star_border_rounded,
      _ => Icons.notifications_none,
    };

/// The paperwork chip, from the `document_review_status` token.
///
/// The prototype calls an approved document "Verified", so the token keeps the
/// word the list already used.
String documentStatusLabel(String token) => switch (token) {
      'approved' => 'Verified',
      'rejected' => 'Rejected',
      'expired' => 'Expired',
      _ => 'Pending',
    };

/// The glyph for a filed document.
///
/// `document_type` is a free-text label rather than an enum, and both the seed
/// and the imported rows use the same long names, so the shape is matched from
/// the words. NBI Clearance is tested first because it also reads "Clearance".
IconData iconForVehicleDocument(String label) {
  final text = label.toLowerCase();
  if (text.contains('nbi')) return Icons.fingerprint;
  if (text.contains('license')) return Icons.badge_outlined;
  if (text.contains('insurance')) return Icons.shield_outlined;
  if (text.contains('clearance')) return Icons.verified_user_outlined;
  if (text.contains('registration') || text.contains('or / cr')) {
    return Icons.description_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

String initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+'))
    ..removeWhere((part) => part.isEmpty);
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value
      .split(RegExp(r'[_\s]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

String paymentMethodLabel(String value) {
  return switch (value.toLowerCase()) {
    'cash' => 'Cash',
    'gcash' => 'GCash',
    'maya' => 'Maya',
    'card' => 'Card',
    _ => _titleCase(value),
  };
}

/// The ledger kind shown on a wallet history row.
///
/// `wallet_transactions` has no status column, so the entry's own type is what
/// the list can say next to the date; the seed's vocabulary (`topup`, `bonus`)
/// is folded into the same words.
String walletEntryTypeLabel(String token) => switch (token) {
      'top_up' || 'topup' => 'Top-up',
      'earning' || 'credit' => 'Earning',
      'payout' => 'Payout',
      'platform_fee' => 'Platform fee',
      'adjustment' => 'Adjustment',
      'refund' => 'Refund',
      'debit' => 'Payment',
      'bonus' => 'Bonus',
      _ => _titleCase(token),
    };

RideRequestItem rideRequestFromRow(RideRequestRow row) {
  final passengerName = asString(row.passenger?['full_name']) ?? 'Passenger';
  return RideRequestItem(
    id: row.id,
    passengerId: row.passengerId,
    riderId: row.riderId,
    passengerName: passengerName,
    passengerInitials: initialsFor(passengerName),
    passengerRating: asDouble(row.passenger?['rating']),
    pickupBarangay: asString(row.pickupBarangay?['name']) ?? '',
    pickupPurok: asString(row.pickupPurok?['name']) ?? '',
    pickup: row.pickupAddress,
    pickupLatitude: row.pickupLatitude,
    pickupLongitude: row.pickupLongitude,
    dropoffBarangay: asString(row.dropoffBarangay?['name']) ?? '',
    dropoffPurok: asString(row.dropoffPurok?['name']) ?? '',
    dropoff: row.dropoffAddress ?? '',
    dropoffLatitude: row.dropoffLatitude,
    dropoffLongitude: row.dropoffLongitude,
    distanceKm: row.distanceKm,
    etaMinutes: row.etaMinutes,
    fare: row.fareCentavos,
    paymentMethod: paymentMethodLabel(row.paymentMethod),
    note: row.note ?? '',
    requestedAt: displayTimestamp(row.requestedAt, fallback: 'Just now'),
    status: RideStatus.fromJson(row.status),
  );
}

RideHistoryItem rideHistoryFromRow(
  RideRecord record, {
  int rating = 0,
  String vehicleType = '',
}) {
  return RideHistoryItem(
    id: record.id,
    route: record.dropoffAddress.isEmpty
        ? record.pickupAddress
        : '${record.pickupAddress} → ${record.dropoffAddress}',
    date: displayTimestamp(
      record.completedAt ?? record.cancelledAt ?? record.requestedAt,
    ),
    fare: record.fareCentavos,
    status: record.status.label,
    vehicleType: vehicleType,
    driverName: record.riderName ?? '—',
    rating: rating,
    completedAt: record.completedAt,
  );
}

RiderTripItem riderTripFromRow(
  RideRequestRow row, {
  int rating = 0,
}) {
  final passengerName = asString(row.passenger?['full_name']) ?? 'Passenger';
  return RiderTripItem(
    id: row.id,
    passengerName: passengerName,
    route: '${row.pickupAddress} → ${row.dropoffAddress ?? 'Destination'}',
    date: displayTimestamp(
      row.completedAt ?? row.cancelledAt ?? row.requestedAt,
    ),
    fare: row.fareCentavos,
    distanceKm: row.distanceKm,
    status: switch (row.status) {
      'completed' => 'Completed',
      'cancelled' => 'Cancelled',
      _ => _titleCase(row.status),
    },
    rating: rating,
    completedAt: row.completedAt,
  );
}

IconData vehicleIcon(String type, String category) {
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

RentalVehicle rentalListingFromRow(VehicleRow row) {
  final ownerName = row.ownerName ?? 'Vehicle Owner';
  final description = [
    if (row.make != null) row.make!,
    if (row.model != null) row.model!,
    if (row.modelYear != null) '${row.modelYear}',
    if (row.color != null) row.color!,
  ].join(' · ');
  return RentalVehicle(
    id: row.id,
    name: row.name,
    type: row.vehicleType,
    icon: vehicleIcon(row.vehicleType, row.category),
    location: asString(row.serviceArea?['name']) ?? '',
    availability: row.status == 'active' ? 'Available today' : 'Unavailable',
    pricePerDay: row.pricePerDayCentavos,
    rating: row.rating,
    ownerName: ownerName,
    ownerInitials: initialsFor(ownerName),
    description: description,
    depositFee: 0,
  );
}

String ownedVehicleStatus(String backendStatus) =>
    backendStatus == 'active' ? 'Listed' : 'Maintenance';

OwnedVehicle ownedVehicleFromRow(VehicleRow row) => OwnedVehicle(
      id: row.id,
      name: row.name,
      type: row.vehicleType,
      category: row.category,
      plate: row.plateNumber,
      pricePerDay: row.pricePerDayCentavos,
      status: ownedVehicleStatus(row.status),
      rating: row.rating,
      totalRentals: row.totalRentals,
    );

VehicleDocumentItem vehicleDocumentFromRow(VehicleDocumentRow row) {
  final title = _titleCase(row.documentType);
  return VehicleDocumentItem(
    id: row.id,
    title: title,
    number: row.documentNumber ?? (row.storagePath == null ? '—' : 'Uploaded'),
    status: switch (row.status) {
      'approved' => 'Verified',
      'rejected' => 'Rejected',
      'expired' => 'Expired',
      _ => 'Pending',
    },
    expiry: displayDateOnly(row.expiresAt),
    icon: switch (row.documentType.toLowerCase()) {
      'license' || 'drivers_license' => 'license',
      'orcr' || 'or_cr' => 'orcr',
      'insurance' => 'insurance',
      'clearance' => 'clearance',
      'nbi' => 'nbi',
      _ => 'file',
    },
  );
}

RentalHistoryItem rentalHistoryFromRow(RentalBookingRow row) =>
    RentalHistoryItem(
      id: row.id,
      vehicleName: row.vehicleName ?? 'Vehicle',
      ownerName: row.ownerName ?? 'Vehicle Owner',
      startDate: displayDateOnly(row.startAt),
      endDate: displayDateOnly(row.endAt),
      totalFare: row.totalFareCentavos,
      status: switch (row.status) {
        'completed' => 'Completed',
        'cancelled' => 'Cancelled',
        'declined' => 'Declined',
        'active' => 'Active',
        _ => _titleCase(row.status),
      },
      startAt: row.startAt,
      endAt: row.endAt,
    );

OwnerBookingRequest ownerBookingFromRow(RentalBookingRow row) {
  final renterName = row.renterName ?? 'Renter';
  final start = row.startAt;
  final end = row.endAt;
  return OwnerBookingRequest(
    id: row.id,
    renterId: row.renterId,
    ownerId: row.ownerId,
    vehicleId: row.vehicleId,
    renterName: renterName,
    renterInitials: initialsFor(renterName),
    vehicleName: row.vehicleName ?? 'Vehicle',
    startDate: displayDateOnly(start),
    endDate: displayDateOnly(end),
    startTime:
        start == null ? null : displayTimestamp(start).split('·').last.trim(),
    endTime: end == null ? null : displayTimestamp(end).split('·').last.trim(),
    durationHours: row.durationHours,
    totalFare: row.totalFareCentavos,
    paymentMethod: paymentMethodLabel(row.paymentMethod),
    pickupLocation: row.pickupLocation,
    currentLocation: row.currentLocation,
    status: RentalStatus.fromJson(row.status),
    startAt: start,
    endAt: end,
  );
}

RentalBooking rentalBookingFromRow(RentalBookingRow row) {
  final start = row.startAt ?? DateTime.now();
  final end = row.endAt ?? start;
  final vehicleType = row.vehicleType ?? 'Vehicle';
  final category = OwnedVehicle.categoryForType(vehicleType);
  final ownerName = row.ownerName ?? 'Vehicle Owner';
  final days = end.difference(start).inDays.abs();
  return RentalBooking(
    id: row.id,
    vehicleId: row.vehicleId,
    vehicleName: row.vehicleName ?? 'Vehicle',
    vehicleType: vehicleType,
    icon: vehicleIcon(vehicleType, category),
    ownerName: ownerName,
    ownerInitials: initialsFor(ownerName),
    pickupLabel: displayDateOnly(start),
    returnLabel: displayDateOnly(end),
    pickupDate: start,
    returnDate: end,
    days: days == 0 ? 1 : days,
    totalFare: row.totalFareCentavos,
    status: RentalStatus.fromJson(row.status),
    requestedAt: start,
  );
}

PasuyoCategory pasuyoCategoryFromBackend(String value) => switch (value) {
      'groceries' => PasuyoCategory.groceries,
      'food_delivery' || 'food' => PasuyoCategory.foodDelivery,
      'pharmacy' => PasuyoCategory.pharmacy,
      'parcel' => PasuyoCategory.parcel,
      'laundry' => PasuyoCategory.laundry,
      _ => PasuyoCategory.other,
    };

PasuyoTask pasuyoTaskFromRow(ServiceRequestRow row) => PasuyoTask(
      id: row.id,
      customerId: row.customerId,
      helperId: row.providerId,
      category: pasuyoCategoryFromBackend(row.category),
      title: row.title,
      items: [for (final item in row.items) item.name],
      pickupBarangay: asString(row.pickupBarangay?['name']) ?? '',
      pickupPurok: asString(row.pickupPurok?['name']) ?? '',
      pickup: row.pickupAddress,
      dropoffBarangay: asString(row.dropoffBarangay?['name']) ?? '',
      dropoffPurok: asString(row.dropoffPurok?['name']) ?? '',
      dropoff: row.dropoffAddress ?? '',
      budget: row.budgetCentavos ?? row.quotedFeeCentavos,
      note: row.description ?? '',
      requestedAt: displayTimestamp(row.requestedAt, fallback: 'Just now'),
      requestedAtIso: row.requestedAt,
      status: PasuyoStatus.fromJson(row.status),
    );

WalletTransaction walletTransactionFromRow(WalletTransactionRow row) {
  final type = switch (row.transactionType) {
    'top_up' => 'topup',
    'earning' => 'credit',
    'payout' => 'payout',
    'refund' => 'credit',
    _ => row.direction == 'credit' ? 'credit' : 'debit',
  };
  return WalletTransaction(
    id: row.id,
    type: type,
    title: row.description ?? _titleCase(row.transactionType),
    amount: row.amountCentavos,
    date: displayTimestamp(row.createdAt),
    status: 'Completed',
    createdAt: row.createdAt,
    kind: row.transactionType,
  );
}

NotificationItem notificationItemFromRow(NotificationRow row) =>
    NotificationItem(
      id: row.id,
      type: row.notificationType,
      title: row.title,
      body: row.body,
      time: displayTimestamp(row.createdAt, fallback: 'Just now'),
      read: row.isRead,
    );

CapabilityType capabilityTypeFromBackendRole(String role) => switch (role) {
      'earner' => CapabilityType.earner,
      'rider' => CapabilityType.rider,
      'vehicle_owner' => CapabilityType.vehicleOwner,
      _ => CapabilityType.passenger,
    };

String backendRoleForCapability(CapabilityType capability) =>
    switch (capability) {
      CapabilityType.passenger => 'passenger',
      CapabilityType.earner => 'earner',
      CapabilityType.rider => 'rider',
      CapabilityType.vehicleOwner => 'vehicle_owner',
    };

VerificationStatus verificationStatusFromBackend(String status) =>
    switch (status) {
      'submitted' => VerificationStatus.submitted,
      'under_review' => VerificationStatus.underReview,
      'approved' => VerificationStatus.approved,
      'rejected' => VerificationStatus.rejected,
      'needs_resubmission' => VerificationStatus.needsResubmission,
      _ => VerificationStatus.draft,
    };

VerificationApplication verificationApplicationFromRow(
  VerificationApplicationRow row,
) {
  final capability = capabilityTypeFromBackendRole(row.capabilityType);
  return VerificationApplication(
    id: row.id,
    accountId: row.profileId,
    capabilityType: capability,
    status: verificationStatusFromBackend(row.status),
    submittedAt: row.submittedAt,
    reviewedAt: row.reviewedAt,
    reviewerNote: row.rejectionReason,
    documents: [
      for (final document in row.documents)
        VerificationDocumentItem(
          id: document.id,
          capabilityType: capability,
          label: document.label ?? _titleCase(document.documentType),
          hint: document.rejectionReason ?? '',
          required: document.isRequired,
          uploaded: document.isUploaded,
          fileName: document.storagePath,
        ),
    ],
  );
}
