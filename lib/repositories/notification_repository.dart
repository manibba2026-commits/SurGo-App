import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';

/// In-app notification feed.
abstract interface class NotificationRepository {
  Future<List<NotificationRecord>> fetchNotifications(
    String profileId, {
    int? limit,
  });

  Future<int> countUnread(String profileId);
}

class SupabaseNotificationRepository implements NotificationRepository {
  SupabaseNotificationRepository(SurgoBackend backend) : _backend = backend;

  static const String _columns =
      'id, notification_type, title, body, data, read_at, created_at';

  final SurgoBackend _backend;

  @override
  Future<List<NotificationRecord>> fetchNotifications(
    String profileId, {
    int? limit,
  }) async {
    final rows = await _backend.rows(
      table: 'notifications',
      columns: _columns,
      eq: {'profile_id': profileId},
      orderBy: 'created_at',
      limit: limit,
    );
    return [for (final row in rows) NotificationRecord.fromRow(row)];
  }

  @override
  Future<int> countUnread(String profileId) async {
    // No count aggregate in the gateway, and the pilot feed is small, so the
    // unread badge counts the rows RLS already filtered.
    final rows = await _backend.rows(
      table: 'notifications',
      columns: 'id',
      eq: {'profile_id': profileId},
      whereNull: const ['read_at'],
    );
    return rows.length;
  }
}

/// Reads the notification slices the seed keeps per profile.
class MockNotificationRepository implements NotificationRepository {
  MockNotificationRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<NotificationRecord>> fetchNotifications(
    String profileId, {
    int? limit,
  }) async {
    final items = _itemsFor(profileId);
    final records = [for (final item in items) _toRecord(item)];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<int> countUnread(String profileId) async =>
      _itemsFor(profileId).where((item) => !item.read).length;

  List<NotificationItem> _itemsFor(String profileId) {
    final stored = _db.notificationsByUser[profileId];
    if (stored != null) return stored;
    if (profileId == _db.passenger.id) return _db.passengerNotifications;
    if (profileId == _db.earner.id) return _db.earnerNotifications;
    return const [];
  }

  NotificationRecord _toRecord(NotificationItem item) => NotificationRecord(
        id: item.id,
        type: item.type,
        title: item.title,
        body: item.body,
        isRead: item.read,
        // The seed pairs its "2h ago" label with a real ISO time, so mock mode
        // reports the same sort key the database column gives.
        createdAt: item.createdAt,
      );
}
