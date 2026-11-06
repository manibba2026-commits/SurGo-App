import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, SupabaseClient;
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/supabase_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/catalog_repository.dart';
import 'package:surgo/repositories/notification_repository.dart';
import 'package:surgo/repositories/pasuyo_repository.dart';
import 'package:surgo/repositories/profile_repository.dart';
import 'package:surgo/repositories/rental_repository.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/repositories/vehicle_repository.dart';
import 'package:surgo/repositories/verification_repository.dart';
import 'package:surgo/repositories/wallet_repository.dart';
import 'package:surgo/state/ride_status.dart';

/// Recorded arguments for one gateway call, so a repository test can prove the
/// query was scoped instead of only checking what a fake happened to return.
class BackendCall {
  const BackendCall({
    required this.table,
    required this.eq,
    required this.whereIn,
    required this.whereNull,
    required this.orderBy,
    required this.ascending,
    required this.limit,
    required this.single,
  });

  final String table;
  final Map<String, Object> eq;
  final Map<String, List<Object>> whereIn;
  final List<String> whereNull;
  final String? orderBy;
  final bool ascending;
  final int? limit;
  final bool single;
}

/// In-memory [SurgoBackend] with enough filtering to exercise repository
/// mapping. It never touches a network or a Supabase client.
class FakeBackend implements SurgoBackend {
  FakeBackend({
    Map<String, List<Map<String, dynamic>>> rowsByTable = const {},
    this.failure,
  }) : _rowsByTable = rowsByTable;

  final Map<String, List<Map<String, dynamic>>> _rowsByTable;
  final RepositoryFailure? failure;
  final List<BackendCall> calls = [];

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
    calls.add(
      BackendCall(
        table: table,
        eq: eq,
        whereIn: whereIn,
        whereNull: whereNull,
        orderBy: orderBy,
        ascending: ascending,
        limit: limit,
        single: false,
      ),
    );
    if (failure != null) throw failure!;

    var result =
        List<Map<String, dynamic>>.from(_rowsByTable[table] ?? const []);
    for (final filter in eq.entries) {
      result = result.where((row) => row[filter.key] == filter.value).toList();
    }
    for (final filter in whereIn.entries) {
      if (filter.value.isEmpty) return const [];
      result = result
          .where((row) => filter.value.contains(row[filter.key]))
          .toList();
    }
    for (final column in whereNull) {
      result = result.where((row) => row[column] == null).toList();
    }
    if (orderBy != null) {
      result.sort((a, b) {
        final left = a[orderBy];
        final right = b[orderBy];
        if (left is Comparable && right is Comparable) {
          final comparison = left.compareTo(right);
          return ascending ? comparison : -comparison;
        }
        return 0;
      });
    }
    return limit == null ? result : result.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    calls.add(
      BackendCall(
        table: table,
        eq: eq,
        whereIn: const {},
        whereNull: const [],
        orderBy: null,
        ascending: false,
        limit: null,
        single: true,
      ),
    );
    if (failure != null) throw failure!;
    for (final row in _rowsByTable[table] ?? const []) {
      if (eq.entries.every((filter) => row[filter.key] == filter.value)) {
        return row;
      }
    }
    return null;
  }
}

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({
    this.profile,
    this.roles = const [],
    this.profileFailure,
    this.rolesFailure,
  });

  final ProfileRecord? profile;
  final List<String> roles;
  final RepositoryFailure? profileFailure;
  final RepositoryFailure? rolesFailure;

  @override
  Future<ProfileRecord?> fetchProfile(String profileId) async {
    if (profileFailure != null) throw profileFailure!;
    return profile;
  }

  @override
  Future<List<String>> fetchApprovedRoles(String profileId) async {
    if (rolesFailure != null) throw rolesFailure!;
    return roles;
  }

  @override
  Future<List<RoleGrantRecord>> fetchRoleGrants(String profileId) async => [
        for (final role in roles)
          RoleGrantRecord(role: role, status: 'approved')
      ];

  @override
  Future<ProviderProfileRecord?> fetchProviderProfile(String profileId) async =>
      null;

  @override
  Future<List<VerificationApplicationRecord>> fetchVerificationApplications(
    String profileId,
  ) async =>
      const [];

  @override
  Future<Set<CapabilityType>> fetchApprovedCapabilities(
    String profileId,
  ) async =>
      capabilitiesFromRoles(roles);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await DbService.instance.load();
  });

  group('mock repositories read the seed', () {
    final db = DbService.instance;

    test('profile resolves a seeded profile and its approved capabilities',
        () async {
      final repository = MockProfileRepository(db);

      final profile =
          await repository.fetchProfile(DbService.primaryPassengerId);
      expect(profile, isNotNull);
      expect(profile!.fullName, isNotEmpty);
      expect(profile.accountStatus, 'active');

      final capabilities = await repository
          .fetchApprovedCapabilities(DbService.primaryPassengerId);
      expect(capabilities, contains(CapabilityType.passenger));
    });

    test('vehicles keep integer centavos and the stored status', () async {
      final repository = MockVehicleRepository(db);

      final listed = await repository.fetchListedVehicles();
      expect(listed, isNotEmpty);
      expect(
          listed.every((vehicle) => vehicle.pricePerDayCentavos > 0), isTrue);
      expect(listed.every((vehicle) => vehicle.status == 'active'), isTrue);
    });

    test('rides are scoped to the passenger and keep centavo fares', () async {
      final repository = MockRideRepository(db);

      final rides = await repository.fetchRidesForPassenger(
        DbService.primaryPassengerId,
      );
      expect(rides, isNotEmpty);
      expect(rides.every((ride) => ride.fareCentavos >= 0), isTrue);
    });

    test('rentals and errands return seeded records', () async {
      final rentals = await MockRentalRepository(db)
          .fetchRentalsByRenter(DbService.primaryPassengerId);
      expect(rentals, isNotEmpty);
      expect(rentals.first.totalFareCentavos, greaterThan(0));

      final errands =
          await MockPasuyoRepository(db).fetchOpenFeed(mockServiceAreaId);
      expect(errands, isNotEmpty);
      expect(errands.first.status.isOpen, isTrue);
    });

    test('wallet, notifications and verification read the per-profile slices',
        () async {
      final wallet = MockWalletRepository(db);
      expect(
        await wallet.fetchBalanceCentavos(DbService.primaryPassengerId),
        db.walletBalanceByUser[DbService.primaryPassengerId],
      );
      expect(
        await wallet.fetchTransactions(DbService.primaryPassengerId),
        isNotEmpty,
      );

      final notifications = MockNotificationRepository(db);
      expect(
        await notifications.fetchNotifications(DbService.primaryPassengerId),
        isNotEmpty,
      );

      final applications =
          await MockVerificationRepository(db).fetchApplications('ACC002');
      expect(applications, isNotEmpty);
      expect(applications.first.id, 'VAPP-ACC002-OWNER');
      expect(applications.first.documents, isNotEmpty);
    });
  });

  group('Supabase repositories map rows', () {
    test('ride rows keep centavos and the typed status', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'ride_requests': [
            {
              'id': 'ride-1',
              'passenger_id': 'p1',
              'service_area_id': 'sa1',
              'status': 'completed',
              'pickup_address': 'Pickup',
              'dropoff_address': 'Dropoff',
              'fare_centavos': 12345,
              'platform_fee_centavos': 1234,
              'requested_at': '2026-01-01T00:00:00Z',
              'completed_at': '2026-01-01T00:10:00Z',
            },
          ],
        },
      );
      final repository = SupabaseRideRepository(backend);

      final rides = await repository.fetchRidesForPassenger('p1');
      expect(rides, hasLength(1));
      expect(rides.single.fareCentavos, 12345);
      expect(rides.single.platformFeeCentavos, 1234);
      expect(rides.single.status, RideStatus.completed);
      expect(backend.calls.last.table, 'ride_requests');
      expect(backend.calls.last.eq['passenger_id'], 'p1');
    });

    test('vehicle rows keep the owner name only when embedded', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'vehicles': [
            {
              'id': 'v1',
              'owner_profile_id': 'o1',
              'service_area_id': 'sa1',
              'name': 'Honda Click',
              'vehicle_type': 'Motorcycle',
              'category': '2-Wheel',
              'plate_number': 'NGD 5521',
              'price_per_day_centavos': 50000,
              'status': 'active',
              'rating': 4.9,
              'total_rentals': 18,
              'owner': {'full_name': 'Owner Name'},
            },
          ],
        },
      );
      final repository = SupabaseVehicleRepository(backend);

      final vehicle = await repository.fetchVehicle('v1');
      expect(vehicle, isNotNull);
      expect(vehicle!.pricePerDayCentavos, 50000);
      expect(vehicle.ownerName, 'Owner Name');
      expect(vehicle.isListed, isTrue);
    });

    test('rental rows map vehicle details and the total fare', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'rental_bookings': [
            {
              'id': 'rental-1',
              'renter_id': 'p1',
              'owner_id': 'o1',
              'vehicle_id': 'v1',
              'service_area_id': 'sa1',
              'status': 'active',
              'start_at': '2026-01-01T00:00:00Z',
              'end_at': '2026-01-02T00:00:00Z',
              'total_fare_centavos': 75000,
              'payment_method': 'gcash',
              'vehicle': {'name': 'Honda Click', 'plate_number': 'NGD 5521'},
            },
          ],
        },
      );
      final repository = SupabaseRentalRepository(backend);

      final rentals = await repository.fetchRentalsByRenter('p1');
      expect(rentals, hasLength(1));
      expect(rentals.single.totalFareCentavos, 75000);
      expect(rentals.single.vehicleName, 'Honda Click');
      expect(backend.calls.last.eq['renter_id'], 'p1');
    });

    test('errand rows map the database category and line items', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'service_requests': [
            {
              'id': 'errand-1',
              'customer_id': 'c1',
              'service_area_id': mockServiceAreaId,
              'category': 'food_delivery',
              'status': 'available',
              'title': 'Buy lunch',
              'pickup_address': 'Jollibee',
              'budget_centavos': 18000,
              'items': [
                {
                  'id': 'item-1',
                  'service_request_id': 'errand-1',
                  'name': 'Chickenjoy',
                  'quantity': 2,
                },
              ],
            },
          ],
        },
      );
      final repository = SupabasePasuyoRepository(backend);

      final errands = await repository.fetchOpenFeed(mockServiceAreaId);
      expect(errands, hasLength(1));
      expect(errands.single.category, PasuyoCategory.foodDelivery);
      expect(errands.single.budgetCentavos, 18000);
      expect(errands.single.items.single.name, 'Chickenjoy');
    });

    test('wallet rows keep centavos and direction', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'wallet_accounts': [
            {
              'id': 'w1',
              'profile_id': 'p1',
              'account_type': 'passenger',
              'balance_centavos': 85000,
              'is_active': true,
            },
          ],
          'wallet_transactions': [
            {
              'id': 't1',
              'wallet_account_id': 'w1',
              'transaction_type': 'top_up',
              'direction': 'credit',
              'amount_centavos': 50000,
              'balance_after_centavos': 85000,
            },
          ],
        },
      );
      final repository = SupabaseWalletRepository(backend);

      expect(await repository.fetchBalanceCentavos('p1'), 85000);
      final transactions = await repository.fetchTransactions('p1');
      expect(transactions, hasLength(1));
      expect(transactions.single.amountCentavos, 50000);
      expect(transactions.single.balanceAfterCentavos, 85000);
      expect(transactions.single.isCredit, isTrue);
    });

    test('notification read state comes from read_at', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'notifications': [
            {
              'id': 'n1',
              'profile_id': 'p1',
              'notification_type': 'ride',
              'title': 'Ride complete',
              'body': 'Thanks for riding.',
              'read_at': null,
            },
          ],
        },
      );
      final repository = SupabaseNotificationRepository(backend);

      final notifications = await repository.fetchNotifications('p1');
      expect(notifications.single.isRead, isFalse);
      expect(await repository.countUnread('p1'), 1);
      expect(backend.calls.last.whereNull, contains('read_at'));
    });

    test('verification rows include their document list', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'verification_applications': [
            {
              'id': 'app-1',
              'profile_id': 'p1',
              'capability_type': 'vehicle_owner',
              'status': 'approved',
              'submitted_at': '2026-01-01T00:00:00Z',
              'documents': [
                {
                  'id': 'doc-1',
                  'application_id': 'app-1',
                  'document_type': 'orcr',
                  'status': 'approved',
                  'is_required': true,
                },
              ],
            },
          ],
          'verification_documents': [
            {
              'id': 'doc-1',
              'application_id': 'app-1',
              'document_type': 'orcr',
              'status': 'approved',
              'is_required': true,
            },
          ],
        },
      );
      final repository = SupabaseVerificationRepository(backend);

      final applications = await repository.fetchApplications('p1');
      expect(applications.single.capabilityType, 'vehicle_owner');
      expect(applications.single.documents.single.documentType, 'orcr');

      final documents = await repository.fetchDocuments('app-1');
      expect(documents, hasLength(1));
      expect(backend.calls.last.table, 'verification_documents');
    });
  });

  group('typed failures', () {
    test('a permission failure is not hidden by a repository', () async {
      final repository = SupabaseRideRepository(
        FakeBackend(failure: RepositoryFailure.permissionDenied()),
      );

      await expectLater(
        repository.fetchRide('ride-1'),
        throwsA(
          isA<RepositoryFailure>().having(
            (failure) => failure.kind,
            'kind',
            RepositoryFailureKind.permissionDenied,
          ),
        ),
      );
    });

    test('an unknown enum token is invalid data, not a default status',
        () async {
      final backend = FakeBackend(
        rowsByTable: {
          'ride_requests': [
            {
              'id': 'ride-1',
              'passenger_id': 'p1',
              'service_area_id': 'sa1',
              'status': 'teleported',
              'pickup_address': 'Pickup',
              'dropoff_address': 'Dropoff',
            },
          ],
        },
      );

      await expectLater(
        SupabaseRideRepository(backend).fetchRide('ride-1'),
        throwsA(
          isA<RepositoryFailure>().having(
            (failure) => failure.kind,
            'kind',
            RepositoryFailureKind.invalidData,
          ),
        ),
      );
    });

    test('a missing required column is invalid data', () async {
      final backend = FakeBackend(
        rowsByTable: {
          'vehicles': [
            {
              'id': 'v1',
              'owner_profile_id': 'o1',
              'name': 'Honda Click',
              'vehicle_type': 'Motorcycle',
              'category': '2-Wheel',
            },
          ],
        },
      );

      await expectLater(
        SupabaseVehicleRepository(backend).fetchVehicle('v1'),
        throwsA(
          isA<RepositoryFailure>().having(
            (failure) => failure.kind,
            'kind',
            RepositoryFailureKind.invalidData,
          ),
        ),
      );
    });

    test('an unreachable build refuses instead of serving seed data', () async {
      await expectLater(
        const UnreachableBackend().rows(table: 'profiles'),
        throwsA(
          isA<RepositoryFailure>().having(
            (failure) => failure.kind,
            'kind',
            RepositoryFailureKind.unavailable,
          ),
        ),
      );
    });

    test('a feature with no backend table reports unsupported', () async {
      await expectLater(
        SupabaseCatalogRepository(FakeBackend()).fetchPlaces(),
        throwsA(
          isA<RepositoryFailure>().having(
            (failure) => failure.kind,
            'kind',
            RepositoryFailureKind.unsupported,
          ),
        ),
      );
    });

    test('gateway errors map to the right typed failure', () {
      expect(
        mapBackendError(const PostgrestException(
          message: 'JSON object requested, multiple (or no) rows returned',
          code: 'PGRST116',
        )).kind,
        RepositoryFailureKind.notFound,
      );
      expect(
        mapBackendError(const PostgrestException(
          message: 'permission denied for table profiles',
          code: '42501',
        )).kind,
        RepositoryFailureKind.permissionDenied,
      );
      expect(
        mapBackendError(TimeoutException('slow')).kind,
        RepositoryFailureKind.offline,
      );
    });
  });

  group('registry', () {
    test('mock mode installs only the seeded implementations', () {
      final registry = RepositoryRegistry.mock(DbService.instance);

      expect(registry.isSupabaseBacked, isFalse);
      expect(registry.profiles, isA<MockProfileRepository>());
      expect(registry.catalog, isA<MockCatalogRepository>());
      expect(registry.vehicles, isA<MockVehicleRepository>());
      expect(registry.rides, isA<MockRideRepository>());
      expect(registry.rentals, isA<MockRentalRepository>());
      expect(registry.pasuyo, isA<MockPasuyoRepository>());
      expect(registry.notifications, isA<MockNotificationRepository>());
      expect(registry.wallet, isA<MockWalletRepository>());
      expect(registry.verifications, isA<MockVerificationRepository>());
    });

    test('Supabase mode installs only the read implementations', () {
      final registry = RepositoryRegistry.supabase(FakeBackend());

      expect(registry.isSupabaseBacked, isTrue);
      expect(registry.profiles, isA<SupabaseProfileRepository>());
      expect(registry.catalog, isA<SupabaseCatalogRepository>());
      expect(registry.vehicles, isA<SupabaseVehicleRepository>());
      expect(registry.rides, isA<SupabaseRideRepository>());
      expect(registry.rentals, isA<SupabaseRentalRepository>());
      expect(registry.pasuyo, isA<SupabasePasuyoRepository>());
      expect(registry.notifications, isA<SupabaseNotificationRepository>());
      expect(registry.wallet, isA<SupabaseWalletRepository>());
      expect(registry.verifications, isA<SupabaseVerificationRepository>());
    });
  });

  group('auth uses the profile repository', () {
    SupabaseAuthRepository buildAuth(ProfileRepository profiles) {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'sb_publishable_test',
      );
      return SupabaseAuthRepository(client: client, profiles: profiles);
    }

    test('loads name, email and roles through the repository', () async {
      final auth = buildAuth(
        FakeProfileRepository(
          profile: const ProfileRecord(
            id: 'u1',
            fullName: 'Repository User',
            email: 'repo@example.com',
          ),
          roles: const ['passenger', 'rider', 'vehicle_owner'],
        ),
      );

      final identity = await auth.loadIdentity(
        const AuthUser(id: 'u1', phone: '+639170000000'),
      );
      expect(identity.fullName, 'Repository User');
      expect(identity.email, 'repo@example.com');
      expect(
          identity.roles, containsAll(['passenger', 'rider', 'vehicle_owner']));
      expect(identity.capabilities, contains(CapabilityType.earner));
      expect(identity.capabilities, contains(CapabilityType.rider));
      expect(identity.capabilities, contains(CapabilityType.vehicleOwner));
    });

    test('a failed profile and role read still allows a passenger session',
        () async {
      final auth = buildAuth(
        FakeProfileRepository(
          profileFailure: RepositoryFailure.offline(),
          rolesFailure: RepositoryFailure.offline(),
        ),
      );

      final identity = await auth.loadIdentity(
        const AuthUser(id: 'u2', email: 'fallback@example.com'),
      );
      expect(identity.capabilities, {CapabilityType.passenger});
      expect(identity.fullName, isNull);
      expect(identity.email, 'fallback@example.com');
    });
  });
}
