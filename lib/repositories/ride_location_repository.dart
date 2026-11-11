import '../services/location_publisher.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'edge_functions.dart';
import 'repository_failure.dart';

/// Where a rider has been during one trip, newest first.
///
/// Read-only: the trail is written by the publishing function, never here, so
/// the privacy rules cannot be bypassed by a client that skipped them.
abstract interface class RideLocationRepository {
  Future<List<RideLocationRecord>> fetchRecentPositions(
    String rideId, {
    int limit,
  });
}

class SupabaseRideLocationRepository implements RideLocationRepository {
  SupabaseRideLocationRepository(SurgoBackend backend) : _backend = backend;

  static const _columns =
      'id, ride_id, rider_id, latitude, longitude, heading_degrees, '
      'speed_kph, recorded_at';

  final SurgoBackend _backend;

  @override
  Future<List<RideLocationRecord>> fetchRecentPositions(
    String rideId, {
    int limit = 20,
  }) async {
    final rows = await _backend.rows(
      table: 'ride_locations',
      columns: _columns,
      eq: {'ride_id': rideId},
      orderBy: 'recorded_at',
      ascending: false,
      limit: limit,
    );
    return [for (final row in rows) RideLocationRecord.fromRow(row)];
  }
}

/// Answers from the fixes this device has published.
///
/// A seeded build has no database, and the prototype's map is only convincing
/// when the rider dot actually moves, so the same in-memory sink the publisher
/// writes to is what a viewer reads.
class MockRideLocationRepository implements RideLocationRepository {
  MockRideLocationRepository(this.source);

  final InMemoryLocationSink source;

  @override
  Future<List<RideLocationRecord>> fetchRecentPositions(
    String rideId, {
    int limit = 20,
  }) async {
    final fix = source.lastByRide[rideId];
    if (fix == null) return const [];
    return [
      RideLocationRecord(
        id: 'live-$rideId',
        rideId: rideId,
        latitude: fix.latitude,
        longitude: fix.longitude,
        headingDegrees: fix.headingDegrees,
        speedKph: fix.speedKph,
        recordedAt: fix.readAt,
      ),
    ];
  }
}

/// Publishes a position by calling the trusted function.
///
/// The client sends what it measured and nothing else: the ride the caller is
/// assigned to, the timestamp and the row itself are decided server-side,
/// because a rider could otherwise append points to somebody else's trip.
class EdgeLocationSink implements LocationSink {
  /// With no invoker given, the app's Supabase client is resolved on first use,
  /// so building this sink in a seeded or test process cannot touch a client
  /// that was never initialized.
  EdgeLocationSink([EdgeInvoker? invoker]) : _provided = invoker;

  final EdgeInvoker? _provided;
  EdgeInvoker? _resolved;

  EdgeInvoker get _invoker {
    final provided = _provided;
    if (provided != null) return provided;
    try {
      return _resolved ??= SupabaseEdgeInvoker();
    } catch (_) {
      return const UnreachableEdgeInvoker();
    }
  }

  static const String functionName = 'publish-ride-location';

  /// Postgres will only accept a uuid into `ride_locations.ride_id`.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  @override
  Future<void> publish({
    required String rideId,
    required String riderId,
    required LocationFix fix,
  }) async {
    if (!_uuid.hasMatch(rideId)) {
      // A prototype request id cannot belong to a hosted trip, and calling the
      // function with it would be a wasted round trip that always fails.
      throw RepositoryFailure.unsupported(
        'This trip is not a hosted ride, so its position cannot be published.',
      );
    }
    await _invoker.invoke(functionName, {
      'ride_id': rideId,
      'latitude': fix.latitude,
      'longitude': fix.longitude,
      'heading_degrees': fix.headingDegrees,
      'speed_kph': fix.speedKph,
      'recorded_at': fix.readAt.toUtc().toIso8601String(),
    });
  }
}
