import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import '../data/db_models.dart';

/// Resolves the device's real, live GPS position for Map V1.
///
/// Mock riders, rental vehicles, and passengers all use the fixed
/// coordinates baked into `assets/data/surgo_map_v1_mock_data.json` — only
/// the current user's own marker comes from here. If permission is denied
/// or location services are off, callers should fall back to
/// `DbService.instance.mapConfig.defaultCenter` (Tandag City).
class LocationService {
  LocationService._internal();
  static final LocationService instance = LocationService._internal();

  /// Result of the most recent successful GPS fix, cached so the "locate
  /// me" button and initial map centering don't both trigger a fresh
  /// hardware read back-to-back.
  MapPoint? lastKnownPosition;

  /// Attempts to get the user's current position.
  ///
  /// Returns `null` (never throws) if location services are disabled or
  /// permission isn't granted — callers should fall back to Tandag City in
  /// that case. On mobile this walks the full geolocator permission flow:
  /// checks if the location service is on, checks current permission
  /// status, and requests permission if it's the first time asking.
  ///
  /// Web skips that pre-flight entirely. The browser's Permissions API
  /// isn't available everywhere, so `Geolocator.checkPermission()` can
  /// report `denied` even after the user has already granted access — the
  /// browser prompt surfaces on `getCurrentPosition()` itself instead.
  Future<MapPoint?> getCurrentLocation() async {
    try {
      if (!kIsWeb) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) return null;

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
          if (permission == LocationPermission.denied) return null;
        }
        if (permission == LocationPermission.deniedForever) return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      final point = MapPoint(position.latitude, position.longitude);
      lastKnownPosition = point;
      return point;
    } catch (_) {
      // Emulators without a fused location provider, timeouts, or a user
      // that dismisses the OS permission dialog all land here — treat it
      // the same as "no permission" and let the caller fall back.
      return null;
    }
  }
}
