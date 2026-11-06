import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart' show PasuyoCategory;
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/state/pasuyo_status.dart';
import 'package:surgo/state/rental_status.dart';
import 'package:surgo/state/ride_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Row parsing is where a schema change is caught, so these tests pin the
/// vocabulary the deployed enums actually use and the failures raised when a
/// row does not match.

void main() {
  group('column helpers', () {
    test('requireText returns a populated column and names it when absent', () {
      expect(requireText({'id': 'r1'}, 'id'), 'r1');
      expect(
        () => requireText({'_table': 'rides', 'id': ''}, 'id'),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.kind == RepositoryFailureKind.invalidData &&
            error.message.contains('rides is missing id.'))),
      );
    });

    test('optionalText trims and treats blank strings as absent', () {
      expect(optionalText({'note': '  '}, 'note'), isNull);
      expect(optionalText({'note': ' bring cash '}, 'note'), ' bring cash ');
    });

    test('numeric and boolean readers accept the shapes PostgREST sends', () {
      expect(optionalInt({'x': 4500000}, 'x'), 4500000);
      expect(optionalInt({'x': 12.5}, 'x'), 12);
      expect(optionalInt({'x': '900'}, 'x'), 900);
      expect(optionalInt({}, 'x', or: 7), 7);
      expect(optionalDouble({'x': '4.8'}, 'x'), 4.8);
      expect(optionalBool({'x': 't'}, 'x'), isTrue);
      expect(optionalBool({'x': 1}, 'x'), isTrue);
      expect(optionalBool({}, 'x', or: true), isTrue);
    });

    test('optionalTime parses ISO timestamps and rejects junk', () {
      expect(optionalTime({'at': '2026-11-06T03:15:00.000Z'}, 'at'),
          DateTime.utc(2026, 11, 6, 3, 15));
      expect(optionalTime({'at': 'not a date'}, 'at'), isNull);
      expect(optionalTime({'at': null}, 'at'), isNull);
    });

    test('embedded readers accept a single object or a list', () {
      expect(
          embeddedRows({
            'items': {'id': 'a'}
          }, 'items'),
          [
            {'id': 'a'}
          ]);
      expect(
          embeddedRows({
            'items': [
              {'id': 'a'},
              'skip'
            ]
          }, 'items'),
          [
            {'id': 'a'}
          ]);
      expect(embeddedRows({}, 'items'), isEmpty);
      expect(
          embeddedRow({
            'owner': {'full_name': 'Ana'}
          }, 'owner'),
          {'full_name': 'Ana'});
      expect(embeddedRow({'owner': null}, 'owner'), isNull);
    });
  });

  group('enum tokens', () {
    test('every ride status token in the database enum is recognised', () {
      expect(rideStatusFromDb('searching'), RideStatus.searching);
      expect(rideStatusFromDb('awaiting_acceptance'),
          RideStatus.awaitingAcceptance);
      expect(rideStatusFromDb('heading_to_pickup'), RideStatus.headingToPickup);
      expect(rideStatusFromDb('in_progress'), RideStatus.inProgress);
      expect(rideStatusFromDb('completed'), RideStatus.completed);
    });

    test('an unknown status fails instead of defaulting', () {
      // A silently defaulted status would render the wrong action button, so
      // the row must be rejected loudly.
      expect(
        () => rideStatusFromDb('in_rent'),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.kind == RepositoryFailureKind.invalidData &&
            error.message.contains('in_rent'))),
      );
      expect(() => rentalStatusFromDb('paused'),
          throwsA(isA<RepositoryFailure>()));
      expect(() => pasuyoStatusFromDb('returned'),
          throwsA(isA<RepositoryFailure>()));
    });

    test('rental and errand vocabularies cover their enums', () {
      expect(rentalStatusFromDb('awaiting_owner'), RentalStatus.awaitingOwner);
      expect(rentalStatusFromDb('returned'), RentalStatus.returned);
      expect(rentalStatusFromDb('declined'), RentalStatus.declined);
      expect(pasuyoStatusFromDb('going_to_pickup'), PasuyoStatus.goingToPickup);
      expect(pasuyoStatusFromDb('at_customer'), PasuyoStatus.atCustomer);
    });

    test('the food category is read under both spellings and written as one',
        () {
      expect(
          pasuyoCategoryFromDb('food_delivery'), PasuyoCategory.foodDelivery);
      expect(pasuyoCategoryFromDb('food'), PasuyoCategory.foodDelivery);
      expect(pasuyoCategoryTokenToDb(PasuyoCategory.foodDelivery),
          'food_delivery');
      expect(pasuyoCategoryTokenToDb(PasuyoCategory.groceries), 'groceries');
      expect(() => pasuyoCategoryFromDb('takeout'),
          throwsA(isA<RepositoryFailure>()));
    });
  });

  group('records', () {
    test('ProfileRecord applies schema defaults', () {
      final record = ProfileRecord.fromRow({
        'id': 'u1',
        'full_name': 'Ana Cruz',
        'rating': 4.6,
      });
      expect(record.accountStatus, 'active');
      expect(record.rating, 4.6);
      expect(record.totalRides, 0);
      expect(record.isSuspended, isFalse);
      expect(
          ProfileRecord.fromRow({
            'id': 'u2',
            'full_name': 'Bo Ling',
            'account_status': 'suspended',
          }).isSuspended,
          isTrue);
    });

    test('VehicleRecord exposes the listing vocabulary the UI uses', () {
      VehicleRecord row(String status) => VehicleRecord.fromRow({
            'id': 'v1',
            'owner_profile_id': 'o1',
            'name': 'Honda Click',
            'vehicle_type': 'Motorcycle',
            'category': '2-Wheel',
            'plate_number': 'NGD 1234',
            'status': status,
          });

      expect(row('active').isListed, isTrue);
      expect(row('active').statusLabel, 'Listed');
      expect(row('pending_verification').statusLabel, 'Pending verification');
      expect(row('inactive').isListed, isFalse);
      expect(row('inactive').statusLabel, 'Unlisted');
      expect(row('suspended').statusLabel, 'Suspended');
      expect(row('active').ownerName, isNull);
    });

    test('a vehicle embed carries the owner name when RLS allows it', () {
      final record = VehicleRecord.fromRow({
        'id': 'v1',
        'owner_profile_id': 'o1',
        'name': 'HiAce',
        'vehicle_type': 'Van',
        'category': '4-Wheel',
        'plate_number': 'NGD 8802',
        'owner': {'full_name': 'Owner Name'},
      });
      expect(record.ownerName, 'Owner Name');
      expect(record.status, 'pending_verification');
    });

    test('read state comes from read_at, not a stored boolean', () {
      NotificationRecord row(DateTime? readAt) => NotificationRecord.fromRow({
            'id': 'n1',
            'notification_type': 'ride',
            'title': 'Trip finished',
            'body': 'Rate your rider',
            'read_at': readAt?.toIso8601String(),
          });

      expect(row(null).isRead, isFalse);
      expect(row(null).readAt, isNull);
      expect(row(DateTime.utc(2026, 11, 6)).isRead, isTrue);
      expect(row(null).data, isEmpty);
    });

    test('a null budget stays null while a zero budget stays zero', () {
      ServiceRequestRecord row(Object? budget) => ServiceRequestRecord.fromRow({
            'id': 'sr1',
            'customer_id': 'c1',
            'service_area_id': 'sa1',
            'category': 'groceries',
            'status': 'available',
            'title': 'Buy rice',
            'pickup_address': 'San Jose',
            'budget_centavos': budget,
          });

      expect(row(null).budgetCentavos, isNull);
      expect(row(0).budgetCentavos, 0);
      expect(row(25000).budgetCentavos, 25000);
    });

    test('line items keep their own parent id', () {
      final record = ServiceRequestRecord.fromRow({
        'id': 'sr1',
        'customer_id': 'c1',
        'service_area_id': 'sa1',
        'category': 'pharmacy',
        'status': 'delivered',
        'title': 'Medicine',
        'pickup_address': 'Drugstore',
        'items': [
          {
            'id': 'i1',
            'service_request_id': 'sr1',
            'name': 'Paracetamol',
            'quantity': 2,
            'unit': 'strip',
            'estimated_unit_price_centavos': 15000,
          },
          {
            'id': 'i2',
            'service_request_id': 'sr1',
            'name': 'Vitamin C',
          },
        ],
      });
      expect(record.items, hasLength(2));
      expect(record.items.first.name, 'Paracetamol');
      expect(record.items.first.quantity, 2);
      expect(record.items.first.estimatedUnitPriceCentavos, 15000);
      expect(record.items.first.actualUnitPriceCentavos, isNull);
      expect(record.items.last.quantity, 1);
      expect(record.isOpen, isFalse);
      expect(record.isActive, isFalse);
    });

    test('ride rows require the columns the workflow depends on', () {
      expect(
        () => RideRecord.fromRow({
          'id': 'r1',
          'service_area_id': 'sa1',
          'status': 'searching',
        }),
        throwsA(isA<RepositoryFailure>()),
      );
      final ride = RideRecord.fromRow({
        'id': 'r1',
        'passenger_id': 'p1',
        'rider_id': null,
        'service_area_id': 'sa1',
        'status': 'searching',
        'pickup_address': 'City Hall',
        'dropoff_address': 'Airport',
        'fare_centavos': 14500,
        'platform_fee_centavos': 1450,
        'distance_km': '3.2',
        'pickup_barangay': {'name': 'San Roque'},
      });
      expect(ride.riderId, isNull);
      expect(ride.status, RideStatus.searching);
      expect(ride.fareCentavos, 14500);
      expect(ride.distanceKm, 3.2);
      expect(ride.pickupBarangayName, 'San Roque');
      expect(ride.paymentMethod, 'cash');
    });

    test('a remittance without a due date is rejected', () {
      expect(
        () => CashFeeRemittanceRecord.fromRow({
          'id': 'fee1',
          'provider_id': 'pr1',
          'amount_centavos': 1450,
        }),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.message.contains('fee1 has no due date.'))),
      );
      final fee = CashFeeRemittanceRecord.fromRow({
        'id': 'fee1',
        'provider_id': 'pr1',
        'amount_centavos': 1450,
        'status': 'overdue',
        'due_at': '2026-11-01T00:00:00.000Z',
      });
      expect(fee.isOutstanding, isTrue);
      expect(
          CashFeeRemittanceRecord.fromRow({
            'id': 'fee2',
            'provider_id': 'pr1',
            'status': 'remitted',
            'due_at': '2026-11-01T00:00:00.000Z',
          }).isOutstanding,
          isFalse);
    });

    test('wallet entries keep centavos and direction', () {
      final entry = WalletEntryRecord.fromRow({
        'id': 'w1',
        'wallet_account_id': 'wa1',
        'transaction_type': 'earning',
        'direction': 'credit',
        'amount_centavos': 250000,
        'balance_after_centavos': 1250000,
      });
      expect(entry.isCredit, isTrue);
      expect(entry.balanceAfterCentavos, 1250000);
      expect(
          WalletEntryRecord.fromRow({
            'id': 'w2',
            'wallet_account_id': 'wa1',
            'transaction_type': 'payout',
            'direction': 'debit',
            'amount_centavos': 100,
          }).isCredit,
          isFalse);
    });
  });

  group('mapBackendError', () {
    test('transport failures become offline', () {
      expect(mapBackendError(TimeoutException('timed out')).kind,
          RepositoryFailureKind.offline);
      expect(mapBackendError(SocketException('closed')).kind,
          RepositoryFailureKind.offline);
      expect(mapBackendError(HandshakeException('x', null)).kind,
          RepositoryFailureKind.offline);
    });

    test('PostgREST codes become the matching failure kind', () {
      expect(
          mapBackendError(const PostgrestException(
                  message: 'no rows', code: 'PGRST116'))
              .kind,
          RepositoryFailureKind.notFound);
      expect(
          mapBackendError(const PostgrestException(
                  message: 'row-level security', code: '42501'))
              .kind,
          RepositoryFailureKind.permissionDenied);
      expect(
          mapBackendError(const PostgrestException(
                  message: 'relation "rides" does not exist', code: '42P01'))
              .message,
          contains('relation "rides" does not exist'));
    });

    test('an unknown code with network wording is still offline', () {
      expect(
          mapBackendError(const PostgrestException(
                  message: 'Failed to fetch', code: 'PGRST002'))
              .kind,
          RepositoryFailureKind.offline);
      expect(
          mapBackendError(const PostgrestException(message: 'Failed to fetch'))
              .kind,
          RepositoryFailureKind.offline);
    });

    test('auth and data-shape errors keep their meaning', () {
      expect(mapBackendError(const AuthException('invalid token')).kind,
          RepositoryFailureKind.permissionDenied);
      expect(mapBackendError(ArgumentError('bad row')).kind,
          RepositoryFailureKind.invalidData);
      expect(mapBackendError(StateError('closed')).kind,
          RepositoryFailureKind.invalidData);
      expect(mapBackendError(Exception('boom')).kind,
          RepositoryFailureKind.unavailable);
    });

    test('a typed failure is returned unchanged', () {
      final original = RepositoryFailure.conflict('already accepted');
      expect(identical(mapBackendError(original), original), isTrue);
    });
  });

  group('UnreachableBackend', () {
    test('refuses both reads with an unavailable failure', () async {
      const backend = UnreachableBackend();
      await expectLater(
        backend.rows(table: 'profiles'),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.kind == RepositoryFailureKind.unavailable)),
      );
      await expectLater(
        backend.row(table: 'profiles', eq: {'id': 'u1'}),
        throwsA(isA<RepositoryFailure>()),
      );
    });
  });
}
