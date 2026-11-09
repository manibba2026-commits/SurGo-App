import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/data_source.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/main.dart';
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
import 'package:surgo/state/ride_status.dart';

/// The seeded adapters must keep answering exactly what the prototype screens
/// expect, because they are still the default build and the test fixture.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DbService db;
  late List<Account> originalAccounts;

  setUpAll(() async {
    db = DbService.instance;
    await db.load();
    originalAccounts = db.accounts;
  });

  /// Links a demo account to an auth uuid, the way a signed-in user is.
  Account linkToAuth(String accountId, String authUserId) {
    final linked = db.accounts
        .firstWhere((a) => a.id == accountId)
        .copyWith(authUserId: authUserId);
    db.accounts = [
      for (final account in db.accounts)
        if (account.id == accountId) linked else account,
    ];
    return linked;
  }

  tearDown(() => db.accounts = originalAccounts);

  group('MockProfileRepository', () {
    test('reads a seeded profile by its own id', () async {
      final repository = MockProfileRepository(db);
      final passenger = db.passengers[DbService.primaryPassengerId]!;
      final record =
          await repository.fetchProfile(DbService.primaryPassengerId);
      expect(record!.fullName, passenger.name);
      expect(record.phone, passenger.phone);
      expect(record.totalRides, passenger.totalRides);
      expect(record.accountStatus, 'active');
    });

    test('an auth user with no seeded account has no profile', () async {
      // Inventing one would show a stranger's wallet on the screen.
      expect(await MockProfileRepository(db).fetchProfile('nobody-at-all'),
          isNull);
    });

    test('roles come from the approved capabilities of the linked account',
        () async {
      linkToAuth('ACC001', 'auth-1');
      final repository = MockProfileRepository(db);
      final grants = await repository.fetchRoleGrants('auth-1');
      expect(grants, isNotEmpty);
      expect(grants.every((grant) => grant.isApproved), isTrue);
      expect(await repository.fetchApprovedRoles('auth-1'),
          containsAll(['passenger', 'earner', 'rider', 'vehicle_owner']));
      expect(
          await repository.fetchApprovedCapabilities('auth-1'),
          containsAll([
            CapabilityType.passenger,
            CapabilityType.rider,
            CapabilityType.vehicleOwner,
          ]));
    });

    test('unlinked id yields no grants rather than the demo roles', () async {
      expect(
          await MockProfileRepository(db).fetchRoleGrants('auth-1'), isEmpty);
    });

    test('verification applications carry the seeded documents', () async {
      final account = db.accounts.firstWhere((a) =>
          db.verificationApplications.any((app) => app.accountId == a.id));
      final linked = linkToAuth(account.id, 'auth-verify');
      final applications = await MockProfileRepository(db)
          .fetchVerificationApplications('auth-verify');
      expect(applications, isNotEmpty);
      for (final application in applications) {
        expect(application.profileId, 'auth-verify');
        expect(application.status, isNotEmpty);
        for (final document in application.documents) {
          expect(document.status, anyOf('approved', 'pending'));
        }
      }
      expect(linked.authUserId, 'auth-verify');
    });

    test('a rider-only earner reads back as a provider profile', () async {
      final repository = MockProfileRepository(db);
      final provider =
          await repository.fetchProviderProfile(DbService.primaryEarnerId);
      expect(provider!.providerType, 'earner');
      expect(provider.capabilityTokens, isNotEmpty);
      expect(await repository.fetchProviderProfile('P003'), isNull);
    });
  });

  group('MockCatalogRepository', () {
    test('one service area stands in for the pilot city', () async {
      final areas = await MockCatalogRepository(db).fetchServiceAreas();
      expect(areas, hasLength(1));
      expect(areas.single.city, db.cityName);
      expect(areas.single.isActive, isTrue);
    });

    test('purok ids stay children of their own barangay', () async {
      final barangays =
          await MockCatalogRepository(db).fetchBarangays('sa-tandag-city');
      expect(barangays.length, db.barangays.length);
      for (final barangay in barangays) {
        expect(barangay.serviceAreaId, 'sa-tandag-city');
        for (var p = 0; p < barangay.puroks.length; p++) {
          final purok = barangay.puroks[p];
          expect(purok.id, '${barangay.id}-purok-$p');
          expect(purok.barangayId, barangay.id);
          expect(barangay.name, isNotEmpty);
        }
      }
    });

    test('a purok round-trips through the barangay list', () async {
      final repository = MockCatalogRepository(db);
      final barangays = await repository.fetchBarangays('sa-tandag-city');
      final first = barangays.first.puroks.isNotEmpty
          ? barangays.first.puroks.first
          : barangays[1].puroks.first;
      expect(await repository.fetchPurok(first.id), isNotNull);
      expect((await repository.fetchPurok(first.id))!.name, first.name);
      expect(await repository.fetchPurok('mock-barangay-999-purok-0'), isNull);
    });

    test('landmarks exist only in the seed', () async {
      final places = await MockCatalogRepository(db).fetchPlaces();
      expect(places, isNotEmpty);
      expect(places.every((p) => p.latitude.abs() > 0), isTrue);
      expect(places.map((p) => p.id).toSet(), hasLength(places.length));
    });

    test('no pricing policy is claimed', () async {
      expect(await MockCatalogRepository(db).fetchActivePricingPolicies(),
          isEmpty);
    });
  });

  group('MockVehicleRepository', () {
    test('the whole fleet belongs to the seeded owner', () async {
      final vehicles =
          await MockVehicleRepository(db).fetchVehiclesOwnedBy('any');
      expect(vehicles.length, db.ownerVehicles.length);
      expect(vehicles.every((v) => v.ownerProfileId == db.vehicleOwner.id),
          isTrue);
      expect(vehicles.every((v) => v.pricePerDayCentavos > 0), isTrue);
    });

    test('the seed status vocabulary survives into the record layer', () async {
      final repository = MockVehicleRepository(db);
      final listed = await repository.fetchListedVehicles();
      expect(listed, isNotEmpty);
      expect(listed.every((v) => v.isListed), isTrue);

      const seedToToken = {
        'Listed': 'active',
        'Rented': 'rented',
        'Maintenance': 'maintenance',
      };
      final all = await repository.fetchVehiclesOwnedBy('any');
      expect(all.length, db.ownerVehicles.length);
      for (var i = 0; i < all.length; i++) {
        expect(all[i].status, seedToToken[db.ownerVehicles[i].status]);
      }

      // A vehicle that is out on rental is still a listing, only not free right
      // now; one in maintenance is off the catalogue entirely.
      expect(all.where((v) => v.status == 'rented').every((v) => v.isListed),
          isTrue);
      expect(
        all.where((v) => v.status == 'maintenance').every((v) => !v.isListed),
          isTrue,
        reason: 'the seed should cover this state',
      );
      expect(listed.map((v) => v.id).toSet(),
          all.where((v) => v.isListed).map((v) => v.id).toSet());
    });

    test('documents are fleet paperwork, not per-vehicle rows', () async {
      final documents =
          await MockVehicleRepository(db).fetchDocuments(['RV001']);
      expect(documents.length, db.vehicleDocuments.length);
      expect(documents.every((d) => d.vehicleId == null), isTrue);
      expect(documents.every((d) => d.status == 'approved'), isTrue);
      expect(await MockVehicleRepository(db).fetchDocuments(const []), isEmpty);
    });

    test('an unknown vehicle is null, not a substitute', () async {
      expect(await MockVehicleRepository(db).fetchVehicle('RV999'), isNull);
      expect(await MockVehicleRepository(db).fetchVehicle('RV001'), isNotNull);
    });
  });

  group('MockRideRepository', () {
    test('the signed-in passenger sees requests and history', () async {
      final records =
          await MockRideRepository(db).fetchRidesForPassenger(db.passenger.id);
      expect(records, isNotEmpty);
      expect(records.map((r) => r.id).toSet(), hasLength(records.length));
      expect(records.every((r) => r.serviceAreaId == 'sa-tandag-city'), isTrue);
      // Seeded fares are centavos integers, so a peso amount would show up as
      // ₱65.00 instead of ₱650.00.
      expect(records.where((r) => r.fareCentavos > 0), isNotEmpty);
    });

    test('another profile only gets its own requests', () async {
      final mine = await MockRideRepository(db).fetchRidesForPassenger('P002');
      expect(mine.every((r) => r.passengerId == 'P002'), isTrue);
    });

    test('the open pool holds only unassigned rides', () async {
      final pool = await MockRideRepository(db).fetchOpenPool('sa-tandag-city');
      for (final ride in pool) {
        expect(ride.status,
            anyOf(RideStatus.searching, RideStatus.awaitingAcceptance));
      }
      expect(
        pool.map((r) => r.id).toSet(),
        db.rideRequests
            .where((r) =>
                r.status == RideStatus.searching ||
                r.status == RideStatus.awaitingAcceptance)
            .map((r) => r.id)
            .toSet(),
      );
    });

    test('limit truncates without dropping the head', () async {
      final all = await MockRideRepository(db).fetchRidesForRider(db.earner.id);
      final few = await MockRideRepository(db)
          .fetchRidesForRider(db.earner.id, limit: 2);
      expect(few.map((r) => r.id), all.take(2).map((r) => r.id));
    });

    test('the seed has no transition log or ratings', () async {
      final repository = MockRideRepository(db);
      final ride =
          (await repository.fetchRidesForPassenger(db.passenger.id)).first;
      expect(await repository.fetchStatusEvents(ride.id), isEmpty);
      expect(await repository.fetchRatingsForRide(ride.id), isEmpty);
    });
  });

  group('MockRentalRepository', () {
    test('the renter sees their rental history', () async {
      final records =
          await MockRentalRepository(db).fetchRentalsByRenter(db.passenger.id);
      expect(records.length, db.rentalHistory.length);
      expect(records.every((r) => r.vehicleName != null), isTrue);
      expect(records.every((r) => r.totalFareCentavos > 0), isTrue);
      expect(
          await MockRentalRepository(db).fetchRentalsByRenter('P002'), isEmpty);
    });

    test('the owner sees pending requests plus completed rentals', () async {
      final records = await MockRentalRepository(db)
          .fetchRentalsByOwner(db.vehicleOwner.id);
      expect(records.length,
          db.ownerBookingRequests.length + db.rentalHistory.length);
      expect(records.any((r) => r.status.name == 'requested'), isTrue);
    });

    test('booking requests keep their window and vehicle', () async {
      final request = db.ownerBookingRequests.first;
      final record = await MockRentalRepository(db).fetchRental(request.id);
      expect(record!.vehicleName, request.vehicleName);
      expect(record.totalFareCentavos, request.totalFare);
      expect(record.startAt, request.startAt);
      expect(record.vehicleId, request.vehicleId);
      expect(await MockRentalRepository(db).fetchRental('rb-missing'), isNull);
    });
  });

  group('MockPasuyoRepository', () {
    test('open feed and category filter agree with the seed', () async {
      final repository = MockPasuyoRepository(db);
      final open = await repository.fetchOpenFeed('sa-tandag-city');
      expect(open.map((r) => r.id).toSet(),
          db.pasuyoTasks.where((t) => t.isOpen).map((t) => t.id).toSet());
      expect(open.every((r) => r.isOpen), isTrue);

      final groceries = await repository.fetchOpenFeed('sa-tandag-city',
          category: PasuyoCategory.groceries);
      expect(groceries.every((r) => r.category == PasuyoCategory.groceries),
          isTrue);
    });

    test('items become named line rows', () async {
      final task = db.pasuyoTasks.firstWhere((t) => t.items.isNotEmpty);
      final record = await MockPasuyoRepository(db).fetchRequest(task.id);
      expect(record!.items.map((i) => i.name), task.items);
      expect(record.items.every((i) => i.serviceRequestId == task.id), isTrue);
      expect(record.budgetCentavos, task.budget);
      expect(record.paymentMethod, 'cash');
    });

    test('participant names come from the seeded profiles', () async {
      final task = db.pasuyoTasks.firstWhere(
          (t) => t.helperId != null && db.earners.containsKey(t.helperId));
      final record = await MockPasuyoRepository(db).fetchRequest(task.id);
      expect(record!.customerName, db.passengers[task.customerId]?.name);
      expect(record.providerName, db.earners[task.helperId!]?.name);
      expect(record.providerId, task.helperId);
    });

    test('status reads by customer and provider', () async {
      final repository = MockPasuyoRepository(db);
      final task = db.pasuyoTasks.firstWhere(
          (t) => t.helperId != null && db.earners.containsKey(t.helperId));
      final byCustomer =
          await repository.fetchRequestsByCustomer(task.customerId);
      expect(byCustomer.map((r) => r.id), contains(task.id));
      expect(byCustomer.every((r) => r.customerId == task.customerId), isTrue);
      final byProvider =
          await repository.fetchRequestsByProvider(task.helperId!);
      expect(byProvider.map((r) => r.id), contains(task.id));
      expect(await repository.fetchRequest('sr-missing'), isNull);
      expect(await repository.fetchStatusEvents(task.id), isEmpty);
    });

    test('delivered errands are not open', () async {
      final delivered = db.pasuyoTasks
          .where((t) => t.status == PasuyoStatus.delivered)
          .map((t) => t.id)
          .toSet();
      final open =
          await MockPasuyoRepository(db).fetchOpenFeed('sa-tandag-city');
      expect(open.map((r) => r.id).toSet().intersection(delivered), isEmpty);
    });
  });

  group('MockNotificationRepository', () {
    test('the feed mirrors the seeded labels and their real times', () async {
      final repository = MockNotificationRepository(db);
      final records = await repository.fetchNotifications(db.passenger.id);
      expect(records.length, db.passengerNotifications.length);
      for (var i = 0; i < records.length; i++) {
        final seed = db.passengerNotifications[i];
        expect(records[i].id, seed.id);
        expect(records[i].title, seed.title);
        expect(records[i].isRead, seed.read);
        expect(records[i].createdAt, seed.createdAt);
      }
    });

    test('unread count matches the seed', () async {
      final repository = MockNotificationRepository(db);
      expect(await repository.countUnread(db.passenger.id),
          db.passengerNotifications.where((n) => !n.read).length);
      expect(await repository.countUnread('unknown-profile'), 0);
      expect(await repository.fetchNotifications('unknown-profile'), isEmpty);
    });

    test('limit applies', () async {
      expect(
          await MockNotificationRepository(db)
              .fetchNotifications(db.earner.id, limit: 1),
          hasLength(1));
    });
  });

  group('MockWalletRepository', () {
    test('each seeded profile has one active wallet', () async {
      final repository = MockWalletRepository(db);
      final accounts = await repository.fetchWalletAccounts(db.passenger.id);
      expect(accounts, hasLength(1));
      expect(accounts.single.accountType, 'passenger');
      expect(accounts.single.isActive, isTrue);
      expect(accounts.single.balanceCentavos, db.passengerWalletBalance);
      expect(await repository.fetchBalanceCentavos(db.earner.id),
          db.earnerWalletBalance);
      expect(await repository.fetchBalanceCentavos(db.vehicleOwner.id),
          db.ownerWalletBalance);
    });

    test('an unknown profile is broke rather than guessed', () async {
      final repository = MockWalletRepository(db);
      expect(await repository.fetchBalanceCentavos('ghost'), 0);
      expect(await repository.fetchWalletAccounts('ghost'), isEmpty);
    });

    test('history derives direction from the seeded sign', () async {
      final repository = MockWalletRepository(db);
      final entries = await repository.fetchTransactions(db.passenger.id);
      expect(entries.length, db.passengerTransactions.length);
      for (var i = 0; i < entries.length; i++) {
        final seed = db.passengerTransactions[i];
        expect(entries[i].isCredit, seed.isPositive);
        expect(entries[i].amountCentavos, seed.amount);
        expect(entries[i].description, seed.title);
        expect(entries[i].walletAccountId, 'mock-wallet-${db.passenger.id}');
        // The seed stores per-row amounts only, so no running balance is
        // reconstructed here.
        expect(entries[i].balanceAfterCentavos, isNull);
      }
    });

    test('settlements and remittances have no seeded equivalent', () async {
      final repository = MockWalletRepository(db);
      expect(await repository.fetchSettlements(db.earner.id), isEmpty);
      await expectLater(
        repository.fetchFeeRemittances(db.earner.id),
        throwsA(predicate((Object? error) =>
            error is RepositoryFailure &&
            error.kind == RepositoryFailureKind.unsupported)),
      );
    });
  });

  group('registry selection', () {
    test('the mock registry names its source', () {
      final registry = RepositoryRegistry.mock();
      expect(registry.isSupabaseBacked, isFalse);
      expect(registry.description, 'local mock seed');
    });

    test('the default build does not silently switch to Supabase', () {
      // `SURGO_DATA_SOURCE` is the only lever; a build that asks for the
      // database must not quietly end up on the seed.
      expect(DataSourceConfig.usesSupabase, isFalse);
      expect(buildRepositoryRegistry(supabaseReady: true).isSupabaseBacked,
          DataSourceConfig.usesSupabase);
      expect(buildRepositoryRegistry(supabaseReady: false).description,
          'local mock seed');
    });
  });
}
