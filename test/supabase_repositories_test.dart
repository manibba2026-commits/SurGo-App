import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart' show CapabilityType, PasuyoCategory;
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/catalog_repository.dart';
import 'package:surgo/repositories/notification_repository.dart';
import 'package:surgo/repositories/pasuyo_repository.dart';
import 'package:surgo/repositories/profile_repository.dart';
import 'package:surgo/repositories/rental_repository.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/repositories/vehicle_repository.dart';
import 'package:surgo/repositories/wallet_repository.dart';
import 'package:surgo/state/pasuyo_status.dart';

/// Drives the Supabase repositories with recorded rows so the query each one
/// builds and the mapping it applies are both checked without a network.
class RecordingBackend implements SurgoBackend {
  RecordingBackend(this.responder);

  /// Return the rows for a call, or throw to simulate a failing read.
  final List<Map<String, dynamic>> Function(RecordedCall call) responder;

  final List<RecordedCall> calls = [];

  RecordedCall _record(
    String table,
    String columns,
    Map<String, Object> eq,
    Map<String, List<Object>> whereIn,
    List<String> whereNull,
    String? orderBy,
    bool ascending,
    int? limit,
  ) {
    final call = RecordedCall(
      table: table,
      columns: columns,
      eq: eq,
      whereIn: whereIn,
      whereNull: whereNull,
      orderBy: orderBy,
      ascending: ascending,
      limit: limit,
    );
    calls.add(call);
    return call;
  }

  @override
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async {
    return responder(_record(
        table, columns, eq, whereIn, whereNull, orderBy, ascending, limit));
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    final rows = responder(
        _record(table, columns, eq, const {}, const [], null, false, null));
    return rows.isEmpty ? null : rows.first;
  }

  RecordedCall get last => calls.last;
}

class RecordedCall {
  RecordedCall({
    required this.table,
    required this.columns,
    required this.eq,
    required this.whereIn,
    required this.whereNull,
    required this.orderBy,
    required this.ascending,
    required this.limit,
  });

  final String table;
  final String columns;
  final Map<String, Object> eq;
  final Map<String, List<Object>> whereIn;
  final List<String> whereNull;
  final String? orderBy;
  final bool ascending;
  final int? limit;
}

void main() {
  final backend = RecordingBackend((_) => const []);

  setUp(() => backend.calls.clear());

  group('profiles', () {
    test('reads the profile row by auth id', () async {
      final subject = RecordingBackend((call) => call.table == 'profiles'
          ? [
              {
                'id': 'auth-1',
                'full_name': 'Marisol Cruz',
                'first_name': 'Marisol',
                'email': 'marisol@example.ph',
                'phone': '+639175124809',
                'account_status': 'active',
                'rating': 4.81,
                'total_rides': 27,
              },
            ]
          : const []);
      final record =
          await SupabaseProfileRepository(subject).fetchProfile('auth-1');
      expect(subject.last.eq, {'id': 'auth-1'});
      expect(record!.fullName, 'Marisol Cruz');
      expect(record.rating, 4.81);
      expect(record.totalRides, 27);
    });

    test('a missing profile reads as null rather than a placeholder', () async {
      expect(await SupabaseProfileRepository(backend).fetchProfile('ghost'),
          isNull);
      expect(backend.last.table, 'profiles');
    });

    test('only approved grants unlock capabilities', () async {
      final subject = RecordingBackend((call) => call.table == 'user_roles'
          ? [
              {'role': 'passenger', 'status': 'approved'},
              {'role': 'rider', 'status': 'pending'},
              {'role': 'vehicle_owner', 'status': 'approved'},
            ]
          : const []);
      final repository = SupabaseProfileRepository(subject);
      expect(await repository.fetchApprovedRoles('u1'),
          ['passenger', 'vehicle_owner']);
      expect(await repository.fetchApprovedCapabilities('u1'),
          {CapabilityType.passenger, CapabilityType.vehicleOwner});
      expect(subject.last.eq, {'profile_id': 'u1'});
      expect(subject.last.columns, contains('approved_at'));
    });

    test('verification applications arrive with their documents', () async {
      final subject =
          RecordingBackend((call) => call.table == 'verification_applications'
              ? [
                  {
                    'id': 'app1',
                    'profile_id': 'u1',
                    'capability_type': 'rider',
                    'status': 'under_review',
                    'submitted_at': '2026-11-01T00:00:00.000Z',
                    'documents': [
                      {
                        'id': 'doc1',
                        'application_id': 'app1',
                        'document_type': 'license',
                        'label': "Driver's License",
                        'status': 'approved',
                        'is_required': true,
                      },
                    ],
                  },
                ]
              : const []);
      final applications = await SupabaseProfileRepository(subject)
          .fetchVerificationApplications('u1');
      expect(applications, hasLength(1));
      expect(applications.single.status, 'under_review');
      expect(applications.single.documents.single.label, "Driver's License");
      expect(subject.last.orderBy, 'created_at');
      expect(
          subject.last.columns, contains('documents:verification_documents'));
    });

    test('provider capabilities keep the raw database tokens', () async {
      final subject =
          RecordingBackend((call) => call.table == 'provider_profiles'
              ? [
                  {
                    'profile_id': 'u1',
                    'provider_type': 'earner',
                    'service_area_id': 'sa-tandag',
                    'capabilities': ['rides', 'errands'],
                    'is_available': true,
                    'rating': 4.6,
                    'total_trips': 133,
                  },
                ]
              : const []);
      final provider =
          await SupabaseProfileRepository(subject).fetchProviderProfile('u1');
      expect(provider!.capabilityTokens, ['rides', 'errands']);
      expect(provider.isAvailable, isTrue);
      expect(provider.totalTrips, 133);
    });
  });

  group('catalog', () {
    test('service areas and barangays are read in name order', () async {
      final subject = RecordingBackend((call) => switch (call.table) {
            'service_areas' => [
                {
                  'id': 'sa-tandag',
                  'name': 'Tandag City',
                  'city': 'Tandag City',
                  'province': 'Surigao del Sur',
                  'is_active': true,
                },
              ],
            'barangays' => [
                {
                  'id': 'bg-1',
                  'name': 'Barangay 1',
                  'service_area_id': 'sa-tandag',
                  'puroks': [
                    {'id': 'pu-1a', 'name': 'Purok 1-A', 'barangay_id': 'bg-1'},
                  ],
                },
              ],
            _ => const <Map<String, dynamic>>[],
          });
      final repository = SupabaseCatalogRepository(subject);

      final areas = await repository.fetchServiceAreas();
      expect(areas.single.name, 'Tandag City');
      expect(subject.calls[0].eq, {'is_active': true});
      expect(subject.calls[0].orderBy, 'name');
      expect(subject.calls[0].ascending, isTrue);

      final barangays = await repository.fetchBarangays('sa-tandag');
      expect(barangays.single.puroks.single.name, 'Purok 1-A');
      expect(subject.calls[1].eq, {'service_area_id': 'sa-tandag'});
    });

    test('pricing policies read only active rows', () async {
      final subject = RecordingBackend((call) => [
            {
              'id': 'pp1',
              'name': 'Tandag ride',
              'service_type': 'ride',
              'is_active': true,
              'base_fare_centavos': 50000,
              'platform_fee_bps': 1000,
            },
          ]);
      final policies =
          await SupabaseCatalogRepository(subject).fetchActivePricingPolicies();
      expect(policies.single.baseFareCentavos, 50000);
      expect(policies.single.platformFeeBps, 1000);
      expect(subject.last.eq, {'is_active': true});
      expect(subject.last.orderBy, 'effective_from');
    });

    test('landmarks report unsupported instead of serving the seed', () async {
      // Requirement: a Supabase build must not substitute fake data.
      await expectLater(
        SupabaseCatalogRepository(backend).fetchPlaces(),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.kind == RepositoryFailureKind.unsupported)),
      );
      expect(backend.calls, isEmpty);
    });
  });

  group('vehicles', () {
    test('the rental catalogue filters on the listing status', () async {
      final subject = RecordingBackend((call) => [
            {
              'id': 'v1',
              'owner_profile_id': 'o1',
              'service_area_id': 'sa-tandag',
              'name': 'Honda Click 125i',
              'vehicle_type': 'Motorcycle',
              'category': '2-Wheel',
              'plate_number': 'NGD 5521',
              'price_per_day_centavos': 50000,
              'status': 'active',
            },
          ]);
      final listed = await SupabaseVehicleRepository(subject)
          .fetchListedVehicles(serviceAreaId: 'sa-tandag');
      expect(listed.single.plateNumber, 'NGD 5521');
      expect(subject.last.eq,
          {'status': 'active', 'service_area_id': 'sa-tandag'});
      expect(subject.last.columns, contains('owner:profiles(full_name)'));
    });

    test('an empty id list is answered without a query', () async {
      final subject = RecordingBackend((_) => const []);
      final repository = SupabaseVehicleRepository(subject);
      expect(await repository.fetchVehiclesByIds(const []), isEmpty);
      expect(await repository.fetchDocuments(const []), isEmpty);
      expect(subject.calls, isEmpty);
    });

    test('documents are read for the requested vehicles', () async {
      await SupabaseVehicleRepository(backend).fetchDocuments(['v1', 'v2']);
      expect(backend.last.table, 'vehicle_documents');
      expect(backend.last.whereIn, {
        'vehicle_id': ['v1', 'v2'],
      });
    });

    test('ownership reads filter on the owner profile', () async {
      await SupabaseVehicleRepository(backend).fetchVehiclesOwnedBy('o1');
      expect(backend.last.eq, {'owner_profile_id': 'o1'});
    });
  });

  group('rides', () {
    test('passenger and rider reads are scoped by their own column', () async {
      await SupabaseRideRepository(backend)
          .fetchRidesForPassenger('p1', limit: 20);
      expect(backend.last.table, 'ride_requests');
      expect(backend.last.eq, {'passenger_id': 'p1'});
      expect(backend.last.limit, 20);
      expect(backend.last.orderBy, 'requested_at');

      await SupabaseRideRepository(backend).fetchRidesForRider('r1');
      expect(backend.last.eq, {'rider_id': 'r1'});
    });

    test('the open pool asks for both unclaimed statuses', () async {
      await SupabaseRideRepository(backend).fetchOpenPool('sa-tandag');
      expect(backend.last.eq, {'service_area_id': 'sa-tandag'});
      expect(backend.last.whereIn, {
        'status': ['searching', 'awaiting_acceptance'],
      });
    });

    test('an unassignable ride row keeps its ids separate', () async {
      final subject = RecordingBackend((_) => [
            {
              'id': 'r1',
              'passenger_id': 'p1',
              'rider_id': 'r1x',
              'service_area_id': 'sa-tandag',
              'status': 'in_progress',
              'pickup_address': 'City Hall',
              'dropoff_address': 'San Roque',
              'fare_centavos': 95000,
              'platform_fee_centavos': 9500,
              'note': 'Follow the shortcut',
            },
          ]);
      final ride = await SupabaseRideRepository(subject).fetchRide('r1');
      expect(ride!.passengerId, 'p1');
      expect(ride.riderId, 'r1x');
      expect(ride.note, 'Follow the shortcut');
      expect(ride.platformFeeCentavos, 9500);
      expect(ride.passengerName, isNull);
      expect(subject.last.eq, {'id': 'r1'});
    });

    test('the status timeline is read oldest first', () async {
      final subject = RecordingBackend((_) => [
            {
              'id': 'e1',
              'ride_id': 'r1',
              'status': 'accepted',
              'created_at': '2026-11-06T01:00:00.000Z',
            },
          ]);
      final events =
          await SupabaseRideRepository(subject).fetchStatusEvents('r1');
      expect(events.single.status.name, 'accepted');
      expect(subject.last.table, 'ride_status_events');
      expect(subject.last.orderBy, 'created_at');
      expect(subject.last.ascending, isTrue);
    });
  });

  group('rentals', () {
    test('renter and owner reads use their own columns', () async {
      await SupabaseRentalRepository(backend).fetchRentalsByRenter('p1');
      expect(backend.last.table, 'rental_bookings');
      expect(backend.last.eq, {'renter_id': 'p1'});
      expect(backend.last.orderBy, 'start_at');

      await SupabaseRentalRepository(backend).fetchRentalsByOwner('o1');
      expect(backend.last.eq, {'owner_id': 'o1'});
    });

    test('the vehicle embed names the booking', () async {
      final subject = RecordingBackend((_) => [
            {
              'id': 'rb1',
              'renter_id': 'p1',
              'owner_id': 'o1',
              'vehicle_id': 'v1',
              'service_area_id': 'sa-tandag',
              'status': 'active',
              'start_at': '2026-11-06T00:00:00.000Z',
              'end_at': '2026-11-08T00:00:00.000Z',
              'duration_hours': 48,
              'total_fare_centavos': 100000,
              'vehicle': {'name': 'HiAce', 'plate_number': 'NGD 8802'},
            },
          ]);
      final rental = await SupabaseRentalRepository(subject).fetchRental('rb1');
      expect(rental!.vehicleName, 'HiAce');
      expect(rental.vehiclePlateNumber, 'NGD 8802');
      expect(rental.durationHours, 48);
      expect(rental.status.name, 'active');
    });
  });

  group('pasuyo', () {
    test('the earner feed filters by area, status and category', () async {
      await SupabasePasuyoRepository(backend)
          .fetchOpenFeed('sa-tandag', category: PasuyoCategory.foodDelivery);
      expect(backend.last.table, 'service_requests');
      expect(backend.last.eq, {
        'service_area_id': 'sa-tandag',
        'status': 'available',
        'category': 'food_delivery',
      });
    });

    test('participants are read from their own columns', () async {
      await SupabasePasuyoRepository(backend).fetchRequestsByCustomer('c1');
      expect(backend.last.eq, {'customer_id': 'c1'});
      await SupabasePasuyoRepository(backend).fetchRequestsByProvider('pr1');
      expect(backend.last.eq, {'provider_id': 'pr1'});
    });

    test('a request row keeps items and derived state', () async {
      final subject = RecordingBackend((_) => [
            {
              'id': 'sr1',
              'customer_id': 'c1',
              'provider_id': null,
              'service_area_id': 'sa-tandag',
              'category': 'groceries',
              'status': 'available',
              'title': 'Rice and eggs',
              'pickup_address': 'City Market',
              'dropoff_address': 'Purok 4',
              'quoted_fee_centavos': 40000,
              'items': [
                {
                  'id': 'i1',
                  'service_request_id': 'sr1',
                  'name': 'Rice 25kg',
                },
              ],
            },
          ]);
      final request =
          await SupabasePasuyoRepository(subject).fetchRequest('sr1');
      expect(request!.isOpen, isTrue);
      expect(request.status, PasuyoStatus.available);
      expect(request.providerId, isNull);
      expect(request.items.single.name, 'Rice 25kg');
    });

    test('status events are read oldest first', () async {
      await SupabasePasuyoRepository(backend).fetchStatusEvents('sr1');
      expect(backend.last.table, 'service_status_events');
      expect(backend.last.ascending, isTrue);
    });
  });

  group('notifications', () {
    test('the feed is read newest first with a limit', () async {
      await SupabaseNotificationRepository(backend)
          .fetchNotifications('u1', limit: 30);
      expect(backend.last.table, 'notifications');
      expect(backend.last.eq, {'profile_id': 'u1'});
      expect(backend.last.orderBy, 'created_at');
      expect(backend.last.ascending, isFalse);
      expect(backend.last.limit, 30);
    });

    test('the unread badge asks for rows with no read timestamp', () async {
      final subject = RecordingBackend((call) => call.whereNull.isEmpty
          ? const []
          : const [
              {'id': 'n1'},
              {'id': 'n2'},
            ]);
      expect(
          await SupabaseNotificationRepository(subject).countUnread('u1'), 2);
      expect(subject.last.eq, {'profile_id': 'u1'});
      expect(subject.last.whereNull, ['read_at']);
      expect(subject.last.columns, 'id');
    });
  });

  group('wallet', () {
    test('the balance sums only active accounts', () async {
      final subject = RecordingBackend((_) => [
            {
              'id': 'wa1',
              'profile_id': 'u1',
              'account_type': 'passenger',
              'balance_centavos': 250000,
              'is_active': true,
            },
            {
              'id': 'wa2',
              'profile_id': 'u1',
              'account_type': 'earner',
              'balance_centavos': 900000,
              'is_active': false,
            },
          ]);
      final repository = SupabaseWalletRepository(subject);
      expect(await repository.fetchBalanceCentavos('u1'), 250000);
      expect(subject.last.table, 'wallet_accounts');
      expect(subject.last.eq, {'profile_id': 'u1'});
    });

    test(
        'history is read through the wallet ids, and none when there are no '
        'wallets', () async {
      final subject = RecordingBackend((call) => call.table == 'wallet_accounts'
          ? [
              {
                'id': 'wa1',
                'profile_id': 'u1',
                'account_type': 'earner',
                'balance_centavos': 100,
              },
            ]
          : [
              {
                'id': 'wt1',
                'wallet_account_id': 'wa1',
                'transaction_type': 'earning',
                'direction': 'credit',
                'amount_centavos': 100,
              },
            ]);
      final entries = await SupabaseWalletRepository(subject)
          .fetchTransactions('u1', limit: 5);
      expect(entries.single.id, 'wt1');
      final historyCall = subject.calls.last;
      expect(historyCall.whereIn, {
        'wallet_account_id': ['wa1'],
      });
      expect(historyCall.limit, 5);

      subject.calls.clear();
      final empty = RecordingBackend((_) => const []);
      expect(await SupabaseWalletRepository(empty).fetchTransactions('u1'),
          isEmpty);
      expect(empty.calls, hasLength(1));
    });

    test('settlements merge both sides without duplicating a row', () async {
      final subject = RecordingBackend((call) {
        if (call.eq.containsKey('customer_id')) {
          return [
            _settlement('st1', '2026-11-05T00:00:00.000Z'),
            _settlement('st2', '2026-11-07T00:00:00.000Z'),
          ];
        }
        // The same two rows, seen from the provider side, plus one new row.
        return [
          _settlement('st2', '2026-11-07T00:00:00.000Z'),
          _settlement('st3', '2026-11-06T00:00:00.000Z'),
        ];
      });
      final settlements =
          await SupabaseWalletRepository(subject).fetchSettlements('u1');
      expect(subject.calls, hasLength(2));
      expect(subject.calls[0].eq, {'customer_id': 'u1'});
      expect(subject.calls[1].eq, {'provider_id': 'u1'});
      expect(settlements.map((s) => s.id), ['st2', 'st3', 'st1']);
      expect(settlements.first.platformRevenueCentavos, 9500);
    });

    test('remittances are read due-first', () async {
      final subject = RecordingBackend((_) => [
            {
              'id': 'fee1',
              'provider_id': 'u1',
              'amount_centavos': 9500,
              'status': 'pending',
              'due_at': '2026-11-10T00:00:00.000Z',
            },
          ]);
      final fees =
          await SupabaseWalletRepository(subject).fetchFeeRemittances('u1');
      expect(fees.single.isOutstanding, isTrue);
      expect(subject.last.table, 'cash_fee_remittances');
      expect(subject.last.orderBy, 'due_at');
      expect(subject.last.ascending, isTrue);
    });
  });

  group('failures', () {
    test('a rejection surfaces as the typed failure, not as empty data',
        () async {
      final subject = RecordingBackend((_) {
        throw RepositoryFailure.permissionDenied();
      });
      await expectLater(
        SupabaseRideRepository(subject).fetchRidesForPassenger('p1'),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.kind == RepositoryFailureKind.permissionDenied)),
      );
    });

    test('a Supabase build whose client never booted never reads the seed',
        () async {
      final registry = RepositoryRegistry.supabase(const UnreachableBackend());
      expect(registry.isSupabaseBacked, isTrue);
      expect(registry.description, 'Supabase (read-only)');
      await expectLater(
        registry.wallet.fetchBalanceCentavos('u1'),
        throwsA(isA<RepositoryFailure>()),
      );
      await expectLater(
        registry.profiles.fetchProfile('u1'),
        throwsA(isA<RepositoryFailure>()),
      );
    });
  });
}

Map<String, dynamic> _settlement(String id, String createdAt) => {
      'id': id,
      'service_type': 'ride',
      'customer_id': 'u1',
      'provider_id': 'r1',
      'fare_centavos': 95000,
      'platform_fee_centavos': 9500,
      'customer_pays_centavos': 95000,
      'provider_payout_centavos': 85500,
      'platform_revenue_centavos': 9500,
      'status': 'completed',
      'created_at': createdAt,
    };
