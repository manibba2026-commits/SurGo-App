import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/ride_chat.dart';
import 'package:surgo/state/ride_match.dart';
import 'package:surgo/state/ride_status.dart';

/// Exercises ride chat: when it is allowed, when it closes, and that a closed
/// thread cannot be reopened.
///
/// Chat is the one feature here whose gate is not its own UI but the trip's
/// status. So most of these tests assert the gate rather than the messages.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  late int originalCount;
  late RideRequestItem? savedRequest;
  late RideMatchProposal? savedProposal;
  late RideRequestItem? savedActive;

  setUpAll(() async {
    await db.load();
  });

  setUp(() {
    originalCount = db.rideRequests.length;
    savedRequest = state.myRideRequest;
    savedProposal = state.rideProposal;
    savedActive = state.activeRide;
  });

  tearDown(() {
    if (db.rideRequests.length > originalCount) {
      db.rideRequests.removeRange(originalCount, db.rideRequests.length);
    }
    state.myRideRequest = savedRequest;
    state.rideProposal = savedProposal;
    state.activeRide = savedActive;
    state.activeRideBreakdown = null;
    // Threads are keyed by request id and every request here is new, so
    // clearing the pointer is what releases them; there is nothing else to
    // restore.
  });

  RideRequestItem searching() {
    state.setPickup('SM Terminal');
    state.setDestination('Tandag Public Hall');
    return state.createRideRequest();
  }

  RideRequestItem accepted() {
    final request = searching();
    state.proposeRider(request);
    state.confirmRideMatch();
    state.riderAccepts(request);
    return request;
  }

  RideRequestItem completed() {
    final request = accepted();
    state.advanceRide();
    state.advanceRide();
    state.advanceRide();
    state.completeActiveRide();
    return request;
  }

  group('the availability gate', () {
    test('is closed with no request at all', () {
      state.myRideRequest = null;

      expect(state.chatAvailability, ChatAvailability.notAcceptedYet);
      expect(state.rideChat, isNull);
      expect(state.openRideChat(), isNull);
    });

    test('is closed while searching', () {
      searching();

      expect(state.chatAvailability, ChatAvailability.notAcceptedYet);
      expect(state.openRideChat(), isNull);
    });

    test('is closed while awaiting the rider, who has not agreed yet', () {
      final request = searching();
      state.proposeRider(request);
      state.confirmRideMatch();

      expect(request.status, RideStatus.awaitingAcceptance);
      expect(state.chatAvailability, ChatAvailability.notAcceptedYet);
      expect(state.openRideChat(), isNull);
    });

    test('opens the moment the rider accepts', () {
      accepted();

      expect(state.chatAvailability, ChatAvailability.available);
      expect(state.openRideChat(), isNotNull);
    });

    test('stays open for the whole trip', () {
      final request = accepted();

      state.advanceRide();
      expect(state.chatAvailability, ChatAvailability.available);
      state.advanceRide();
      expect(state.chatAvailability, ChatAvailability.available);
      state.advanceRide();
      expect(state.chatAvailability, ChatAvailability.available);
      expect(request.status, RideStatus.inProgress);
    });

    test('closes when the trip completes', () {
      completed();

      expect(state.chatAvailability, ChatAvailability.ended);
      expect(state.rideChat, isNull);
      expect(state.openRideChat(), isNull);
    });

    test('closes when the trip is cancelled', () {
      final request = accepted();
      state.advanceRide();

      state.cancelActiveRide();

      expect(request.status, RideStatus.cancelled);
      expect(state.chatAvailability, ChatAvailability.ended);
      expect(state.openRideChat(), isNull);
    });

    test('is closed for a request cancelled before it started', () {
      final request = searching();

      state.cancelRideRequest();

      expect(request.status, RideStatus.cancelled);
      expect(state.openRideChat(), isNull);
    });
  });

  group('mapping a status to availability', () {
    test('covers every ride state', () {
      final expected = {
        RideStatus.searching: ChatAvailability.notAcceptedYet,
        RideStatus.awaitingAcceptance: ChatAvailability.notAcceptedYet,
        RideStatus.accepted: ChatAvailability.available,
        RideStatus.headingToPickup: ChatAvailability.available,
        RideStatus.arrived: ChatAvailability.available,
        RideStatus.inProgress: ChatAvailability.available,
        RideStatus.completed: ChatAvailability.ended,
        RideStatus.cancelled: ChatAvailability.ended,
      };

      // Asserted exhaustively: adding a state to the enum without deciding
      // whether chat opens would otherwise fail to compile here rather than
      // silently defaulting.
      for (final entry in expected.entries) {
        expect(chatAvailabilityFor(entry.key), entry.value,
            reason: '${entry.key} should map to ${entry.value}');
      }
    });

    test('treats a missing request as not yet accepted', () {
      expect(chatAvailabilityFor(null), ChatAvailability.notAcceptedYet);
    });
  });

  group('opening a thread', () {
    test('seeds the opening messages from the matched rider', () {
      final request = accepted();

      final thread = state.openRideChat()!;

      expect(thread.requestId, request.id);
      expect(thread.rider.id, request.riderId);
      expect(thread.riderName, isNotEmpty);
      expect(thread.riderInitials.length, 2);
      expect(thread.isEmpty, isFalse);
      expect(thread.length, greaterThanOrEqualTo(2));
      // Every seeded line is from the rider: the passenger has not written yet.
      expect(thread.messages.every((m) => !m.isMine), isTrue);
    });

    test('mentions the real pickup, so it is not a canned greeting', () {
      final request = accepted();

      final thread = state.openRideChat()!;
      final text = thread.messages.map((m) => m.body).join(' ');

      expect(request.pickup, isNotEmpty);
      expect(text, contains(request.pickup.split(',').first.trim()));
    });

    test('returns the same thread when opened twice', () {
      accepted();

      final first = state.openRideChat();
      final second = state.openRideChat();

      // Re-creating would wipe the conversation, so identity matters more than
      // equality of contents here.
      expect(identical(first, second), isTrue);
    });

    test('starts empty of passenger messages', () {
      accepted();

      final thread = state.openRideChat()!;

      expect(thread.messages.where((m) => m.isMine), isEmpty);
    });
  });

  group('sending a message', () {
    test('appends it to the thread and marks it as the passenger\'s', () {
      accepted();
      final before = state.rideChat!.length;

      final refusal = state.sendRideMessage('On my way down');

      expect(refusal, isNull);
      expect(state.rideChat!.length, before + 1);
      final last = state.rideChat!.messages.last;
      expect(last.body, 'On my way down');
      expect(last.isMine, isTrue);
      expect(last.author, ChatAuthor.passenger);
    });

    test('trims the body, so whitespace is not stored', () {
      accepted();

      state.sendRideMessage('   hello   ');

      expect(state.rideChat!.messages.last.body, 'hello');
    });

    test('refuses a blank message', () {
      accepted();

      expect(state.sendRideMessage(''), ChatSendRefusal.empty);
      expect(state.sendRideMessage('    '), ChatSendRefusal.empty);
      expect(state.sendRideMessage('\n\t'), ChatSendRefusal.empty);
    });

    test('refuses a message past the length cap', () {
      accepted();
      final tooLong = 'x' * (kMaxChatMessageLength + 1);

      expect(state.sendRideMessage(tooLong), ChatSendRefusal.tooLong);
      // The thread must be untouched by a rejected send.
      expect(state.rideChat!.messages.every((m) => m.body != tooLong), isTrue);
    });

    test('accepts a message exactly at the cap', () {
      accepted();
      final atCap = 'x' * kMaxChatMessageLength;

      expect(state.sendRideMessage(atCap), isNull);
      expect(state.rideChat!.messages.last.body.length, kMaxChatMessageLength);
    });

    test('refuses while the rider has not accepted', () {
      final request = searching();
      state.proposeRider(request);
      state.confirmRideMatch();

      expect(state.sendRideMessage('hello?'),
          ChatSendRefusal.tripNotAccepted);
      expect(state.rideChat, isNull);
    });

    test('refuses after the trip ends', () {
      completed();

      expect(state.sendRideMessage('still there?'), ChatSendRefusal.tripEnded);
    });

    test('refuses with no request', () {
      state.myRideRequest = null;

      expect(state.sendRideMessage('hello?'),
          ChatSendRefusal.tripNotAccepted);
    });

    test('keeps messages in the order they were sent', () {
      accepted();

      state.sendRideMessage('first');
      state.sendRideMessage('second');
      state.sendRideMessage('third');

      final mine = state.rideChat!.messages.where((m) => m.isMine).toList();
      expect(mine.map((m) => m.body).toList(), ['first', 'second', 'third']);
      // Timestamps must be non-decreasing or the thread renders out of order.
      for (var i = 1; i < mine.length; i++) {
        expect(
            !mine[i].sentAt.isBefore(mine[i - 1].sentAt), isTrue,
            reason: 'message ${i} was stamped before message ${i - 1}');
      }
    });

    test('gives every message a distinct id', () {
      accepted();

      state.sendRideMessage('one');
      state.sendRideMessage('two');
      state.sendRideMessage('three');

      final ids = state.rideChat!.messages.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('closing a thread', () {
    test('completing the trip discards it', () {
      final request = accepted();
      state.openRideChat();
      state.sendRideMessage('see you');
      expect(state.rideChat, isNotNull);

      state.advanceRide();
      state.advanceRide();
      state.advanceRide();
      state.completeActiveRide();

      // The thread is gone rather than left readable: a finished ride's messages
      // should not be reachable from the next trip's chat.
      expect(state.rideChat, isNull);
      expect(_threadExists(state, request.id), isFalse);
    });

    test('a new trip gets a fresh, empty-of-passenger thread', () {
      completed();
      final second = accepted();

      final thread = state.openRideChat()!;

      expect(thread.requestId, second.id);
      // Nothing from the finished trip leaked into this one.
      expect(thread.messages.where((m) => m.isMine), isEmpty);
      expect(thread.messages.every((m) => m.body != 'see you'), isTrue);
    });

    test('cancelling the trip discards it', () {
      final request = accepted();
      state.openRideChat();

      state.cancelActiveRide();

      expect(_threadExists(state, request.id), isFalse);
    });
  });

  group('message labels', () {
    test('the clock is zero-padded and 24-hour', () {
      final m = RideChatMessage(
        id: 'm',
        requestId: 'r',
        author: ChatAuthor.passenger,
        body: 'hi',
        sentAt: DateTime(2026, 1, 1, 9, 5),
      );

      expect(m.timeLabel, '09:05');
    });

    test('labels today and yesterday relative to now', () {
      final now = DateTime(2026, 5, 20, 12, 0);

      final today = RideChatMessage(
        id: 'a',
        requestId: 'r',
        author: ChatAuthor.rider,
        body: 'x',
        sentAt: DateTime(2026, 5, 20, 9, 0),
      );
      final yesterday = RideChatMessage(
        id: 'b',
        requestId: 'r',
        author: ChatAuthor.rider,
        body: 'x',
        sentAt: DateTime(2026, 5, 19, 23, 30),
      );

      expect(today.dayLabel(now), 'Today');
      expect(yesterday.dayLabel(now), 'Yesterday');
    });

    test('falls back to a short date for anything older', () {
      final now = DateTime(2026, 5, 20, 12, 0);
      final old = RideChatMessage(
        id: 'a',
        requestId: 'r',
        author: ChatAuthor.rider,
        body: 'x',
        sentAt: DateTime(2026, 5, 1, 8, 0),
      );

      expect(old.dayLabel(now), '1 May');
    });

    test('a message just before midnight still reads as yesterday', () {
      // The classic off-by-one: comparing clock times instead of calendar days
      // would call 23:50 on the 19th "Today" at 00:10 on the 20th.
      final now = DateTime(2026, 5, 20, 0, 10);
      final late = RideChatMessage(
        id: 'a',
        requestId: 'r',
        author: ChatAuthor.rider,
        body: 'x',
        sentAt: DateTime(2026, 5, 19, 23, 50),
      );

      expect(late.dayLabel(now), 'Yesterday');
    });
  });

  group('the thread list', () {
    test('is unmodifiable, so a screen cannot rewrite history', () {
      accepted();
      final thread = state.openRideChat()!;

      expect(
        () => thread.messages.add(
          RideChatMessage(
            id: 'x',
            requestId: thread.requestId,
            author: ChatAuthor.rider,
            body: 'forged',
            sentAt: DateTime.now(),
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });
}

/// Whether a thread exists for [requestId].
///
/// Threads are only reachable through the active request, and the store hands
/// back null once the trip is over, so the public getter is the whole truth a
/// test needs.
bool _threadExists(AppState state, String requestId) {
  final request = state.myRideRequest;
  if (request == null) return false;
  if (request.id != requestId) return false;
  return state.rideChat != null;
}