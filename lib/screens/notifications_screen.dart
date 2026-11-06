import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/surfaces.dart';

/// Shared notifications list. `isRider` picks which feed (passenger or
/// rider) to read from — both are just separate arrays in the mock DB.
class NotificationsScreen extends StatelessWidget {
  final bool isRider;
  const NotificationsScreen({super.key, this.isRider = false});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: () => isRider
                ? state.clearRiderNotifications()
                : state.clearNotifications(),
            child: const Text('Mark all read',
                style: TextStyle(color: AppColors.primaryLight, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final items = isRider ? state.earnerNotifications : state.passengerNotifications;
          if (items.isEmpty) {
            return const Center(
              child: Text('No notifications yet', style: TextStyle(color: AppColors.muted)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final n = items[i];
              return SbTintedCard(
                tone: n.read ? SbTone.neutral : SbTone.notification,
                wash: !n.read,
                borderColor:
                    n.read ? AppColors.border : SbTone.notification.border,
                onTap: () => state.markNotificationRead(n),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SbToneIcon(
                      tone: n.read ? SbTone.neutral : SbTone.notification,
                      icon: n.icon,
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
                                child: Text(n.title,
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                              ),
                              if (!n.read)
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
                          Text(n.body, style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                          const SizedBox(height: 6),
                          Text(n.time, style: const TextStyle(color: AppColors.muted2, fontSize: 10.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
