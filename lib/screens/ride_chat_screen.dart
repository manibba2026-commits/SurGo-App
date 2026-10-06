import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/ride_chat.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

/// Messages between the passenger and the rider on the active trip.
///
/// The thread exists for the duration of the ride and not before or after: chat
/// unlocks when the rider accepts and closes when the trip is completed or
/// cancelled. That rule lives in [AppState], so arriving here by any route -
/// including a back-stack left over from a finished trip - lands on an
/// explanation rather than a live conversation that should have closed.
class RideChatScreen extends StatefulWidget {
  const RideChatScreen({super.key});

  @override
  State<RideChatScreen> createState() => _RideChatScreenState();
}

class _RideChatScreenState extends State<RideChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Which "this chat is closed" explanation to show, captured once on open.
  ///
  /// Captured on first frame because the trip can end while this screen is still
  /// in the stack, and re-reading the live status on every build would silently
  /// swap the reason under the passenger.
  String? _closedReason;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _evaluate();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Decides whether the thread can be opened, and says why not if it cannot.
  void _evaluate() {
    final state = AppState.instance;
    if (state.openRideChat() != null) {
      _scrollToEnd();
      return;
    }
    switch (state.chatAvailability) {
      case ChatAvailability.notAcceptedYet:
        _closedReason =
            'Chat opens once your rider accepts the trip. You can talk to each '
            'other as soon as they are on the way.';
      case ChatAvailability.ended:
        _closedReason =
            'This trip is finished, so chat is closed. Use Trip history or the '
            'support line if you still need to reach SurGo.';
      case ChatAvailability.available:
        _closedReason = 'No rider is assigned to this trip yet.';
    }
    setState(() {});
  }

  void _scrollToEnd([bool animate = false]) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _send() {
    final state = AppState.instance;
    final refusal = state.sendRideMessage(_controller.text);

    if (refusal != null) {
      // Tell the passenger rather than dropping the keystroke: a message that
      // vanishes with no explanation reads as a broken app.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_explain(refusal))),
      );
      return;
    }

    _controller.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd(true));
  }

  String _explain(ChatSendRefusal refusal) => switch (refusal) {
        ChatSendRefusal.empty => 'Type a message first.',
        ChatSendRefusal.tooLong =>
          'That message is too long. Keep it under $kMaxChatMessageLength '
              'characters.',
        ChatSendRefusal.tripNotAccepted =>
          'Your rider has not accepted the trip yet, so chat is not open.',
        ChatSendRefusal.tripEnded =>
          'This trip is finished, so chat is closed.',
      };

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final thread = state.rideChat;

    if (thread == null) {
      return _closed(_closedReason ?? _reasonFor(state.chatAvailability));
    }

    final messages = thread.messages;
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            SbAvatar(initials: thread.riderInitials, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    thread.riderName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  Text(
                    'On this trip · ${state.myRideRequest?.status.label ?? ''}',
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const _EmptyThread()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final message = messages[i];
                      final previous = i == 0 ? null : messages[i - 1];
                      // Only label a bubble group once, and start a new day
                      // separator when the calendar day changes.
                      final newDay = previous == null ||
                          !_sameDay(previous.sentAt, message.sentAt);
                      final grouped = !newDay &&
                          previous.author == message.author &&
                          message.sentAt
                                  .difference(previous.sentAt)
                                  .inMinutes <
                              5;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (newDay) _DaySeparator(label: message.dayLabel(now)),
                          _Bubble(
                            message: message,
                            showTime: !grouped,
                          ),
                        ],
                      );
                    },
                  ),
          ),
          _composer(),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _reasonFor(ChatAvailability availability) => switch (availability) {
        ChatAvailability.available => 'No rider is assigned to this trip yet.',
        ChatAvailability.notAcceptedYet =>
          'Chat opens once your rider accepts the trip.',
        ChatAvailability.ended => 'This trip is finished, so chat is closed.',
      };

  Widget _composer() {
    final remaining = kMaxChatMessageLength - _controller.text.length;
    final canSend = _controller.text.trim().isNotEmpty && remaining >= 0;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                maxLength: kMaxChatMessageLength,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 13.5),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Message your rider',
                  hintStyle: const TextStyle(
                      color: AppColors.muted2, fontSize: 13),
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.panel2,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            // A send button that is greyed out rather than hidden: its position
            // should not jump as the field gains and loses content.
            IconButton(
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.send_rounded, size: 20),
              color: AppColors.primaryLight,
              disabledColor: AppColors.muted2,
              style: IconButton.styleFrom(
                backgroundColor: canSend
                    ? AppColors.primarySoft
                    : AppColors.panel2,
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _closed(String reason) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_bubble_outline_rounded,
                  size: 40, color: AppColors.muted2),
              const SizedBox(height: 14),
              const Text('Chat is closed',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 8),
              Text(reason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.5)),
              const SizedBox(height: 22),
              SbOutlineButton(
                label: 'Back to trip',
                block: false,
                onPressed: () {
                  // Drop this screen rather than leaving a dead chat route
                  // stacked on top of the trip.
                  if (Navigator.canPop(context)) {
                    Navigator.pop(context);
                  } else {
                    Navigator.pushReplacementNamed(context, '/livetrip');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final RideChatMessage message;
  final bool showTime;

  const _Bubble({required this.message, required this.showTime});

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    return Padding(
      padding: EdgeInsets.only(top: showTime ? 8 : 3),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.76,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              color: mine ? AppColors.primaryDark : AppColors.panel2,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft: Radius.circular(mine ? 14 : 4),
                bottomRight: Radius.circular(mine ? 4 : 14),
              ),
              border: mine ? null : Border.all(color: AppColors.border),
            ),
            child: Text(
              message.body,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
          if (showTime) ...[
            const SizedBox(height: 3),
            Text(
              message.timeLabel,
              style: const TextStyle(color: AppColors.muted2, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  final String label;
  const _DaySeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(label,
                style: const TextStyle(color: AppColors.muted2, fontSize: 10.5)),
          ),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          'No messages yet. Say hello to your rider.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
      ),
    );
  }
}