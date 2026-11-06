import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;

/// Pasuyo errands: the customer's post, the helper's job list and the
/// append-only status history.
abstract interface class PasuyoRepository {
  Future<List<ServiceRequestRecord>> fetchRequestsByCustomer(
    String customerId, {
    int? limit,
  });

  Future<List<ServiceRequestRecord>> fetchRequestsByProvider(
    String providerId, {
    int? limit,
  });

  /// Unclaimed errands for the earner feed. Approved-earner visibility is an
  /// RLS decision, so an unapproved reader gets an empty list.
  Future<List<ServiceRequestRecord>> fetchOpenFeed(
    String serviceAreaId, {
    PasuyoCategory? category,
    int? limit,
  });

  Future<ServiceRequestRecord?> fetchRequest(String requestId);

  Future<List<ServiceStatusEventRecord>> fetchStatusEvents(String requestId);
}

const String _requestColumns =
    'id, customer_id, provider_id, service_area_id, category, status, title, '
    'description, pickup_address, pickup_barangay_id, pickup_purok_id, '
    'pickup_latitude, pickup_longitude, dropoff_address, dropoff_barangay_id, '
    'dropoff_purok_id, dropoff_latitude, dropoff_longitude, budget_centavos, '
    'quoted_fee_centavos, platform_fee_centavos, payment_method, '
    'requested_at, accepted_at, picked_up_at, delivered_at, cancelled_at, '
    'cancellation_reason, '
    'items:service_request_items(id, service_request_id, name, quantity, unit, '
    'estimated_unit_price_centavos, actual_unit_price_centavos, notes)';

class SupabasePasuyoRepository implements PasuyoRepository {
  SupabasePasuyoRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

  @override
  Future<List<ServiceRequestRecord>> fetchRequestsByCustomer(
    String customerId, {
    int? limit,
  }) =>
      _read(eq: {'customer_id': customerId}, limit: limit);

  @override
  Future<List<ServiceRequestRecord>> fetchRequestsByProvider(
    String providerId, {
    int? limit,
  }) =>
      _read(eq: {'provider_id': providerId}, limit: limit);

  @override
  Future<List<ServiceRequestRecord>> fetchOpenFeed(
    String serviceAreaId, {
    PasuyoCategory? category,
    int? limit,
  }) =>
      _read(
        eq: {
          'service_area_id': serviceAreaId,
          'status': 'available',
          if (category != null) 'category': pasuyoCategoryTokenToDb(category),
        },
        limit: limit,
      );

  @override
  Future<ServiceRequestRecord?> fetchRequest(String requestId) async {
    final row = await _backend.row(
      table: 'service_requests',
      columns: _requestColumns,
      eq: {'id': requestId},
    );
    return row == null ? null : ServiceRequestRecord.fromRow(row);
  }

  @override
  Future<List<ServiceStatusEventRecord>> fetchStatusEvents(
      String requestId) async {
    final rows = await _backend.rows(
      table: 'service_status_events',
      columns: 'id, service_request_id, status, actor_profile_id, note, '
          'created_at',
      eq: {'service_request_id': requestId},
      orderBy: 'created_at',
      ascending: true,
    );
    return [for (final row in rows) ServiceStatusEventRecord.fromRow(row)];
  }

  Future<List<ServiceRequestRecord>> _read({
    required Map<String, Object> eq,
    int? limit,
  }) async {
    final rows = await _backend.rows(
      table: 'service_requests',
      columns: _requestColumns,
      eq: eq,
      orderBy: 'requested_at',
      limit: limit,
    );
    return [for (final row in rows) ServiceRequestRecord.fromRow(row)];
  }
}

/// Reads the seeded `pasuyo.json` slice.
class MockPasuyoRepository implements PasuyoRepository {
  MockPasuyoRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<ServiceRequestRecord>> fetchRequestsByCustomer(
    String customerId, {
    int? limit,
  }) async {
    final records = [
      for (final task in _db.pasuyoTasks)
        if (task.customerId == customerId) _toRecord(task),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<ServiceRequestRecord>> fetchRequestsByProvider(
    String providerId, {
    int? limit,
  }) async {
    final records = [
      for (final task in _db.pasuyoTasks)
        if (task.helperId == providerId) _toRecord(task),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<ServiceRequestRecord>> fetchOpenFeed(
    String serviceAreaId, {
    PasuyoCategory? category,
    int? limit,
  }) async {
    final records = [
      for (final task in _db.pasuyoTasks)
        if (task.isOpen && (category == null || task.category == category))
          _toRecord(task),
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<ServiceRequestRecord?> fetchRequest(String requestId) async {
    for (final task in _db.pasuyoTasks) {
      if (task.id == requestId) return _toRecord(task);
    }
    return null;
  }

  @override
  Future<List<ServiceStatusEventRecord>> fetchStatusEvents(
      String requestId) async {
    // No transition log in the seed; see the note in MockRideRepository.
    return const [];
  }

  ServiceRequestRecord _toRecord(PasuyoTask task) => ServiceRequestRecord(
        id: task.id,
        customerId: task.customerId,
        providerId: task.helperId,
        serviceAreaId: mockServiceAreaId,
        category: task.category,
        status: task.status,
        title: task.title,
        pickupAddress: task.pickup,
        pickupBarangayName: task.pickupBarangay,
        dropoffAddress: task.dropoff.isEmpty ? null : task.dropoff,
        dropoffBarangayName: task.dropoffBarangay,
        budgetCentavos: task.budget,
        paymentMethod: 'cash',
        requestedAt: task.requestedAtIso,
        description: task.note.isEmpty ? null : task.note,
        items: [
          for (var index = 0; index < task.items.length; index++)
            ServiceRequestItemRecord(
              id: '${task.id}-item-$index',
              serviceRequestId: task.id,
              name: task.items[index],
            ),
        ],
        customerName: _db.passengers[task.customerId]?.name,
        providerName:
            task.helperId == null ? null : _db.earners[task.helperId]?.name,
      );
}
