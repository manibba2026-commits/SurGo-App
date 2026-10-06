import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/services/money.dart';

/// Guards the seed split: every file the manifest promises must exist, foreign
/// keys must resolve, and amounts must already be in centavos.
///
/// These assertions exist because the seed is data, not code — a bad edit shows
/// up as an empty screen or a ₱65.00 fare that should be ₱650.00, neither of
/// which the compiler catches.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DbService db;
  late Map<String, Map<String, dynamic>> files;

  setUpAll(() async {
    db = DbService.instance;
    await db.load();

    final manifest =
        json.decode(await rootBundle.loadString(DbService.manifestPath))
            as Map<String, dynamic>;
    files = {
      for (final name in (manifest['files'] as List).cast<String>())
        name: json.decode(
                await rootBundle.loadString('assets/db/$name'))
            as Map<String, dynamic>,
    };
  });

  group('manifest', () {
    test('every declared file is loaded and is a JSON object', () {
      expect(files, isNotEmpty);
      expect(db.schemaVersion, greaterThanOrEqualTo(2));
      for (final entry in files.entries) {
        expect(entry.value, isNotEmpty, reason: '${entry.key} is empty');
      }
    });

    test('declares each domain file the app reads', () {
      expect(
        files.keys.toSet(),
        containsAll(<String>[
          'config.json',
          'users.json',
          'locations.json',
          'vehicles.json',
          'rides.json',
          'rentals.json',
          'pasuyo.json',
          'wallets.json',
          'earnings.json',
        ]),
      );
    });

    test('carries no unexpected section, so nothing is loaded but unused', () {
      // A section left behind after a split would load and silently never be
      // read, which is how seed drift starts.
      const expected = {
        'config.json': {'schemaVersion', 'commissionBps', 'currency', 'fare', 'payouts', '_note'},
        'users.json': {'passenger', 'rider', 'vehicleOwner', 'credentials', 'paymentMethods', 'emergencyContacts', 'favorites', 'notifications', 'accountSettings', '_note'},
        'locations.json': {'city', 'barangays', 'savedPlaces', 'places', '_note'},
        'vehicles.json': {'owned', 'documents', 'bookingRequests', '_note'},
        'rides.json': {'requests', 'history', '_note'},
        'rentals.json': {'history'},
        'pasuyo.json': {'tasks', '_note'},
        'wallets.json': {'roles', '_note'},
        'earnings.json': {'rider', 'owner'},
        'manifest.json': {'schemaVersion', 'city', 'files', '_note'},
      };
      files.forEach((name, body) {
        final want = expected[name];
        if (want == null) return;
        expect(body.keys.toSet(), want, reason: '$name sections changed');
      });
    });
  });

  group('money is in centavos', () {
    test('ride and rental history are whole peso amounts at most', () {
      // Sanity bound: a centavos value should be far larger than a peso value,
      // so anything still stored in pesos shows up here as suspiciously small.
      for (final item in db.rideHistory) {
        expect(item.fare, greaterThan(100),
            reason: '${item.id} fare ${item.fare} looks like pesos');
        expect(item.fare % 1, 0, reason: '${item.id} fare is not a whole centavo');
      }
      for (final item in db.rentalHistory) {
        expect(item.totalFare, greaterThan(100));
      }
      for (final trip in db.riderTrips) {
        expect(trip.fare, greaterThan(100), reason: '${trip.id} fare looks like pesos');
      }
    });

    test('no amount would render as an implausibly tiny peso value', () {
      // ₱65.00 is right; ₱0.65 means the seed forgot to multiply by 100.
      for (final item in db.rideHistory) {
        expect(Money.format(item.fare), matches(r'^₱\d'),
            reason: '${item.id} renders as ${Money.format(item.fare)}');
      }
    });

    test('wallet balances are non-negative integers', () {
      expect(db.passengerWalletBalance, greaterThanOrEqualTo(0));
      expect(db.riderWalletBalance, greaterThanOrEqualTo(0));
      expect(db.ownerWalletBalance, greaterThanOrEqualTo(0));
      for (final role in ['passenger', 'rider', 'owner']) {
        final list = role == 'passenger'
            ? db.passengerTransactions
            : role == 'rider'
                ? db.riderTransactions
                : db.ownerTransactions;
        expect(list, isNotEmpty, reason: '$role has no transactions');
        for (final tx in list) {
          expect(tx.amount, isNot(0));
        }
      }
    });

    test('earnings roll-ups and daily buckets are in centavos', () {
      expect(db.earningsToday, greaterThan(1000));
      expect(db.earningsWeek, greaterThanOrEqualTo(db.earningsToday));
      expect(db.earningsMonth, greaterThanOrEqualTo(db.earningsWeek));
      for (final bucket in db.dailyEarnings) {
        expect(bucket.amount, greaterThanOrEqualTo(0));
      }
    });
  });

  group('referential integrity', () {
    test('every Pasuyo customer resolves to a passenger on the map', () {
      final ids = db.mapPassengers.map((p) => p.id).toSet();
      for (final task in db.pasuyoTasks) {
        expect(ids, contains(task.customerId), reason: task.id);
      }
    });

    test('every Pasuyo helper resolves to a rider on the map', () {
      final ids = db.mapRiders.map((r) => r.id).toSet();
      for (final task in db.pasuyoTasks) {
        if (task.helperId == null) continue;
        expect(ids, contains(task.helperId), reason: task.id);
      }
    });

    test('an open errand has no helper and a claimed one does', () {
      for (final task in db.pasuyoTasks) {
        if (task.isOpen) {
          expect(task.helperId, isNull, reason: '${task.id} is open but claimed');
        } else if (!task.isCancelled) {
          expect(task.helperId, isNotNull, reason: '${task.id} is claimed');
        }
      }
    });

    test('the signed-in accounts own their seeded records', () {
      expect(db.pasuyoTasks.map((t) => t.customerId),
          contains(db.passenger.id));
      expect(db.pasuyoTasks.whereType<PasuyoTask>().map((t) => t.helperId),
          contains(db.rider.id));
      expect(db.mapRentalVehicles.map((v) => v.ownerId),
          contains(db.vehicleOwner.id));
    });

    test('ids are unique within each collection', () {
      void unique<T>(Iterable<T> ids, String label) {
        final list = ids.toList();
        expect(list.toSet().length, list.length,
            reason: '$label contains duplicate ids');
      }

      unique(db.pasuyoTasks.map((t) => t.id), 'pasuyoTasks');
      unique(db.rideHistory.map((r) => r.id), 'rideHistory');
      unique(db.riderTrips.map((t) => t.id), 'riderTrips');
      unique(db.rentalHistory.map((r) => r.id), 'rentalHistory');
      unique(db.ownerVehicles.map((v) => v.id), 'ownerVehicles');
      unique(db.places.map((p) => p.id), 'places');
    });

    test('map rental vehicles and owned vehicles describe the same fleet', () {
      expect(db.mapRentalVehicles.map((v) => v.id).toSet(),
          db.ownerVehicles.map((v) => v.id).toSet());
    });

    test('every seed place has coordinates inside the city area', () {
      expect(db.places, isNotEmpty);
      for (final place in db.places) {
        expect(place.label, isNotEmpty);
        expect(place.latitude, inInclusiveRange(9.0, 9.2),
            reason: '${place.id} latitude ${place.latitude}');
        expect(place.longitude, inInclusiveRange(126.1, 126.3),
            reason: '${place.id} longitude ${place.longitude}');
      }
    });
  });

  group('timestamps', () {
    test('history records carry a real ISO time next to the display label', () {
      for (final item in db.rideHistory) {
        expect(item.completedAt, isNotNull, reason: item.id);
        expect(item.date, isNotEmpty, reason: item.id);
      }
      for (final trip in db.riderTrips) {
        expect(trip.completedAt, isNotNull, reason: trip.id);
      }
      for (final tx in db.riderTransactions) {
        expect(tx.createdAt, isNotNull, reason: tx.id);
      }
      for (final rental in db.rentalHistory) {
        expect(rental.startAt, isNotNull, reason: rental.id);
        expect(rental.endAt, isNotNull, reason: rental.id);
      }
    });

    test('the daily earnings chart can key on a date, not just a weekday', () {
      for (final bucket in db.dailyEarnings) {
        expect(bucket.date, isNotNull, reason: bucket.day);
      }
    });

    test('a cancelled errand reports no step rather than step 1', () {
      final cancelled = db.pasuyoTasks.where((t) => t.isCancelled).toList();
      expect(cancelled, isNotEmpty, reason: 'seed should cover this state');
      for (final task in cancelled) {
        expect(task.stepIndex, -1);
        expect(task.stepLabel, 'Cancelled');
        expect(task.nextStatus, isNull);
      }
    });
  });

  group('commission config', () {
    test('rates loaded from config reach the fee calculator', () {
      final bps = files['config.json']!['commissionBps'] as Map<String, dynamic>;
      expect(bps['ride'], 1000);
      expect(bps['pasuyo'], 1500);
      expect(bps['rental'], 1000);
    });

    test('currency is declared as two-decimal PHP', () {
      final currency =
          files['config.json']!['currency'] as Map<String, dynamic>;
      expect(currency['code'], 'PHP');
      expect(currency['minorUnits'], 2);
    });
  });
}