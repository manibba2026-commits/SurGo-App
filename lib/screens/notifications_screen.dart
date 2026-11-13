import 'package:flutter/material.dart';

import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';

/// Shared notifications list. `isRider` picks which feed (passenger or rider)
/// the notification repository reads for; both are the same read keyed by a
/// different profile.
class NotificationsScreen extends StatefulWidget {
  final bool isRider;
  const NotificationsScreen({super.key, this.isRider = false});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _markingAll = false;

  AppState get state => AppState.instance;

  DomainSlot get _feedSlot => widget.isRider
      ? DomainSlot.earnerNotificationFeed
      : DomainSlot.passengerNotificationFeed;

  DomainSlot get _unreadSlot => widget.isRider
      ? DomainSlot.unreadEarnerNotifications
      : DomainSlot.unreadPassengerNotifications;

  Future<void> _refresh() async {
    await Future.wait([
      state.cache.refresh(_feedSlot),
      state.cache.refresh(_unreadSlot),
    ]);
  }

  Future<void> _markAllRead() async {
    if (_markingAll) return;
    setState(() => _markingAll = true);
    final ok = await state.markAllNotificationsRead(isRider: widget.isRider);
    if (!mounted) return;
    setState(() => _markingAll = false);
    if (!ok) {
      SurgoNotice.show(
        context,
        'Notifications could not be updated. Check your connection and try '
        'again.',
        tone: SbNoticeTone.warning,
      );
    }
  }

  Future<void> _markRead(NotificationRecord notification) async {
    if (notification.isRead) return;
    final ok = await state.markNotificationRead(
      id: notification.id,
      isRider: widget.isRider,
    );
    if (!ok && mounted) {
      SurgoNotice.show(
        context,
        'That notification could not be marked read.',
        tone: SbNoticeTone.warning,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _markingAll ? null : _markAllRead,
            child: _markingAll
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Mark all read',
                    style: TextStyle(
                      color: AppColors.primaryLight,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: RepositoryView<List<NotificationRecord>>(
          slot: _feedSlot,
          empty: (_) => const CustomScrollView(
            physics: AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'No notifications yet',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
              ),
            ],
          ),
          data: (context, items) => ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _NotificationCard(
              notification: items[i],
              onMarkRead: () => _markRead(items[i]),
            ),
          ),
        ),
      ),
    );
  }
}

/// One expandable notification card.
///
/// Tapping the card marks an unread notification read and opens the detail
/// section: the notification type, when it arrived, its read state and the
/// scalar fields the server put in `data` (a rental or errand reference, for
/// example). The card itself never writes; the screen owns the repository call.
class _NotificationCard extends StatefulWidget {
  final NotificationRecord notification;
  final VoidCallback onMarkRead;

  const _NotificationCard({
    required this.notification,
    required this.onMarkRead,
  });

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  bool _expanded = false;

  NotificationRecord get n => widget.notification;

  void _toggle() {
    if (!n.isRead) widget.onMarkRead();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    return SbTintedCard(
      tone: n.isRead ? SbTone.neutral : SbTone.notification,
      wash: !n.isRead,
      borderColor: n.isRead ? AppColors.border : SbTone.notification.border,
      onTap: _toggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SbToneIcon(
                tone: n.isRead ? SbTone.neutral : SbTone.notification,
                icon: iconForNotificationType(n.type),
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            n.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (!n.isRead)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        const SizedBox(width: 6),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: AppColors.muted2,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      n.body,
                      maxLines: _expanded ? null : 2,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Text(
                          displayAge(n.createdAt),
                          style: const TextStyle(
                            color: AppColors.muted2,
                            fontSize: 10.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 3,
                          height: 3,
                          decoration: const BoxDecoration(
                            color: AppColors.muted2,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _typeLabel(n.type),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.muted2,
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 10),
            _detailRow('Type', _typeLabel(n.type)),
            _detailRow(
              'Received',
              displayTimestamp(n.createdAt, fallback: displayAge(n.createdAt)),
            ),
            _detailRow('Status', n.isRead ? 'Read' : 'Unread'),
            for (final entry in _details()) _detailRow(entry.key, entry.value),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.muted2, fontSize: 10.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<MapEntry<String, String>> _details() {
    final entries = <MapEntry<String, String>>[];
    for (final entry in n.data.entries) {
      if (entry.key == 'seed_id' || entry.value == null) continue;
      final value = entry.value;
      if (value is Map || value is List) continue;
      entries.add(
        MapEntry(_humanize(entry.key), _detailValue(entry.key, value)),
      );
      if (entries.length >= 4) break;
    }
    return entries;
  }

  static String _detailValue(String key, Object value) {
    final text = '$value';
    if ((key.endsWith('_id') || key == 'id') && text.length > 8) {
      return text.substring(0, 8);
    }
    return text;
  }

  static String _typeLabel(String type) => switch (type) {
    'promo' => 'Promotion',
    'ride' => 'Ride update',
    'rental' => 'Rental update',
    'pasuyo' => 'Errand update',
    'payment' => 'Payment',
    'wallet' => 'Wallet',
    'verification' => 'Verification',
    'system' => 'System',
    'safety' => 'Safety',
    'rating' => 'Rating',
    _ => _humanize(type),
  };

  static String _humanize(String value) {
    if (value.isEmpty) return value;
    final words = value
        .split(RegExp(r'[_\s]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
    return words;
  }
}
