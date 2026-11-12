import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/geo.dart';
import 'package:surgo/state/ride_match.dart';
import 'package:surgo/state/ride_status.dart';

/// Exercises the ride lifecycle from the passenger's side: create, propose,
/// confirm, rider accepts, trip runs, trip completes.
///
/// Two things are asserted throughout rather than just at the end. First, that
/// each step lands on the state the enum says it should, so the ladder cannot
/// quietly reorder itself. Second, that the illegal jumps are refused, since a
/// guard nobody tests is a guard that does not exist.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  late List<_RequestState> saved;
  late List<RideRequestItem> savedRideRequests;
  late int originalCount;
  late int wallet;
  late int today;
  late int week;
  late int month;
  late List<int> daily;
  late List<WalletTransaction> savedTransactions;
  late RideRequestItem? savedRequest;
  late RideMatchProposal? savedProposal;
  late RideRequestItem? savedActive;
  late List<RiderTripItem> savedTrips;
  late Map<String, int> notificationCounts;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    saved = db.rideRequests.map(_RequestState.of).toList();
    savedRideRequests = List.of(db.rideRequests);
    originalCount = db.rideRequests.length;
    savedTrips = List.of(db.riderTrips);
    wallet = db.earnerWalletBalance;
    today = db.earningsToday;
    week = db.earningsWeek;
    month = db.earningsMonth;
    daily = db.dailyEarnings.map((d) => d.amount).toList();
    savedTransactions = List.of(db.earnerTransactions);
    savedRequest = state.myRideRequest;
    savedProposal = state.rideProposal;
    savedActive = state.activeRide;
    notificationCounts = {
      for (final entry in db.notificationsByUser.entries)
        entry.key: entry.value.length,
    };
  });

  tearDown(() {
    // Restore the exact collections rather than trimming ranges: requests,
    // trips and transactions are all inserted at index 0, so cutting from the
    // tail would remove seeded rows and keep the test's.
    db.rideRequests
      ..clear()
      ..addAll(savedRideRequests);
    for (var i = 0; i < saved.length; i++) {
      saved[i].applyTo(db.rideRequests[i]);
    }
    db.riderTrips
      ..clear()
      ..addAll(savedTrips);
    db.earnerWalletBalance = wallet;
    db.earningsToday = today;
    db.earningsWeek = week;
    db.earningsMonth = month;
    for (var i = 0; i < db.dailyEarnings.length; i++) {
      db.dailyEarnings[i].amount = daily[i];
    }
    db.earnerTransactions
      ..clear()
      ..addAll(savedTransactions);
    for (final entry in notificationCounts.entries) {
      final feed = db.notificationsByUser[entry.key];
      if (feed != null && feed.length > entry.value) {
        feed.removeRange(entry.value, feed.length);
      }
    }
    for (final key in db.notificationsByUser.keys.toList()) {
      if (!notificationCounts.containsKey(key)) {
        db.notificationsByUser.remove(key);
      }
    }
    state.myRideRequest = savedRequest;
    state.rideProposal = savedProposal;
    state.activeRide = savedActive;
    state.activeRideBreakdown = null;
    state.lastRideBreakdown = null;
  });

  /// A request created through the real booking path, so the tests exercise the
  /// same state the booking screen produces rather than a hand-built fixture.
  RideRequestItem newRequest() {
    state.setPickup('SM Terminal');
    state.setDestination('Tandag Public Hall');
    return state.createRideRequest();
  }

  group('creating a request', () {
    test('persists it, so the trip can be traced back afterwards', () {
      final request = newRequest();

      expect(db.rideRequests.first, same(request));
      expect(state.myRideRequest, same(request));
      expect(request.status, RideStatus.searching);
      expect(request.riderId, isNull);
    });

    test('starts in searching, not accepted: nobody has agreed yet', () {
      final request = newRequest();

      expect(request.status, RideStatus.searching);
      expect(request.status.allowsChat, isFalse);
      expect(state.canChatOnRide, isFalse);
    });

    test('resolves the pickup label to real coordinates', () {
      final request = newRequest();

      expect(request.pickupLatitude, isNotNull);
      expect(request.pickupLongitude, isNotNull);
      expect(request.dropoffLatitude, isNotNull);
    });

    test('a repeated submission reuses the one live request', () {
      final first = newRequest();
      final second = state.createRideRequest();

      expect(second, same(first));
      expect(db.rideRequests.length, originalCount + 1);
      expect(state.myRideRequest, same(first));
    });

    test('a request after cancellation receives a distinct id', () {
      final first = newRequest();
      state.cancelRideRequest();
      final second = state.createRideRequest();

      expect(second.id, isNot(first.id));
    });
  });

  group('proposing a rider', () {
    test('picks an available, verified rider and holds them as a proposal', () {
      final request = newRequest();

      final outcome = state.proposeRider(request);

      expect(outcome, MatchOutcome.proposed);
      final proposal = state.rideProposal!;
      expect(proposal.rider.available, isTrue);
      expect(proposal.rider.verified, isTrue);
      expect(proposal.fare, request.fare);
      expect(proposal.etaMinutes, greaterThanOrEqualTo(1));
      // Still searching: proposing is not the same as being matched.
      expect(request.status, RideStatus.searching);
      expect(request.riderId, isNull);
    });

    test('is deterministic: the same request proposes the same rider', () {
      final a = newRequest();
      final first = state.proposeRider(a);
      final firstRider = state.rideProposal!.rider.id;
      state.declineRideMatch();

      final b = newRequest();
      final second = state.proposeRider(b);

      expect(first, MatchOutcome.proposed);
      expect(second, MatchOutcome.proposed);
      expect(state.rideProposal!.rider.id, firstRider);
    });

    test('proposes the nearest rider, not the highest rated one', () {
      final request = newRequest();
      state.proposeRider(request);

      final proposal = state.rideProposal!;
      final distance = _distanceTo(request, proposal.rider);

      if (distance == null) {
        // No coordinates on this pickup: ranking cannot be distance-based, and
        // the contract is then rating-then-id, which determinism already covers.
        return;
      }
      // Only riders the search may actually offer: available, verified, and
      // not the signed-in passenger riding on their own account.
      final selfRiderId = state.currentAccount?.riderId;
      final selfNames = {
        db.passenger.name.toLowerCase(),
        request.passengerName.trim().toLowerCase(),
      };
      for (final r in db.mapRiders.where((r) =>
          r.available &&
          r.verified &&
          r.id != selfRiderId &&
          !selfNames.contains(r.name.toLowerCase()))) {
        final other = _distanceTo(request, r);
        if (other == null) continue;
        expect(distance, lessThanOrEqualTo(other));
      }
    });

    test('offers the fleet regardless of vehicle type', () {
      // The vehicle-selection step is gone: the passenger picks a rider, so a
      // request recorded as one type must not be starved of another type.
      final request = newRequest();
      request.vehicleId = 'Boat';

      expect(state.proposeRider(request), MatchOutcome.proposed);
      final eligible = db.mapRiders.where((r) => r.available && r.verified);
      if (eligible.isNotEmpty) {
        expect(eligible.map((r) => r.id), contains(state.rideProposal!.rider.id));
      }
    });

    test('walks down the ranking as riders are excluded', () {
      final request = newRequest();
      final seen = <String>{};

      var outcome = state.proposeRider(request);
      while (outcome == MatchOutcome.proposed) {
        final id = state.rideProposal!.rider.id;
        // Find Another must never show the same rider twice.
        expect(seen, isNot(contains(id)));
        seen.add(id);
        outcome = state.proposeRider(request, excludeRiderIds: seen);
      }

      expect(outcome, MatchOutcome.noRidersAvailable);
      final eligible = db.mapRiders.where((r) => r.available && r.verified).length;
      expect(seen.length, lessThanOrEqualTo(eligible));
      // Exhausting the fleet clears the last proposal rather than leaving a
      // rider on screen who is no longer the answer to the search.
      expect(state.rideProposal, isNull);
    });

    test('refuses to propose a second rider for the same request', () {
      final request = newRequest();
      expect(state.proposeRider(request), MatchOutcome.proposed);
      final chosen = state.rideProposal!.rider.id;

      // Confirming, then trying to match again, must not silently replace the
      // rider the passenger is about to accept.
      expect(state.confirmRideMatch(), isTrue);
      final outcome = state.proposeRider(request);

      expect(outcome, MatchOutcome.noRidersAvailable);
      expect(request.riderId, chosen);
    });

    test('never proposes the passenger as their own rider', () {
      final request = newRequest();

      state.proposeRider(request);

      final rider = state.rideProposal!.rider;
      // MapRider ids (R00x) and profile ids (P00x) live in different namespaces,
      // so the self check has to go through the account's linked rider id and
      // the name, not by comparing ids across the two.
      final selfRiderId = state.currentAccount?.riderId;
      if (selfRiderId != null) expect(rider.id, isNot(selfRiderId));
      expect(rider.name.toLowerCase(), isNot(db.passenger.name.toLowerCase()));
      expect(rider.name.toLowerCase(),
          isNot(request.passengerName.trim().toLowerCase()));
    });

    test('never proposes a rider who is marked unavailable', () {
      final request = newRequest();

      state.proposeRider(request);

      expect(state.rideProposal!.rider.available, isTrue);
    });

    test('never proposes the rider already committed to another trip', () {
      final first = newRequest();
      state.proposeRider(first);
      final busy = state.rideProposal!.rider.id;
      state.confirmRideMatch();
      state.riderAccepts(first);

      final second = newRequest();
      state.proposeRider(second);

      // The accepted trip holds its rider, so a second request must be offered
      // someone else or nobody.
      if (state.rideProposal != null) {
        expect(state.rideProposal!.rider.id, isNot(busy));
      }
    });
  });

  group('confirming the match', () {
    test('assigns the rider and moves to awaiting acceptance', () {
      final request = newRequest();
      final riderId = (state.proposeRider(request), state.rideProposal!.rider.id);

      expect(state.confirmRideMatch(), isTrue);
      expect(request.status, RideStatus.awaitingAcceptance);
      expect(request.riderId, riderId.$2);
      // Cleared: the proposal was acted on, so nothing should still offer it.
      expect(state.rideProposal, isNull);
    });

    test('does not start the trip: the rider has not agreed', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();

      expect(request.status, RideStatus.awaitingAcceptance);
      expect(state.activeRide, isNull);
      expect(state.canChatOnRide, isFalse);
    });

    test('refuses without a proposal to confirm', () {
      newRequest();

      expect(state.confirmRideMatch(), isFalse);
      expect(state.myRideRequest!.status, RideStatus.searching);
    });

    test('sends the request to the selected rider and tells both sides', () {
      final request = newRequest();
      state.proposeRider(request);
      final rider = state.rideProposal!.rider;
      final passengerFeedBefore = db.passengerNotifications.length;

      expect(state.confirmRideMatch(), isTrue);

      // Addressed to the chosen rider, not broadcast, so another rider cannot
      // answer a request they were not offered.
      expect(request.riderId, rider.id);
      expect(state.activeRide, isNull,
          reason: 'selecting a rider is a request, not an accepted trip');

      final riderFeed = db.notificationsByUser[rider.id];
      expect(riderFeed, isNotNull);
      expect(riderFeed!.first.title, 'New ride request');
      expect(riderFeed.first.body, contains(request.pickup));
      expect(db.passengerNotifications.length, passengerFeedBefore + 1);
      expect(db.passengerNotifications.first.title,
          'Request sent to ${rider.name}');
    });
  });

  group('declining a proposal', () {
    test('returns the request to searching and forgets the rider', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();

      state.declineRideMatch();

      expect(request.status, RideStatus.searching);
      expect(request.riderId, isNull);
      // The request returns to matching rather than being cancelled, so the
      // passenger's pickup and destination survive for the next rider.
      expect(request.pickup, 'SM Terminal');
      expect(request.dropoff, 'Tandag Public Hall');
      expect(state.rideProposal, isNull);
    });

    test('lets a different rider be proposed afterwards', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();
      state.declineRideMatch();

      expect(state.proposeRider(request), MatchOutcome.proposed);
      expect(state.rideProposal, isNotNull);
    });
  });

  group('the rider inbox', () {
    RideRequestItem inboxRequest({
      required String id,
      String? passengerId,
      String? riderId,
    }) =>
        RideRequestItem(
          id: id,
          passengerId: passengerId,
          riderId: riderId,
          passengerName: 'Someone Else',
          passengerInitials: 'SE',
          passengerRating: 4.4,
          pickupBarangay: 'Bongtud',
          pickupPurok: '',
          pickup: 'Bongtud',
          dropoffBarangay: 'Tandag',
          dropoffPurok: '',
          dropoff: 'Public Market',
          distanceKm: 2.4,
          etaMinutes: 7,
          fare: 3000,
          paymentMethod: 'Cash',
          note: '',
          requestedAt: 'Just now',
        );

    test('shows open requests and ones addressed to this rider', () {
      final open = inboxRequest(id: 'rq-open', passengerId: 'P002');
      final addressed = inboxRequest(
        id: 'rq-addressed',
        passengerId: 'P002',
        riderId: db.earner.id,
      );
      final otherRiders =
          inboxRequest(id: 'rq-other', passengerId: 'P002', riderId: 'R999');
      db.rideRequests.addAll([open, addressed, otherRiders]);

      final inbox = state.pendingRequests;

      expect(inbox, contains(open));
      expect(inbox, contains(addressed));
      expect(inbox, isNot(contains(otherRiders)),
          reason: 'a request sent to another rider is not this rider\'s to answer');
    });

    test('hides the account\'s own passenger request', () {
      final own = newRequest();

      // A rider cannot accept a trip they placed as a passenger.
      expect(state.pendingRequests, isNot(contains(own)));
    });

    test('can accept a request addressed to this rider', () {
      final request = inboxRequest(
        id: 'rq-mine',
        passengerId: 'P002',
        riderId: db.earner.id,
      )..status = RideStatus.awaitingAcceptance;
      db.rideRequests.add(request);

      state.respondToRequest(request, accepted: true);

      expect(request.status, RideStatus.accepted);
      expect(state.activeRide, same(request));
      expect(db.rideRequests, isNot(contains(request)),
          reason: 'an answered request leaves the incoming list');
      expect(db.passengerNotifications.first.title, contains('accepted'));
    });

    test('can decline a request addressed to this rider', () {
      final request = inboxRequest(
        id: 'rq-declined',
        passengerId: 'P002',
        riderId: db.earner.id,
      )..status = RideStatus.awaitingAcceptance;
      db.rideRequests.add(request);

      state.respondToRequest(request, accepted: false);

      expect(request.status, RideStatus.cancelled);
      expect(state.activeRide, isNull);
      expect(db.rideRequests, isNot(contains(request)));
      expect(db.passengerNotifications.first.title, contains('declined'));
    });

    test('cannot answer a request addressed to a different rider', () {
      final request = inboxRequest(
        id: 'rq-theirs',
        passengerId: 'P002',
        riderId: 'R999',
      )..status = RideStatus.awaitingAcceptance;
      db.rideRequests.add(request);

      state.respondToRequest(request, accepted: true);

      expect(request.status, RideStatus.awaitingAcceptance);
      expect(state.activeRide, isNull,
          reason: 'picking a rider does not let anyone else accept for them');
      expect(db.rideRequests, contains(request));
    });
  });

  group('the rider accepting', () {
    test('starts the trip and unlocks chat', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();

      state.riderAccepts(request);

      expect(request.status, RideStatus.accepted);
      expect(state.activeRide, same(request));
      expect(state.canChatOnRide, isTrue);
      expect(state.activeRideBreakdown, isNotNull);
      final breakdown = state.activeRideBreakdown!;
      expect(breakdown.providerGets, request.fare,
          reason: 'the rider keeps the whole agreed fare');
      expect(breakdown.surgoKeeps, greaterThan(0),
          reason: 'the customer also pays the platform fee');
      expect(breakdown.customerPays, request.fare + breakdown.surgoKeeps);
    });

    test('is refused before the passenger confirms', () {
      final request = newRequest();
      state.proposeRider(request);

      // The request is still searching: there is no assignment to accept, so
      // this must not silently become a booking.
      state.riderAccepts(request);

      expect(request.status, RideStatus.searching);
      expect(state.activeRide, isNull);
    });
  });

  group('running the trip', () {
    RideRequestItem acceptedTrip() {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();
      state.riderAccepts(request);
      return request;
    }

    test('walks accepted -> heading -> arrived -> in progress', () {
      final request = acceptedTrip();

      state.advanceRide();
      expect(request.status, RideStatus.headingToPickup);
      state.advanceRide();
      expect(request.status, RideStatus.arrived);
      state.advanceRide();
      expect(request.status, RideStatus.inProgress);
    });

    test('cannot skip a step', () {
      final request = acceptedTrip();

      // Going straight from accepted to in progress would pay for a trip the
      // rider never drove, so the one-step advance must refuse it.
      state.advanceRide();
      state.advanceRide();
      expect(request.status, RideStatus.arrived);
      expect(request.canAdvanceTo(RideStatus.inProgress), isTrue);
      expect(request.canAdvanceTo(RideStatus.completed), isFalse);
    });

    test('stays open for chat for the whole trip', () {
      final request = acceptedTrip();

      for (var i = 0; i < 3; i++) {
        state.advanceRide();
        expect(request.status.allowsChat, isTrue,
            reason: 'chat closes once the trip is over, not while it runs');
      }
      expect(state.canChatOnRide, isTrue);
    });

    test('completing pays out once and closes the trip', () {
      final request = acceptedTrip();
      state.advanceRide();
      state.advanceRide();
      state.advanceRide();
      final walletBefore = db.earnerWalletBalance;

      state.completeActiveRide();

      expect(request.status, RideStatus.completed);
      expect(state.activeRide, isNull);
      expect(db.earnerWalletBalance, greaterThan(walletBefore));
      expect(db.riderTrips.length, savedTrips.length + 1);
      expect(request.status.allowsChat, isFalse);
    });

    test('completing a trip that never started pays nothing', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();
      state.riderAccepts(request);
      final walletBefore = db.earnerWalletBalance;

      // Still accepted: no ride, no pay. This guard is the whole reason
      // completeActiveRide checks the status before crediting anything.
      state.completeActiveRide();

      expect(request.status, RideStatus.accepted);
      expect(db.earnerWalletBalance, walletBefore);
      expect(db.riderTrips.length, savedTrips.length);
      expect(state.activeRide, same(request));
    });

    test('completing twice does not pay twice', () {
      acceptedTrip();
      state.advanceRide();
      state.advanceRide();
      state.advanceRide();
      state.completeActiveRide();
      final walletAfter = db.earnerWalletBalance;

      state.completeActiveRide();

      expect(db.earnerWalletBalance, walletAfter);
      expect(db.riderTrips.length, savedTrips.length + 1);
    });

    test('cancelling mid-trip stops the payout', () {
      final request = acceptedTrip();
      state.advanceRide();
      final walletBefore = db.earnerWalletBalance;

      state.cancelActiveRide();

      expect(request.status, RideStatus.cancelled);
      expect(state.activeRide, isNull);
      expect(state.canChatOnRide, isFalse);
      expect(db.earnerWalletBalance, walletBefore);
    });
  });

  group('cancelling a request', () {
    test('removes it and leaves nothing active', () {
      final request = newRequest();

      state.cancelRideRequest();

      expect(state.myRideRequest, isNull);
      expect(state.rideProposal, isNull);
      expect(state.activeRide, isNull);
      expect(db.rideRequests, isNot(contains(request)));
      expect(request.status, RideStatus.cancelled);
    });

    test('is refused once the trip is over', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();
      state.riderAccepts(request);
      state.advanceRide();
      state.advanceRide();
      state.advanceRide();
      state.completeActiveRide();

      state.cancelRideRequest();

      // A completed trip must not be un-completed: terminal means terminal.
      expect(request.status, RideStatus.completed);
    });

    test('does nothing when there is no request', () {
      state.myRideRequest = null;
      state.rideProposal = null;

      state.cancelRideRequest();

      expect(state.myRideRequest, isNull);
    });
  });

  group('haversineKm', () {
    test('is zero for the same point', () {
      final p = const MapPoint(9.0785, 126.2025);

      expect(haversineKm(p, p), closeTo(0, 0.0001));
    });

    test('matches a known short distance across Tandag', () {
      // SM Terminal (9.0825,126.1985) to Tandag Public Hall (9.0705,126.1985):
      // 0.012 degrees of latitude, about 1.33 km.
      final a = const MapPoint(9.0825, 126.1985);
      final b = const MapPoint(9.0705, 126.1985);

      expect(haversineKm(a, b), closeTo(1.334, 0.01));
    });

    test('is symmetric', () {
      final a = const MapPoint(9.0825, 126.1985);
      final b = const MapPoint(9.0689, 126.1927);

      expect(haversineKm(a, b), closeTo(haversineKm(b, a), 0.0001));
    });
  });

  group('ride status ladder', () {
    test('every non-terminal state has exactly one successor', () {
      for (final s in RideStatus.values) {
        if (s.isTerminal) {
          expect(s.next, isNull, reason: '$s is terminal');
        } else {
          expect(s.next, isNotNull, reason: '$s must lead somewhere');
        }
      }
    });

    test('the ladder reaches completed from searching', () {
      final request = newRequest();
      var guard = 0;

      while (request.status.next != null && guard++ < 20) {
        request.advanceTo(request.status.next!);
      }

      expect(request.status, RideStatus.completed);
      expect(guard, lessThan(20));
    });

    test('a terminal request refuses to advance', () {
      final request = newRequest();
      request.status = RideStatus.completed;

      expect(request.advanceTo(RideStatus.headingToPickup), isFalse);
      expect(request.status, RideStatus.completed);
      expect(request.cancel(), isFalse);
    });
  });

  group('the proposal', () {
    test('shows a real name and a two-letter monogram', () {
      final request = newRequest();
      state.proposeRider(request);
      final proposal = state.rideProposal!;

      expect(proposal.riderName, isNotEmpty);
      expect(proposal.initials.length, 2);
      expect(proposal.initials, proposal.initials.toUpperCase());
    });

    test('labels an unknown distance as Nearby rather than inventing one', () {
      // Coordinates are final on the model, so this builds a request without
      // them the way a label that resolves to no seeded place would.
      final request = RideRequestItem(
        id: 'rq-no-coords',
        passengerId: db.passenger.id,
        passengerName: db.passenger.name,
        passengerInitials: db.passenger.initials,
        passengerRating: db.passenger.rating,
        pickupBarangay: 'Unknown',
        pickupPurok: '',
        pickup: 'Somewhere unlisted',
        dropoffBarangay: 'Unknown',
        dropoffPurok: '',
        dropoff: 'Elsewhere unlisted',
        distanceKm: 3.2,
        etaMinutes: 8,
        fare: 4500,
        paymentMethod: 'Cash',
        note: '',
        requestedAt: 'Just now',
      );
      state.myRideRequest = request;

      expect(state.proposeRider(request), MatchOutcome.proposed);
      final proposal = state.rideProposal!;

      expect(proposal.distanceKm, isNull);
      expect(proposal.distanceLabel, 'Nearby');
      // The ETA still has to be a usable number, not a null the UI would print.
      expect(proposal.etaMinutes, greaterThanOrEqualTo(1));
    });

    test('labels a known distance in km', () {
      final request = newRequest();
      state.proposeRider(request);
      final proposal = state.rideProposal!;

      if (proposal.distanceKm == null) {
        expect(proposal.distanceLabel, 'Nearby');
      } else {
        expect(proposal.distanceLabel, contains('km'));
      }
    });
  });
}

/// Distance from [rider] to the request's pickup, or null when unknown.
double? _distanceTo(RideRequestItem request, MapRider rider) {
  final lat = request.pickupLatitude;
  final lon = request.pickupLongitude;
  if (lat == null || lon == null) return null;
  return haversineKm(rider.position, MapPoint(lat, lon));
}

/// The mutable fields of a [RideRequestItem], so a test that mutates seeded
/// data can put it back the way it found it.
class _RequestState {
  final RideStatus status;
  final String? riderId;
  final String? vehicleId;

  _RequestState(this.status, this.riderId, this.vehicleId);

  factory _RequestState.of(RideRequestItem r) =>
      _RequestState(r.status, r.riderId, r.vehicleId);

  void applyTo(RideRequestItem r) {
    r.status = status;
    r.riderId = riderId;
    r.vehicleId = vehicleId;
  }
}