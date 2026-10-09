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
  late int originalCount;
  late int wallet;
  late int today;
  late int week;
  late int month;
  late List<int> daily;
  late int txCount;
  late RideRequestItem? savedRequest;
  late RideMatchProposal? savedProposal;
  late RideRequestItem? savedActive;
  late int tripCount;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    saved = db.rideRequests.map(_RequestState.of).toList();
    originalCount = db.rideRequests.length;
    tripCount = db.riderTrips.length;
    wallet = db.riderWalletBalance;
    today = db.earningsToday;
    week = db.earningsWeek;
    month = db.earningsMonth;
    daily = db.dailyEarnings.map((d) => d.amount).toList();
    txCount = db.riderTransactions.length;
    savedRequest = state.myRideRequest;
    savedProposal = state.rideProposal;
    savedActive = state.activeRide;
  });

  tearDown(() {
    // Drop anything a test added, then restore the original order and statuses.
    if (db.rideRequests.length > originalCount) {
      db.rideRequests.removeRange(originalCount, db.rideRequests.length);
    }
    for (var i = 0; i < saved.length; i++) {
      saved[i].applyTo(db.rideRequests[i]);
    }
    db.riderTrips.removeRange(tripCount, db.riderTrips.length);
    db.riderWalletBalance = wallet;
    db.earningsToday = today;
    db.earningsWeek = week;
    db.earningsMonth = month;
    for (var i = 0; i < db.dailyEarnings.length; i++) {
      db.dailyEarnings[i].amount = daily[i];
    }
    db.riderTransactions.removeRange(txCount, db.riderTransactions.length);
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

    test('gives a second request its own id, so two can never collide', () {
      final first = newRequest();

      final second = state.createRideRequest();

      expect(second.id, isNot(first.id));
      expect(db.rideRequests.length, originalCount + 2);
      // The pointer follows the newest request; the older one is still in the
      // list so the rider can see it, which is why the booking screen must not
      // offer "find ride" twice without checking.
      expect(state.myRideRequest, same(second));
    });

    test('two requests in the same microsecond still get distinct ids', () {
      final first = newRequest();
      final second = state.createRideRequest();

      expect(second.id, isNot(first.id));
    });
  });

  group('proposing a rider', () {
    test('picks an available rider and holds them as a proposal', () {
      final request = newRequest();

      final outcome = state.proposeRider(request);

      expect(outcome, MatchOutcome.proposed);
      final proposal = state.rideProposal!;
      expect(proposal.rider.available, isTrue);
      expect(proposal.rider.id, isNot(request.passengerId));
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
      for (final r in db.mapRiders.where((r) =>
          r.available &&
          r.vehicleType.toLowerCase() == request.vehicleId!.toLowerCase())) {
        final other = _distanceTo(request, r);
        if (other == null) continue;
        expect(distance, lessThanOrEqualTo(other));
      }
    });

    test('matches the rider to the requested type, not just availability', () {
      final request = newRequest(); // the booking default is Tricycle
      request.vehicleId = 'Motorcycle';

      expect(state.proposeRider(request), MatchOutcome.proposed);
      expect(state.rideProposal!.rider.vehicleType, 'motorcycle');
    });

    test('refuses when no rider drives the requested type', () {
      final request = newRequest();
      request.vehicleId = 'Boat';

      expect(state.proposeRider(request), MatchOutcome.noRidersAvailable);
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
      expect(rider.id, isNot(request.passengerId));
      expect(rider.id, isNot(db.passenger.id));
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
  });

  group('declining a proposal', () {
    test('returns the request to searching and forgets the rider', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();

      state.declineRideMatch();

      expect(request.status, RideStatus.searching);
      expect(request.riderId, isNull);
      // The requested vehicle type survives: only the rejected rider is
      // forgotten, so re-matching still respects the passenger's choice.
      expect(request.vehicleId, state.selectedRide.name);
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
      expect(state.activeRideBreakdown!.customerPays, request.fare);
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
      final walletBefore = db.riderWalletBalance;

      state.completeActiveRide();

      expect(request.status, RideStatus.completed);
      expect(state.activeRide, isNull);
      expect(db.riderWalletBalance, greaterThan(walletBefore));
      expect(db.riderTrips.length, tripCount + 1);
      expect(request.status.allowsChat, isFalse);
    });

    test('completing a trip that never started pays nothing', () {
      final request = newRequest();
      state.proposeRider(request);
      state.confirmRideMatch();
      state.riderAccepts(request);
      final walletBefore = db.riderWalletBalance;

      // Still accepted: no ride, no pay. This guard is the whole reason
      // completeActiveRide checks the status before crediting anything.
      state.completeActiveRide();

      expect(request.status, RideStatus.accepted);
      expect(db.riderWalletBalance, walletBefore);
      expect(db.riderTrips.length, tripCount);
      expect(state.activeRide, same(request));
    });

    test('completing twice does not pay twice', () {
      acceptedTrip();
      state.advanceRide();
      state.advanceRide();
      state.advanceRide();
      state.completeActiveRide();
      final walletAfter = db.riderWalletBalance;

      state.completeActiveRide();

      expect(db.riderWalletBalance, walletAfter);
      expect(db.riderTrips.length, tripCount + 1);
    });

    test('cancelling mid-trip stops the payout', () {
      final request = acceptedTrip();
      state.advanceRide();
      final walletBefore = db.riderWalletBalance;

      state.cancelActiveRide();

      expect(request.status, RideStatus.cancelled);
      expect(state.activeRide, isNull);
      expect(state.canChatOnRide, isFalse);
      expect(db.riderWalletBalance, walletBefore);
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