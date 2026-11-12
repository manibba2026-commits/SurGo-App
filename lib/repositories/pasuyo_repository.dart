import '../data/db_models.dart';
import '../data/db_service.dart';
import '../state/pasuyo_status.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'catalog_repository.dart' show mockServiceAreaId;
import 'repository_failure.dart';

/// Pasuyo errands: the customer's post, the helper's job list and the
/// append-only status history.
///
/// Reads are open to any build. Writes are only offered when a writer was
/// installed; each one calls a database function that checks the actor and
/// the legal transition, so the client never decides either.
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

  /// Posts an errand as the signed-in customer.
  ///
  /// [items] is the JSON-ready list the database function turns into
  /// `service_request_items` rows: `{name, quantity, unit,
  /// estimated_unit_price_centavos, notes}`.
  Future<ServiceRequestRecord> createRequest({
    required PasuyoCategory category,
    required String title,
    required String pickupAddress,
    required String pickupBarangayId,
    required int quotedFeeCentavos,
    List<Map<String, dynamic>> items = const [],
    String? description,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? dropoffAddress,
    String? dropoffBarangayId,
    String? dropoffPurokId,
    double? dropoffLatitude,
    double? dropoffLongitude,
    bool bookedForSomeone = false,
    String? recipientName,
    String? recipientPhone,
  });

  /// Claims an open errand as the signed-in helper.
  Future<ServiceRequestRecord> accept(String requestId);

  /// Moves an assigned errand one step. The database refuses any other move.
  Future<ServiceRequestRecord> advance({
    required String requestId,
    required PasuyoStatus status,
  });

  /// Records the actual unit prices the helper paid.
  Future<ServiceRequestRecord> setItemActuals({
    required String requestId,
    required List<Map<String, dynamic>> items,
  });

  /// Cancels an unfinished errand as either participant.
  Future<ServiceRequestRecord> cancel({
    required String requestId,
    String? reason,
  });
}

const String _requestColumns =
    'id, customer_id, provider_id, service_area_id, category, status, title, '
    'description, pickup_address, pickup_barangay_id, pickup_purok_id, '
    'pickup_latitude, pickup_longitude, dropoff_address, dropoff_barangay_id, '
    'dropoff_purok_id, dropoff_latitude, dropoff_longitude, budget_centavos, '
    'quoted_fee_centavos, platform_fee_centavos, payment_method, '
    'requested_at, accepted_at, picked_up_at, delivered_at, cancelled_at, '
    'cancellation_reason, booked_for_someone, recipient_name, recipient_phone, '
    // Both ids point at profiles, so the embed must name its foreign key or
    // PostgREST rejects the whole read as ambiguous.
    'customer:profiles!service_requests_customer_id_fkey(full_name), '
    'provider:profiles!service_requests_provider_id_fkey(full_name), '
    'items:service_request_items(id, service_request_id, name, quantity, unit, '
    'estimated_unit_price_centavos, actual_unit_price_centavos, notes)';

class SupabasePasuyoRepository implements PasuyoRepository {
  SupabasePasuyoRepository(
    SurgoBackend backend, {
    this._writer,
  })  : _backend = backend;

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;

  SurgoWriteBackend get _write {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot submit errand changes.',
      );
    }
    return writer;
  }

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

  @override
  Future<ServiceRequestRecord> createRequest({
    required PasuyoCategory category,
    required String title,
    required String pickupAddress,
    required String pickupBarangayId,
    required int quotedFeeCentavos,
    List<Map<String, dynamic>> items = const [],
    String? description,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? dropoffAddress,
    String? dropoffBarangayId,
    String? dropoffPurokId,
    double? dropoffLatitude,
    double? dropoffLongitude,
    bool bookedForSomeone = false,
    String? recipientName,
    String? recipientPhone,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'create_service_request',
      params: {
        'p_category': pasuyoCategoryTokenToDb(category),
        'p_title': title,
        'p_pickup_address': pickupAddress,
        'p_pickup_barangay_id': pickupBarangayId,
        'p_quoted_fee_centavos': quotedFeeCentavos,
        'p_items': items,
        if (description != null) 'p_description': description,
        if (pickupPurokId != null) 'p_pickup_purok_id': pickupPurokId,
        if (pickupLatitude != null) 'p_pickup_latitude': pickupLatitude,
        if (pickupLongitude != null) 'p_pickup_longitude': pickupLongitude,
        if (dropoffAddress != null) 'p_dropoff_address': dropoffAddress,
        if (dropoffBarangayId != null)
          'p_dropoff_barangay_id': dropoffBarangayId,
        if (dropoffPurokId != null) 'p_dropoff_purok_id': dropoffPurokId,
        if (dropoffLatitude != null) 'p_dropoff_latitude': dropoffLatitude,
        if (dropoffLongitude != null) 'p_dropoff_longitude': dropoffLongitude,
        'p_booked_for_someone': bookedForSomeone,
        if (recipientName != null) 'p_recipient_name': recipientName,
        if (recipientPhone != null) 'p_recipient_phone': recipientPhone,
      },
    ));
    return ServiceRequestRecord.fromRow(row);
  }

  @override
  Future<ServiceRequestRecord> accept(String requestId) async {
    final row = _rpcRow(await _write.rpc(
      function: 'accept_service_request',
      params: {'p_request_id': requestId},
    ));
    return ServiceRequestRecord.fromRow(row);
  }

  @override
  Future<ServiceRequestRecord> advance({
    required String requestId,
    required PasuyoStatus status,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'advance_service_status',
      params: {
        'p_request_id': requestId,
        'p_status': pasuyoStatusToDb(status),
      },
    ));
    return ServiceRequestRecord.fromRow(row);
  }

  @override
  Future<ServiceRequestRecord> setItemActuals({
    required String requestId,
    required List<Map<String, dynamic>> items,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'set_service_item_actuals',
      params: {'p_request_id': requestId, 'p_items': items},
    ));
    return ServiceRequestRecord.fromRow(row);
  }

  @override
  Future<ServiceRequestRecord> cancel({
    required String requestId,
    String? reason,
  }) async {
    final row = _rpcRow(await _write.rpc(
      function: 'cancel_service_request',
      params: {
        'p_request_id': requestId,
        if (reason != null) 'p_reason': reason,
      },
    ));
    return ServiceRequestRecord.fromRow(row);
  }

  Map<String, dynamic> _rpcRow(dynamic result) {
    if (result is Map) return Map<String, dynamic>.from(result);
    throw RepositoryFailure.invalidData(
      'The errand service returned an unexpected shape.',
    );
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

  @override
  Future<ServiceRequestRecord> createRequest({
    required PasuyoCategory category,
    required String title,
    required String pickupAddress,
    required String pickupBarangayId,
    required int quotedFeeCentavos,
    List<Map<String, dynamic>> items = const [],
    String? description,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? dropoffAddress,
    String? dropoffBarangayId,
    String? dropoffPurokId,
    double? dropoffLatitude,
    double? dropoffLongitude,
    bool bookedForSomeone = false,
    String? recipientName,
    String? recipientPhone,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded errands are simulated by AppState.',
    );
  }

  @override
  Future<ServiceRequestRecord> accept(String requestId) async {
    throw RepositoryFailure.unsupported(
      'Seeded errands are simulated by AppState.',
    );
  }

  @override
  Future<ServiceRequestRecord> advance({
    required String requestId,
    required PasuyoStatus status,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded errands are simulated by AppState.',
    );
  }

  @override
  Future<ServiceRequestRecord> setItemActuals({
    required String requestId,
    required List<Map<String, dynamic>> items,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded errands are simulated by AppState.',
    );
  }

  @override
  Future<ServiceRequestRecord> cancel({
    required String requestId,
    String? reason,
  }) async {
    throw RepositoryFailure.unsupported(
      'Seeded errands are simulated by AppState.',
    );
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
