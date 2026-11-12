import 'dart:async';

import '../repositories/backend.dart';
import '../state/domain_cache.dart';

typedef RowRealtimeBackend = SurgoRealtimeBackend;

class NotificationSession {
  NotificationSession({
    required this.cache,
    required this.profileId,
    this.realtime,
  });

  final DomainCache cache;
  final String profileId;
  final RowRealtimeBackend? realtime;

  static const _slots = [
    DomainSlot.unreadPassengerNotifications,
    DomainSlot.unreadEarnerNotifications,
    DomainSlot.passengerNotificationFeed,
    DomainSlot.earnerNotificationFeed,
  ];

  StreamSubscription<void>? _subscription;
  Timer? _poll;
  Timer? _deadline;
  Completer<bool>? _waiting;
  Future<void>? _refreshing;
  Future<void>? _flight;
  bool _pending = false;
  bool _started = false;
  bool _stopped = false;

  void start() {
    if (_started || _stopped || profileId.trim().isEmpty) return;
    _started = true;
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(refresh());
    });
    try {
      _subscription = realtime
          ?.watchRows(
            table: 'notifications',
            column: 'profile_id',
            value: profileId,
          )
          .listen(
            (_) => unawaited(refresh()),
            onError: (Object error) {
              if (!_stopped) unawaited(refresh());
            },
          );
    } catch (_) {
      // Missing realtime is not a failed SELECT; polling remains available.
    }
  }

  // A timed-out cache flight stays owned to prevent stalled reads piling up.
  Future<void> refresh() {
    if (_stopped || profileId.trim().isEmpty) return Future.value();
    _pending = true;
    final refreshing = _refreshing;
    if (refreshing != null) return refreshing;
    if (_flight != null) return Future.value();
    return _refreshing = _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _pending = false;
        for (final slot in _slots) {
          if (_stopped) return;
          if (!await _read(slot)) {
            _pending = !_stopped;
            return;
          }
        }
      } while (!_stopped && _pending);
    } finally {
      _refreshing = null;
    }
  }

  Future<bool> _read(DomainSlot slot) async {
    final done = Completer<bool>();
    _waiting = done;
    _deadline = Timer(const Duration(seconds: 20), () => done.complete(false));
    final flight = Future<void>.sync(() => cache.refresh(slot));
    _flight = flight;
    void settled() {
      if (identical(_flight, flight)) _flight = null;
      if (!done.isCompleted) {
        done.complete(true);
      } else {
        scheduleMicrotask(() {
          if (!_stopped && _pending && _refreshing == null) {
            unawaited(refresh());
          }
        });
      }
    }

    unawaited(
      flight.then(
        (_) => settled(),
        onError: (Object error, StackTrace stack) => settled(),
      ),
    );
    try {
      return await done.future;
    } finally {
      _deadline?.cancel();
      _deadline = null;
      _waiting = null;
    }
  }

  void stop() {
    _stopped = true;
    _pending = false;
    _poll?.cancel();
    _poll = null;
    _deadline?.cancel();
    _deadline = null;
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete(false);
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(
        Future<void>.sync(subscription.cancel).catchError((Object _) {}),
      );
    }
  }
}
