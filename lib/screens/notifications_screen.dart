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
class NotificationsScreen extends StatelessWidget {
  final bool isRider;
  const NotificationsScreen({super.key, this.isRider = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final slot = isRider
        ? DomainSlot.earnerNotificationFeed
        : DomainSlot.passengerNotificationFeed;
    // Hosted notifications support SELECT only, not acknowledgement. A hosted
    // identity using the offline registry still keeps the seed's mark-read UX.
    final hosted =
        state.usesHostedIdentity && state.repositories.isSupabaseBacked;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: hosted
                ? () => SurgoNotice.show(
                    context,
                    'Marking notifications read is not synced for live '
                    'accounts yet.',
                    tone: SbNoticeTone.info,
                  )
                : () => isRider
                      ? state.clearRiderNotifications()
                      : state.clearNotifications(),
            child: const Text(
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
        onRefresh: () => Future.wait([
          state.cache.refresh(slot),
          state.cache.refresh(
            isRider
                ? DomainSlot.unreadEarnerNotifications
                : DomainSlot.unreadPassengerNotifications,
          ),
        ]),
        child: RepositoryView<List<NotificationRecord>>(
          slot: slot,
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
            itemBuilder: (context, i) =>
                _tile(state, items[i], markRead: !hosted),
          ),
        ),
      ),
    );
  }

  Widget _tile(AppState state, NotificationRecord n, {required bool markRead}) {
    return SbTintedCard(
      tone: n.isRead ? SbTone.neutral : SbTone.notification,
      wash: !n.isRead,
      borderColor: n.isRead ? AppColors.border : SbTone.notification.border,
      onTap: markRead ? () => state.markNotificationReadById(n.id) : null,
      child: Row(
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
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  n.body,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  displayAge(n.createdAt),
                  style: const TextStyle(
                    color: AppColors.muted2,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
