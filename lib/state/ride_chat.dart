import '../data/db_models.dart';
import 'ride_status.dart';

/// Who sent a message.
enum ChatAuthor { passenger, rider }

/// One message in a ride's chat thread.
///
/// Messages are immutable once sent; the timestamp is a real [DateTime] rather
/// than a display string so the thread can be grouped by day and ordered
/// without parsing text back out.
class RideChatMessage {
  final String id;
  final String requestId;
  final ChatAuthor author;
  final String body;
  final DateTime sentAt;

  const RideChatMessage({
    required this.id,
    required this.requestId,
    required this.author,
    required this.body,
    required this.sentAt,
  });

  bool get isMine => author == ChatAuthor.passenger;

  /// The clock time shown under the bubble.
  ///
  /// Only the clock, not the date: every message in a ride thread is from the
  /// same session, and the date sits on the day's separator instead.
  String get timeLabel {
    final h = sentAt.hour.toString().padLeft(2, '0');
    final m = sentAt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Day separator label: "Today", "Yesterday", or a short date.
  String dayLabel(DateTime now) {
    final day = DateTime(sentAt.year, sentAt.month, sentAt.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${sentAt.day} ${_monthName(sentAt.month)}';
  }

  static String _monthName(int m) => const [
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
      ][m - 1];
}

/// The messages for one ride, plus who the other party is.
///
/// The thread exists only while there is a trip to talk about. [RideStatus]
/// decides that, not the screen: opening the chat screen, or a leftover route
/// in the stack, must not be enough to make a thread.
class RideChatThread {
  /// The ride this thread belongs to.
  final String requestId;

  /// The rider on the other side of the conversation.
  final MapRider rider;

  final List<RideChatMessage> _messages;

  RideChatThread({
    required this.requestId,
    required this.rider,
    List<RideChatMessage>? messages,
  }) : _messages = [...?messages];

  /// Messages oldest first, which is the order a chat reads in.
  List<RideChatMessage> get messages => List.unmodifiable(_messages);

  bool get isEmpty => _messages.isEmpty;

  int get length => _messages.length;

  /// The other party's name, for the thread header.
  String get riderName => rider.name;

  /// Two-letter monogram for the header avatar.
  String get riderInitials {
    final parts = rider.name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  /// Adds a message to the thread.
  void add(RideChatMessage message) => _messages.add(message);
}

/// A rejection from [sendRideMessage], so the UI can explain itself instead of
/// silently dropping the keystroke.
enum ChatSendRefusal {
  /// No ride is active, or the trip has not started yet.
  tripNotAccepted,

  /// The ride is over: completed or cancelled.
  tripEnded,

  /// Nothing but whitespace was typed.
  empty,

  /// Beyond the per-message cap, which keeps one pasted paragraph from turning
  /// the thread into an unreadable wall.
  tooLong,
}

/// Why chat is unavailable right now.
enum ChatAvailability {
  /// The rider has accepted; the thread is open.
  available,

  /// Still searching or waiting for the rider to accept.
  notAcceptedYet,

  /// The trip is over.
  ended,
}

/// The longest a single message may be. Comfortably longer than a sentence,
/// short enough that the bubble stays readable.
const int kMaxChatMessageLength = 400;

/// Maps a ride's [RideStatus] to whether its chat is open.
///
/// A single place decides this so the live trip screen and the chat screen
/// cannot disagree about whether the thread is live.
ChatAvailability chatAvailabilityFor(RideStatus? status) {
  if (status == null) return ChatAvailability.notAcceptedYet;
  if (status.isTerminal) return ChatAvailability.ended;
  if (!status.allowsChat) return ChatAvailability.notAcceptedYet;
  return ChatAvailability.available;
}

/// The opening messages for a new thread.
///
/// A thread that starts empty reads as a broken feature: the passenger has
/// opened a chat and sees nothing to reply to. These stand in for the small
/// talk that has already happened by the time a rider is driving over, which is
/// why they mention the actual pickup rather than being a fixed greeting.
List<RideChatMessage> seedRideMessages({
  required String requestId,
  required MapRider rider,
  required String pickup,
  required int etaMinutes,
  required DateTime now,
}) =>
    [
      RideChatMessage(
        id: '$requestId-m1',
        requestId: requestId,
        author: ChatAuthor.rider,
        body: 'Hi! I\'m on my way to $pickup, about $etaMinutes min away.',
        sentAt: now.subtract(const Duration(minutes: 3)),
      ),
      RideChatMessage(
        id: '$requestId-m2',
        requestId: requestId,
        author: ChatAuthor.rider,
        body: 'Message me here if you need anything before I arrive.',
        sentAt: now.subtract(const Duration(minutes: 2, seconds: 55)),
      ),
    ];