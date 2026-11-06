import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db_models.dart';
import '../state/geo.dart';
import '../state/ride_status.dart';
import 'location_service.dart';

/// One reading of where the device is, carrying the quality data that decides
/// whether it may be shared.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.readAt,
    this.accuracyMeters,
    this.headingDegrees,
    this.speedKph,
  });

  final double latitude;
  final double longitude;
  final DateTime readAt;

  /// Radius of confidence in metres. A fix without it cannot be trusted,
  /// because nothing says whether it came from a tower or a GPS chip.
  final double? accuracyMeters;
  final double? headingDegrees;
  final double? speedKph;

  MapPoint get point => MapPoint(latitude, longitude);
}

/// Where an accepted fix goes.
///
/// A Supabase build calls the trusted publishing function; a seeded build keeps
/// the fix in memory so the prototype still shows a moving rider. Neither lets
/// the client write a table: the `authenticated` role holds no write privilege
/// at all, which is what keeps the privacy rules out of the app's hands.
abstract interface class LocationSink {
  Future<void> publish({
    required String rideId,
    required String riderId,
    required LocationFix fix,
  });
}

/// What the rider's side of location sharing can honestly report.
enum LocationShareStatus {
  /// Nothing to share: offline, no committed trip, or signed out.
  off,

  /// Fixes are being accepted and published.
  sharing,

  /// On a trip, but the newest fix is too old to draw as current.
  stale,

  /// Permission denied, location services off, or the sink keeps failing.
  unavailable,
}

/// The rules that decide whether a position may be written at all.
///
/// Kept apart from [LocationPublisher] so a test can prove a rule without a
/// clock, a stream or a database.
class LocationRules {
  /// A reading is only published for the rider committed to that trip.
  ///
  /// While a request is still being matched, any approved rider can read it, so
  /// publishing then would hand a live position to strangers.
  static bool isSharedTrip(RideStatus? status) =>
      status != null && status.isCommitted && !status.isTerminal;

  /// Rejects a fix that could not have come from a real device in the field.
  ///
  /// The bounds match the `check` constraints on `ride_locations`, so a
  /// rejected reading never reaches the database to be refused there. The age
  /// and accuracy ceilings are what stop a cached or tower-graded fix from
  /// being drawn as though the rider had just moved.
  static bool isTrustworthy(LocationFix fix, {required DateTime now}) {
    final latitude = fix.latitude;
    final longitude = fix.longitude;
    if (latitude.isNaN ||
        longitude.isNaN ||
        !latitude.isFinite ||
        !longitude.isFinite) {
      return false;
    }
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return false;
    }
    // Null island: a common default for a device that has never obtained a fix.
    if (latitude == 0 && longitude == 0) return false;

    final accuracy = fix.accuracyMeters;
    if (accuracy == null ||
        !accuracy.isFinite ||
        accuracy > maxAccuracyMeters) {
      return false;
    }
    return now.difference(fix.readAt).abs() <= maxFixAge;
  }

  /// True when a fix is worth a row.
  ///
  /// A rider idling at pickup would otherwise write one point every few seconds
  /// forever, so a move has to be real — or the last write has to be old enough
  /// that the trail needs a heartbeat to prove the rider is still there.
  static bool isWorthWriting({
    required LocationFix fix,
    required LocationFix? lastWritten,
    required DateTime now,
  }) {
    if (lastWritten == null) return true;
    if (now.difference(lastWritten.readAt) >= maxWriteInterval) return true;
    return haversineKm(lastWritten.point, fix.point) * 1000 >= minMoveMeters;
  }

  static bool isStale({
    required LocationFix? newest,
    required DateTime now,
    int? acceptedSecondsAgo,
  }) {
    if (newest == null) return true;
    final ageSeconds =
        acceptedSecondsAgo ?? now.difference(newest.readAt).inSeconds;
    return ageSeconds > staleAfter.inSeconds;
  }

  static const maxAccuracyMeters = 100.0;
  static const maxFixAge = Duration(seconds: 15);
  static const minMoveMeters = 25.0;
  static const maxWriteInterval = Duration(seconds: 30);
  static const staleAfter = Duration(seconds: 45);
}

/// Publishes the rider's position while a trip is committed, and stops.
///
/// [sync] is the only input: it is called on every app-state change, so the
/// publisher starts and stops itself as the rider goes online, accepts,
/// completes or cancels. Nothing here decides policy on its own from a timer.
class LocationPublisher extends ChangeNotifier {
  LocationPublisher({
    required LocationSink Function() sink,
    Future<Stream<LocationFix>?> Function()? positions,
    DateTime Function()? clock,
  })  : _sinkOf = sink,
        _positions = positions ?? LocationService.instance.trackPositions,
        _clock = clock ?? DateTime.now;

  /// Resolved per publish, so the publisher follows whichever data layer the
  /// app has installed instead of freezing the one it was built with.
  final LocationSink Function() _sinkOf;
  final Future<Stream<LocationFix>?> Function() _positions;
  final DateTime Function() _clock;

  StreamSubscription<LocationFix>? _subscription;
  Timer? _freshnessTimer;
  bool _starting = false;
  int _startToken = 0;

  String? _rideId;
  String? _riderId;
  String? _attemptedRideId;
  LocationFix? _lastWritten;
  int _consecutiveFailures = 0;
  bool _publishing = false;
  bool _disposed = false;

  /// Whether the app currently wants sharing on, which is what a finished
  /// permission round trip has to be checked against.
  bool get isSharingRequested => _rideId != null && _riderId != null;

  LocationShareStatus _status = LocationShareStatus.off;

  /// The last fix the sink accepted, for a screen that shows where sharing is
  /// at without re-reading the database.
  LocationFix? get lastWritten => _lastWritten;
  LocationShareStatus get status => _status;
  bool get isPublishing => _publishing;

  /// Re-evaluates whether this device may share, given the app's current state.
  ///
  /// [riderId] must be the signed-in profile and [status] its trip's status: a
  /// rider who is online but not assigned shares nothing, because there is no
  /// passenger entitled to the position yet.
  void sync({
    required bool online,
    required String? rideId,
    required String? riderId,
    required String? signedInProfileId,
    required RideStatus? status,
  }) {
    if (_disposed) return;
    final mayShare = online &&
        rideId != null &&
        riderId != null &&
        signedInProfileId != null &&
        riderId == signedInProfileId &&
        LocationRules.isSharedTrip(status);

    if (!mayShare) {
      stop();
      return;
    }
    _rideId = rideId;
    _riderId = riderId;
    if (_publishing || _starting) return;
    // A share that gave up on this trip — refused permission, or a sink that
    // would not take a fix — stays given-up. Otherwise every app-state change
    // mid-trip would re-run the permission round trip. The next trip is a new
    // chance, so a rider who grants permission later recovers without a
    // restart.
    if (_status == LocationShareStatus.unavailable &&
        _attemptedRideId == rideId) {
      return;
    }
    _startListening();
  }

  Future<void> _startListening() async {
    _starting = true;
    _attemptedRideId = _rideId;
    // Asking for permission takes a round trip to the user, and they can end
    // the trip while the prompt is up. The token makes a late answer belong to
    // a share that no longer exists.
    final token = ++_startToken;
    Stream<LocationFix>? stream;
    try {
      stream = await _positions();
    } catch (_) {
      stream = null;
    }
    _starting = false;
    if (_disposed || token != _startToken || !isSharingRequested) {
      return;
    }
    if (stream == null) {
      // Denied permission or location services off. The rider keeps the rest of
      // the app; only live position is unavailable, and it says so.
      _setStatus(LocationShareStatus.unavailable);
      return;
    }
    _publishing = true;
    _consecutiveFailures = 0;
    _setStatus(LocationShareStatus.sharing);
    _subscription = stream.listen(_onFix, onError: (Object _) {
      _pause(reason: LocationShareStatus.unavailable);
    });
    _freshnessTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => checkFreshness(),
    );
  }

  /// Stops sharing and forgets the trail, for the end of a trip or a sign-out.
  void stop() {
    // Bumped even when there is nothing to cancel, so a permission prompt the
    // rider is still looking at cannot start a share they have already ended.
    _startToken++;
    _starting = false;
    if (!_publishing && _status == LocationShareStatus.off) return;
    _subscription?.cancel();
    _subscription = null;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _publishing = false;
    _lastWritten = null;
    _consecutiveFailures = 0;
    _rideId = null;
    _riderId = null;
    _attemptedRideId = null;
    _setStatus(LocationShareStatus.off);
  }

  /// Drops the trail without pretending sharing was never asked for, used when
  /// the device stops being trustworthy while the trip is still live.
  void _pause({required LocationShareStatus reason}) {
    _subscription?.cancel();
    _subscription = null;
    _publishing = false;
    _setStatus(reason);
  }

  /// A screen, or a test, can ask the same question the timer asks.
  void checkFreshness() {
    if (!_publishing) return;
    if (LocationRules.isStale(newest: _lastWritten, now: _clock())) {
      _setStatus(LocationShareStatus.stale);
      return;
    }
    if (_status == LocationShareStatus.stale) {
      _setStatus(LocationShareStatus.sharing);
    }
  }

  Future<void> _onFix(LocationFix fix) async {
    if (!_publishing || _disposed) return;
    final now = _clock();
    if (!LocationRules.isTrustworthy(fix, now: now)) return;
    if (!LocationRules.isWorthWriting(
        fix: fix, lastWritten: _lastWritten, now: now)) {
      return;
    }
    final rideId = _rideId;
    final riderId = _riderId;
    if (rideId == null || riderId == null) return;
    try {
      await _sinkOf().publish(rideId: rideId, riderId: riderId, fix: fix);
      _lastWritten = fix;
      _consecutiveFailures = 0;
      _setStatus(LocationShareStatus.sharing);
    } catch (_) {
      // No connection, or the function refused. Sharing stays on so a returned
      // network resumes it, but a sink that never accepts is reported rather
      // than retried into a loop.
      if (++_consecutiveFailures < maxPublishFailures) return;
      _pause(reason: LocationShareStatus.unavailable);
    }
  }

  void _setStatus(LocationShareStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  static const maxPublishFailures = 3;

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _freshnessTimer?.cancel();
    super.dispose();
  }
}

/// Keeps published fixes in memory, for a seeded build and for tests.
class InMemoryLocationSink implements LocationSink {
  final Map<String, LocationFix> lastByRide = {};
  final List<LocationFix> published = [];

  @override
  Future<void> publish({
    required String rideId,
    required String riderId,
    required LocationFix fix,
  }) async {
    published.add(fix);
    lastByRide[rideId] = fix;
  }
}
