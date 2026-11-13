import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/db_models.dart';
import '../state/geo.dart';

/// The point a fraction [t] (0–1) of the way along [route] by distance.
///
/// Segment lengths come from [haversineKm], so a long rural leg does not move
/// the pin faster than a short one. Returns null when there is nothing to
/// interpolate.
MapPoint? pointAlongRoute(List<MapPoint> route, double t) {
  if (route.isEmpty) return null;
  if (route.length == 1) return route.first;
  final clamped = t.clamp(0.0, 1.0);
  final lengths = <double>[];
  var total = 0.0;
  for (var i = 1; i < route.length; i++) {
    final length = haversineKm(route[i - 1], route[i]);
    lengths.add(length);
    total += length;
  }
  if (total <= 0) return route.last;
  var remaining = total * clamped;
  for (var i = 0; i < lengths.length; i++) {
    if (remaining <= lengths[i] || i == lengths.length - 1) {
      final segment = lengths[i] == 0 ? 0.0 : remaining / lengths[i];
      final from = route[i];
      final to = route[i + 1];
      return MapPoint(
        from.latitude + (to.latitude - from.latitude) * segment,
        from.longitude + (to.longitude - from.longitude) * segment,
      );
    }
    remaining -= lengths[i];
  }
  return route.last;
}

/// Drives a simulated provider along [route] for one leg of a booking.
///
/// Only a provider assigned to an active booking should be passed an enabled
/// widget; idle providers stay on their seeded position. Positions are pushed
/// at a low rate on purpose: [SurgoMap] already eases each new fix, so frequent
/// updates would fight that glide.
class SimulatedRideMotion extends StatefulWidget {
  const SimulatedRideMotion({
    super.key,
    required this.enabled,
    required this.route,
    required this.legKey,
    required this.duration,
    required this.builder,
  });

  final bool enabled;
  final List<MapPoint> route;

  /// Changes when the booking or its status changes, restarting the leg.
  final String legKey;
  final Duration duration;

  /// Receives the simulated position, or null while motion is disabled.
  final Widget Function(BuildContext context, MapPoint? position) builder;

  @override
  State<SimulatedRideMotion> createState() => _SimulatedRideMotionState();
}

class _SimulatedRideMotionState extends State<SimulatedRideMotion> {
  static const _tick = Duration(milliseconds: 1200);

  Timer? _timer;
  DateTime? _startedAt;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      _restart();
    }
  }

  @override
  void didUpdateWidget(covariant SimulatedRideMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.legKey != widget.legKey ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.duration != widget.duration ||
        !_sameRoute(oldWidget.route, widget.route)) {
      _restart();
    }
  }

  bool _sameRoute(List<MapPoint> a, List<MapPoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    if (!widget.enabled || _reduceMotion || widget.route.length < 2) return;
    _startedAt = DateTime.now();
    _timer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      if (_progress() >= 1) _timer?.cancel();
      setState(() {});
    });
    setState(() {});
  }

  double _progress() {
    final started = _startedAt;
    if (started == null || widget.duration.inMilliseconds <= 0) return 0;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    return (elapsed / widget.duration.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.enabled && !_reduceMotion
        ? pointAlongRoute(widget.route, _progress())
        : null;
    return widget.builder(context, position);
  }
}
