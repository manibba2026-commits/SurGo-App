import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';

/// In-app notification feed.
abstract interface class NotificationRepository {
  Future<List<NotificationRecord>> fetchNotifications(
    String profileId, {
    int? limit,
  });

  Future<int> countUnread(String profileId);

  /// Marks one notification read. The RPC refuses a notification owned by a
  /// different profile; [profileId] is only used by the seeded implementation.
  Future<void> markRead(String profileId, String notificationId);

  /// Marks every unread notification for [profileId] read and returns the count
  /// the database changed.
  Future<int> markAllRead(String profileId);
}

class SupabaseNotificationRepository implements NotificationRepository {
  SupabaseNotificationRepository(SurgoBackend backend, {this._writer})
    : _backend = backend;

  static const String _columns =
      'id, notification_type, title, body, data, read_at, created_at';

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;

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

  @override
  Future<void> markRead(String profileId, String notificationId) async {
    final result = await _requireWriter().rpc(
      function: 'mark_notification_read',
      params: {'p_notification_id': notificationId},
    );
    if (_rpcCount(result) == 0) {
      throw RepositoryFailure.notFound();
    }
  }

  @override
  Future<int> markAllRead(String profileId) async {
    final result = await _requireWriter().rpc(
      function: 'mark_all_notifications_read',
    );
    return _rpcCount(result);
  }

  SurgoWriteBackend _requireWriter() {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot update notifications.',
      );
    }
    return writer;
  }

  static int _rpcCount(Object? result) {
    if (result is int) return result;
    if (result is num) return result.toInt();
    if (result is String) return int.tryParse(result) ?? 0;
    if (result is List && result.isNotEmpty) return _rpcCount(result.first);
    return 0;
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

  @override
  Future<void> markRead(String profileId, String notificationId) async {
    for (final item in _itemsFor(profileId)) {
      if (item.id == notificationId) item.read = true;
    }
  }

  @override
  Future<int> markAllRead(String profileId) async {
    var changed = 0;
    for (final item in _itemsFor(profileId)) {
      if (!item.read) {
        item.read = true;
        changed++;
      }
    }
    return changed;
  }

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
