import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart' as ml;
import '../data/db_models.dart';
import '../services/location_service.dart';
import '../services/map_bootstrap.dart';
import '../theme/app_colors.dart';
import 'flow_scaffold.dart';
import 'surgo_notice.dart';

// ---------------------------------------------------------------------------
// Tile configuration
//
// Provide the MapTiler API key at build time:
//
//   flutter run  --dart-define=MAPTILER_API_KEY=your_key_here
//   flutter build apk --dart-define=MAPTILER_API_KEY=your_key_here
//   flutter build web --dart-define=MAPTILER_API_KEY=your_key_here
//
// See docs/MAP_TILES.md for domain/HTTP-referrer restrictions and
// Android/iOS key-protection guidance.
//
// Without a key, render a labelled offline preview, never unrestricted tiles.
// ---------------------------------------------------------------------------

bool get _hasMapTilerKey => MapBootstrap.hasKey;
const _kRouteBlue = Color(0xFF4A90E2);
const _kAttribution = '© MapTiler · © OpenStreetMap contributors';

/// Shown when no key is configured.
const _kMissingKeyMessage =
    'MAPTILER_API_KEY not set.\n'
    'Build with --dart-define=MAPTILER_API_KEY=<key>';

/// Maps a mock-data `vehicle_type` / `marker_type` string to the icon shown
/// inside a SurGo purple pin, per `marker_config` in the Map V1 JSON.
IconData surgoMarkerIcon(String type) {
  switch (type) {
    case 'motorcycle':
      return Icons.two_wheeler;
    case 'tricycle':
      return Icons.electric_rickshaw;
    case 'van':
      return Icons.airport_shuttle;
    case 'multicab':
      return Icons.local_shipping_outlined;
    case 'rental':
      return Icons.directions_car_filled;
    case 'passenger':
      return Icons.person;
    case 'user_location':
      return Icons.my_location;
    default:
      return Icons.place;
  }
}

/// One tappable point on a [SurgoMap].
class SurgoMapMarker {
  final String id;
  final MapPoint position;
  final IconData icon;

  /// Bottom-sheet title, e.g. a rider's name or a vehicle's name.
  final String title;

  /// Short line under the title, e.g. "Motorcycle · Purok 2, Telaje".
  final String subtitle;

  /// Extra label/value rows shown in the info sheet (rating, fare, price,
  /// status, etc.) — kept generic so every marker type can supply whatever
  /// is relevant without needing its own sheet layout.
  final List<MapEntry<String, String>> details;

  /// Optional label + callback for a primary action button in the info
  /// sheet (e.g. "Book this ride", "Rent this vehicle"). Omit for markers
  /// that are informational only.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Slightly dims the marker (used for unavailable riders/vehicles).
  final bool faded;

  /// Optional destination accent; existing transport pins remain purple.
  final Color color;

  const SurgoMapMarker({
    required this.id,
    required this.position,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.details = const [],
    this.actionLabel,
    this.onAction,
    this.faded = false,
    this.color = AppColors.primary,
  });
}

/// Shared MapLibre/MapTiler surface with real device location and tappable
/// transport pins. Without a key it uses an explicitly labelled offline grid.
/// Route geometry is supplied by the caller: this widget does not calculate
/// road routes, ETAs, or driver positions.
class SurgoMap extends StatefulWidget {
  /// The neutral route color used while a request is still being arranged.
  static const defaultRouteColor = _kRouteBlue;

  final List<SurgoMapMarker> markers;

  /// If true, resolves the device's live GPS position on load and shows a
  /// "you are here" marker + a locate-me button. Falls back to
  /// [fallbackCenter] (Tandag City by default) if permission is denied.
  final bool showUserLocation;

  final MapPoint? fallbackCenter;
  final double initialZoom;

  /// When false, the map is a static, non-interactive preview (used inside
  /// cards) — panning/zooming/tapping markers is disabled.
  final bool interactive;

  final double height;
  final BorderRadius? borderRadius;

  /// Caller-supplied geometry, never generated road routing.
  final List<MapPoint> route;
  final bool routeIsEstimate;

  /// Color of the drawn route. Defaults to the neutral blue used while a
  /// request is still being arranged; active trips pass the success green.
  final Color routeColor;

  /// Native map gestures. Inline previews disable these so a drag that lands
  /// on the map scrolls the surrounding form instead of panning the map.
  final bool panEnabled;
  final bool zoomEnabled;
  final bool rotateEnabled;
  final bool pitchEnabled;

  /// Draws expanding search rings around this point (the pickup while the app
  /// looks for a rider). Purely visual; it never changes the map camera.
  final MapPoint? pulseCenter;

  /// Space occupied by screen overlays, especially persistent bottom sheets.
  /// Route bounds and marker endpoints are fitted inside the remaining area.
  final EdgeInsets cameraPadding;

  /// Called when the user taps the basemap itself. Marker taps are excluded,
  /// so a screen can turn a tap into a dropped pin or a reverse-geocoded
  /// address without also firing when a pin is opened.
  final ValueChanged<MapPoint>? onMapTap;

  /// Called when the user long-presses the basemap; used to drop a pin on
  /// touch devices where a precise tap is hard.
  final ValueChanged<MapPoint>? onMapLongPress;

  const SurgoMap({
    super.key,
    required this.markers,
    this.showUserLocation = true,
    this.fallbackCenter,
    this.initialZoom = 15,
    this.interactive = true,
    this.height = 260,
    this.borderRadius,
    this.route = const [],
    this.routeIsEstimate = false,
    this.routeColor = _kRouteBlue,
    this.panEnabled = true,
    this.zoomEnabled = true,
    this.rotateEnabled = true,
    this.pitchEnabled = true,
    this.pulseCenter,
    this.cameraPadding = EdgeInsets.zero,
    this.onMapTap,
    this.onMapLongPress,
  });

  @override
  State<SurgoMap> createState() => _SurgoMapState();
}

class _SurgoMapState extends State<SurgoMap>
    with TickerProviderStateMixin {
  // MapLibre owns the controller's native lifetime.
  ml.MapController? _mapController;
  Timer? _loadTimeout;
  Timer? _readyTimer;
  int _mapGeneration = 0;
  bool _waitingForIdle = true;
  bool _loadTimedOut = false;
  bool _styleLoaded = false;
  late final AnimationController _routeAnimation;

  /// Interpolates a marker between its old and new coordinates so live rider
  /// fixes glide instead of jumping.
  late final AnimationController _markerAnimation;
  final Map<String, MapPoint> _markerFrom = {};
  late List<MapPoint> _route;
  late Set<String> _markerIds;
  MapPoint? _userPosition;
  MapPoint? _previewCenter;
  double? _previewZoom;
  _MapFrame? _gestureFrame;
  Offset _gestureAnchor = Offset.zero;
  Size _mapSize = Size.zero;
  bool _locating = false;
  bool _deniedOnce = false;
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _route = List.of(widget.route);
    _markerIds = widget.markers.map((m) => m.id).toSet();
    _routeAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _markerAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _markerFrom.clear();
      });
    if (_hasMapTilerKey) _startLoadTimeout();
    if (widget.showUserLocation) _resolveUserLocation(recenter: false);
  }

  void _startLoadTimeout() {
    _loadTimeout?.cancel();
    final generation = _mapGeneration;
    _loadTimeout = Timer(const Duration(seconds: 15), () {
      if (!mounted || generation != _mapGeneration || !_waitingForIdle) return;
      // A drawn style means the map is usable even if the engine never
      // reports "idle"; the engine gives no load errors to distinguish them.
      if (_styleLoaded) {
        _markReady();
        return;
      }
      setState(() => _loadTimedOut = true);
    });
  }

  void _markReady() {
    if (!mounted || !_waitingForIdle) return;
    _loadTimeout?.cancel();
    _readyTimer?.cancel();
    setState(() {
      _waitingForIdle = false;
      _loadTimedOut = false;
    });
  }

  void _retryMap() {
    if (!mounted) return;
    setState(() {
      _mapGeneration++;
      _mapController = null;
      _waitingForIdle = true;
      _loadTimedOut = false;
      _styleLoaded = false;
    });
    _startLoadTimeout();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion != reduceMotion) {
      _reduceMotion = reduceMotion;
      _animateRoute();
    }
  }

  @override
  void didUpdateWidget(covariant SurgoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final routeChanged = !_samePoints(_route, widget.route);
    final markerIds = widget.markers.map((m) => m.id).toSet();
    final markersChanged =
        _markerIds.length != markerIds.length ||
        !_markerIds.containsAll(markerIds);
    _markerIds = markerIds;
    final previous = {for (final m in oldWidget.markers) m.id: m};
    var markerMoved = false;
    for (final marker in widget.markers) {
      final old = previous[marker.id];
      if (old == null ||
          (old.position.latitude == marker.position.latitude &&
              old.position.longitude == marker.position.longitude)) {
        continue;
      }
      // Start from wherever the pin is mid-glide rather than snapping back.
      _markerFrom[marker.id] = _displayPoint(marker.id, old.position);
      markerMoved = true;
    }
    if (markerMoved) {
      if (_reduceMotion == true) {
        _markerFrom.clear();
      } else {
        _markerAnimation.forward(from: 0);
      }
    }
    if (routeChanged) {
      _route = List.of(widget.route);
      _animateRoute();
    } else if (oldWidget.routeColor != widget.routeColor) {
      // A request that turns green when a provider is found should draw the
      // found route again, not just recolor a line that already finished.
      _animateRoute();
    }
    if (!widget.showUserLocation) {
      _userPosition = null;
      _locating = false;
    } else if (!oldWidget.showUserLocation) {
      _resolveUserLocation(recenter: false);
    }
    if (routeChanged ||
        markersChanged ||
        oldWidget.cameraPadding != widget.cameraPadding ||
        oldWidget.fallbackCenter?.latitude != widget.fallbackCenter?.latitude ||
        oldWidget.fallbackCenter?.longitude !=
            widget.fallbackCenter?.longitude ||
        oldWidget.initialZoom != widget.initialZoom ||
        oldWidget.showUserLocation != widget.showUserLocation) {
      _previewCenter = null;
      _previewZoom = null;
      _scheduleCameraFit();
    }
  }

  void _animateRoute() {
    if (_reduceMotion == true || _route.length < 2) {
      _routeAnimation.value = 1;
    } else {
      _routeAnimation.forward(from: 0);
    }
  }

  /// Where a pin is drawn right now: its live target, or a point along the
  /// glide from the previous fix while [_markerAnimation] is running.
  MapPoint _displayPoint(String id, MapPoint target) {
    final from = _markerFrom[id];
    if (from == null) return target;
    final t = Curves.easeInOutCubic.transform(_markerAnimation.value);
    return MapPoint(
      from.latitude + (target.latitude - from.latitude) * t,
      from.longitude + (target.longitude - from.longitude) * t,
    );
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    _readyTimer?.cancel();
    _mapController = null;
    _routeAnimation.dispose();
    _markerAnimation.dispose();
    super.dispose();
  }

  Future<void> _resolveUserLocation({bool recenter = true}) async {
    setState(() => _locating = true);
    final point = await LocationService.instance.getCurrentLocation();
    if (!mounted || !widget.showUserLocation) return;
    setState(() {
      _locating = false;
      if (point != null) {
        _userPosition = point;
        _deniedOnce = false;
        if (recenter) {
          _previewCenter = point;
          _previewZoom = widget.initialZoom;
        } else if (_route.isEmpty) {
          _previewCenter = null;
          _previewZoom = null;
        }
      } else {
        _deniedOnce = true;
      }
    });
    if (point == null) return;
    if (recenter) {
      await _mapController?.moveCamera(
        center: _geographic(point),
        zoom: widget.initialZoom,
        padding: _frame.padding,
      );
    } else if (_route.isEmpty) {
      _scheduleCameraFit();
    }
  }

  MapPoint get _fallback =>
      widget.fallbackCenter ?? const MapPoint(9.0785, 126.1985);

  _MapFrame get _frame {
    // Reserve space for the pin bodies, labels, and missing-key warning. The
    // inset shrinks with short preview maps: a fixed 76/70 inset would swallow
    // almost the whole viewport and MapLibre would fit the entire province.
    final height = _mapSize.height;
    final pinPadding = height > 0 && height.isFinite
        ? EdgeInsets.fromLTRB(
            36,
            math.min(76, height * 0.22),
            36,
            math.min(70, height * 0.20),
          )
        : const EdgeInsets.fromLTRB(36, 76, 36, 70);
    final frame = _MapFrame.fit(
      size: _mapSize,
      center: _previewCenter ?? _userPosition ?? _fallback,
      zoom: _previewZoom ?? widget.initialZoom,
      points: _previewCenter != null || _route.isEmpty
          ? const []
          : [..._route, ...widget.markers.map((m) => m.position)],
      padding: widget.cameraPadding + pinPadding,
    );
    if (!_mapSize.isEmpty) {
      // Keep the fitted offline camera until an intentional fit or gesture.
      // Rider positions must not recompute bounds on every rebuild.
      _previewCenter ??= frame.center;
      _previewZoom ??= frame.zoom;
    }
    return frame;
  }

  void _scheduleCameraFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitCamera();
    });
  }

  Future<void> _fitCamera() async {
    if (_mapSize.isEmpty) return;
    final frame = _frame;
    await _mapController?.moveCamera(
      center: _geographic(frame.center),
      zoom: frame.zoom,
      padding: frame.padding,
    );
  }

  Widget _markerWidget(SurgoMapMarker marker) => Semantics(
    label: marker.title,
    button: widget.interactive,
    child: GestureDetector(
      key: ValueKey('surgo-marker-${marker.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.interactive
          ? () => _showMarkerSheet(context, marker)
          : null,
      child: _SurgoPin(
        icon: marker.icon,
        faded: marker.faded,
        color: marker.color,
      ),
    ),
  );

  Widget _renderer(_MapFrame frame, List<MapPoint> drawnRoute) {
    final generation = _mapGeneration;
    final features = drawnRoute.length < 2
        ? <ml.Feature<ml.LineString>>[]
        : [
            ml.Feature<ml.LineString>(
              id: 'surgo-route',
              geometry: ml.LineString.from(drawnRoute.map(_geographic)),
            ),
          ];
    final dashes = widget.routeIsEstimate ? const [2, 2] : null;
    return IgnorePointer(
      ignoring: !widget.interactive,
      child: ml.MapLibreMap(
        key: ValueKey('surgo-map-$generation'),
        options: ml.MapOptions(
          initStyle: MapBootstrap.instance.styleSource,
          initCenter: _geographic(frame.center),
          initZoom: frame.zoom,
          gestures: widget.interactive
              ? ml.MapGestures(
                  pan: widget.panEnabled,
                  zoom: widget.zoomEnabled,
                  rotate: widget.rotateEnabled,
                  pitch: widget.pitchEnabled,
                )
              : const ml.MapGestures.none(),
        ),
        onMapCreated: (controller) {
          if (!mounted || generation != _mapGeneration) return;
          _mapController = controller;
          _fitCamera();
        },
        onStyleLoaded: (_) {
          if (!mounted || generation != _mapGeneration) return;
          // The basemap is styled and painting; tiles finish on their own.
          _styleLoaded = true;
          _readyTimer?.cancel();
          _readyTimer = Timer(const Duration(milliseconds: 1200), _markReady);
          _animateRoute();
        },
        onEvent: (event) {
          if (!mounted || generation != _mapGeneration) return;
          if (event is ml.MapEventIdle) _markReady();
          if (event is ml.MapEventClick && widget.onMapTap != null) {
            _handleMapPress(event, widget.onMapTap!);
          }
          if (event is ml.MapEventLongClick && widget.onMapLongPress != null) {
            _handleMapPress(event, widget.onMapLongPress!);
          }
        },
        layers: [
          ml.PolylineLayer(
            polylines: features,
            color: widget.routeColor.withValues(alpha: 0.18),
            width: 10,
            dashArray: dashes,
          ),
          ml.PolylineLayer(
            polylines: features,
            color: widget.routeColor,
            width: 4,
            dashArray: dashes,
          ),
        ],
        children: [
          ml.WidgetLayer(
            allowInteraction: widget.interactive,
            markers: [
              if (widget.pulseCenter != null)
                ml.Marker(
                  point: _geographic(widget.pulseCenter!),
                  size: const Size(160, 160),
                  alignment: Alignment.center,
                  child: const IgnorePointer(
                    child: SbSearchRadar(size: 160, showIcon: false),
                  ),
                ),
              for (final marker in widget.markers)
                ml.Marker(
                  point: _geographic(
                    _displayPoint(marker.id, marker.position),
                  ),
                  size: const Size(42, 48),
                  alignment: Alignment.bottomCenter,
                  child: _markerWidget(marker),
                ),
              if (_userPosition != null)
                ml.Marker(
                  point: _geographic(_userPosition!),
                  size: const Size(26, 26),
                  child: const _UserDot(),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _offlinePreview(_MapFrame frame, List<MapPoint> drawnRoute) {
    return GestureDetector(
      key: const ValueKey('surgo-offline-preview'),
      behavior: HitTestBehavior.opaque,
      onScaleStart: !widget.interactive
          ? null
          : (details) {
              _gestureFrame = frame;
              _gestureAnchor =
                  _worldPoint(frame.center) +
                  (details.localFocalPoint - frame.screenCenter) / frame.scale;
            },
      onScaleUpdate: !widget.interactive
          ? null
          : (details) {
              final start = _gestureFrame;
              if (start == null) return;
              final zoom = (start.zoom + math.log(details.scale) / math.ln2)
                  .clamp(0.0, 22.0);
              final scale = 512.0 * math.pow(2, zoom);
              setState(() {
                _previewCenter = _fromWorldPoint(
                  _gestureAnchor -
                      (details.localFocalPoint - start.screenCenter) / scale,
                );
                _previewZoom = zoom;
              });
            },
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            key: const ValueKey('surgo-offline-canvas'),
            painter: _PreviewPainter(
              frame: frame,
              route: drawnRoute,
              routeIsEstimate: widget.routeIsEstimate,
              routeColor: widget.routeColor,
            ),
          ),
          for (final marker in widget.markers)
            Positioned(
              left:
                  frame.project(_displayPoint(marker.id, marker.position)).dx -
                  21,
              top:
                  frame.project(_displayPoint(marker.id, marker.position)).dy -
                  48,
              width: 42,
              height: 48,
              child: _markerWidget(marker),
            ),
          if (widget.pulseCenter != null)
            Positioned(
              left: frame.project(widget.pulseCenter!).dx - 80,
              top: frame.project(widget.pulseCenter!).dy - 80,
              width: 160,
              height: 160,
              child: const IgnorePointer(
                child: SbSearchRadar(size: 160, showIcon: false),
              ),
            ),
          if (_userPosition != null)
            Positioned(
              left: frame.project(_userPosition!).dx - 13,
              top: frame.project(_userPosition!).dy - 13,
              width: 26,
              height: 26,
              child: const _UserDot(),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.circular(18),
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            if (_mapSize != size) {
              _mapSize = size;
              _previewCenter = null;
              _previewZoom = null;
              _scheduleCameraFit();
            }
            return AnimatedBuilder(
              animation: Listenable.merge([
                _routeAnimation,
                _markerAnimation,
              ]),
              builder: (context, _) {
                final frame = _frame;
                final drawnRoute = _partialRoute(_route, _routeAnimation.value);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_hasMapTilerKey)
                      _renderer(frame, drawnRoute)
                    else
                      _offlinePreview(frame, drawnRoute),
                    if (!_hasMapTilerKey ||
                        (_route.length >= 2 && widget.routeIsEstimate))
                      Positioned(
                        left: widget.cameraPadding.left + 12,
                        right: widget.cameraPadding.right + 12,
                        top: widget.cameraPadding.top + 10,
                        child: IgnorePointer(
                          child: _MapLabel(
                            text: [
                              if (!_hasMapTilerKey) 'Offline map preview',
                              if (_route.length >= 2)
                                widget.routeIsEstimate
                                    ? 'Straight-line estimate'
                                    : 'Road route · offline basemap',
                            ].join('\n'),
                          ),
                        ),
                      ),
                    Positioned(
                      left: widget.cameraPadding.left + 8,
                      right:
                          widget.cameraPadding.right +
                          (widget.showUserLocation && widget.interactive
                              ? 60
                              : 8),
                      bottom: widget.cameraPadding.bottom + 6,
                      child: IgnorePointer(
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: _MapLabel(
                            text: _hasMapTilerKey
                                ? _kAttribution
                                : _kMissingKeyMessage,
                            warning: !_hasMapTilerKey,
                          ),
                        ),
                      ),
                    ),
                    if (_hasMapTilerKey && _waitingForIdle)
                      Positioned(
                        left: widget.cameraPadding.left,
                        top: widget.cameraPadding.top,
                        right: widget.cameraPadding.right,
                        bottom: widget.cameraPadding.bottom,
                        child: Center(
                          child: Material(
                            color: AppColors.panel,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!_loadTimedOut) ...[
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                  Text(
                                    _loadTimedOut
                                        ? 'Map did not finish loading.'
                                        : 'Loading map…',
                                  ),
                                  if (_loadTimedOut)
                                    TextButton(
                                      onPressed: _retryMap,
                                      child: const Text('Retry'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.showUserLocation && widget.interactive)
                      Positioned(
                        right: widget.cameraPadding.right + 10,
                        bottom: widget.cameraPadding.bottom + 10,
                        child: _LocateMeButton(
                          locating: _locating,
                          denied: _deniedOnce,
                          onTap: () => _resolveUserLocation(recenter: true),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// A basemap press should not also drop a pin when it landed on one of our
  /// own pins. The platform widget layer usually swallows those taps, but the
  /// screen-point check keeps the behavior honest on every platform.
  void _handleMapPress(
    ml.MapEventUserInput event,
    ValueChanged<MapPoint> callback,
  ) {
    final controller = _mapController;
    if (controller != null) {
      try {
        final markerScreens = controller.toScreenLocations([
          for (final marker in widget.markers)
            _geographic(_displayPoint(marker.id, marker.position)),
          if (_userPosition != null) _geographic(_userPosition!),
        ]);
        for (final markerPoint in markerScreens) {
          if ((markerPoint - event.screenPoint).distance <= 26) return;
        }
      } catch (_) {
        // Projection is unavailable while the camera is rebuilding; a press
        // that cannot be checked still counts as a basemap press.
      }
    }
    callback(
      MapPoint(event.point.lat, event.point.lon),
    );
  }

  void _showMarkerSheet(BuildContext context, SurgoMapMarker m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MarkerInfoSheet(marker: m),
    );
  }
}

/// Custom purple "filled location pin" marker with an icon inside —
/// matches the SurGo brand marker style used across every role's map.
class _SurgoPin extends StatelessWidget {
  final IconData icon;
  final bool faded;
  final Color color;
  const _SurgoPin({
    required this.icon,
    required this.faded,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final pinColor = faded ? AppColors.muted2 : color;
    final pin = Opacity(
      opacity: faded ? 0.55 : 1,
      child: SizedBox(
        width: 42,
        height: 48,
        child: CustomPaint(
          painter: _PinPainter(color: pinColor),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(child: Icon(icon, color: Colors.white, size: 18)),
          ),
        ),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) return pin;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1800),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.85, end: 1),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        child: pin,
        builder: (_, scale, child) => Transform.scale(
          scale: scale,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
      builder: (_, progress, child) => Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -8 * progress,
            top: -8 * progress,
            child: IgnorePointer(
              child: Container(
                width: 42 + 16 * progress,
                height: 42 + 16 * progress,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: pinColor.withValues(alpha: 0.12 * (1 - progress)),
                ),
              ),
            ),
          ),
          if (child != null) child,
        ],
      ),
    );
  }
}

class _PinPainter extends CustomPainter {
  final Color color;
  const _PinPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final r = w / 2;
    final center = Offset(r, r);

    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: r))
      ..moveTo(center.dx - r * 0.62, center.dy + r * 0.55)
      ..lineTo(center.dx, size.height)
      ..lineTo(center.dx + r * 0.62, center.dy + r * 0.55)
      ..close();

    canvas.drawShadow(path, Colors.black, 3, true);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawCircle(center, r, Paint()..color = color);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = AppColors.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _PinPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The device's own live-GPS position — a small blue "you are here" dot,
/// distinct from the purple mock-transport pins.
class _UserDot extends StatelessWidget {
  const _UserDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF4A90E2).withValues(alpha: 0.25),
      ),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF4A90E2),
            border: Border.all(color: Colors.white, width: 2.5),
          ),
        ),
      ),
    );
  }
}

class _LocateMeButton extends StatelessWidget {
  final bool locating;
  final bool denied;
  final VoidCallback onTap;
  const _LocateMeButton({
    required this.locating,
    required this.denied,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.panel2,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: locating
            ? null
            : () {
                onTap();
                if (denied) {
                  SurgoNotice.show(
                    context,
                    'Location permission is off — enable it in system settings to center on you.',
                    tone: SbNoticeTone.warning,
                  );
                }
              },
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.borderLight),
          ),
          child: locating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primaryLight,
                  ),
                )
              : const Icon(
                  Icons.my_location,
                  color: AppColors.primaryLight,
                  size: 20,
                ),
        ),
      ),
    );
  }
}

class _MarkerInfoSheet extends StatelessWidget {
  final SurgoMapMarker marker;
  const _MarkerInfoSheet({required this.marker});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: marker.color,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(marker.icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        marker.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        marker.subtitle,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (marker.details.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.panel2,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    for (final d in marker.details)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              d.key,
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 12.5,
                              ),
                            ),
                            Text(
                              d.value,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (marker.actionLabel != null && marker.onAction != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    marker.onAction!();
                  },
                  child: Text(
                    marker.actionLabel!,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MapLabel extends StatelessWidget {
  final String text;
  final bool warning;
  const _MapLabel({required this.text, this.warning = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: warning ? AppColors.primaryLight : Colors.white70,
        fontSize: warning ? 10 : 9,
        height: 1.4,
      ),
    ),
  );
}

ml.Geographic _geographic(MapPoint point) =>
    ml.Geographic(lat: point.latitude, lon: point.longitude);

bool _samePoints(List<MapPoint> a, List<MapPoint> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
      return false;
    }
  }
  return true;
}

// Normalized Web Mercator, shared by offline geometry and native camera fitting.
Offset _worldPoint(MapPoint point) {
  final latitude = point.latitude.clamp(-85.05112878, 85.05112878);
  return Offset(
    (point.longitude + 180) / 360,
    (1 - math.log(math.tan(math.pi / 4 + latitude * math.pi / 360)) / math.pi) /
        2,
  );
}

MapPoint _fromWorldPoint(Offset point) => MapPoint(
  (2 * math.atan(math.exp(math.pi * (1 - 2 * point.dy))) - math.pi / 2) *
      180 /
      math.pi,
  ((point.dx * 360) % 360) - 180,
);

/// Same padded center and zoom on both renderers; pins keep their geographic
/// positions rather than being distributed decoratively over the preview.
class _MapFrame {
  final Size size;
  final MapPoint center;
  final double zoom;
  final EdgeInsets padding;
  const _MapFrame({
    required this.size,
    required this.center,
    required this.zoom,
    required this.padding,
  });

  factory _MapFrame.fit({
    required Size size,
    required MapPoint center,
    required double zoom,
    required List<MapPoint> points,
    required EdgeInsets padding,
  }) {
    // When overlays exceed the map, retain at least one pixel of viewport.
    final horizontal = math.min(
      1.0,
      math.max(0.0, size.width - 1) / math.max(1.0, padding.horizontal),
    );
    final vertical = math.min(
      1.0,
      math.max(0.0, size.height - 1) / math.max(1.0, padding.vertical),
    );
    final effectivePadding = EdgeInsets.fromLTRB(
      padding.left * horizontal,
      padding.top * vertical,
      padding.right * horizontal,
      padding.bottom * vertical,
    );
    if (points.isNotEmpty && !size.isEmpty) {
      final projected = points.map(_worldPoint).toList();
      final west = projected.map((p) => p.dx).reduce(math.min);
      final east = projected.map((p) => p.dx).reduce(math.max);
      final north = projected.map((p) => p.dy).reduce(math.min);
      final south = projected.map((p) => p.dy).reduce(math.max);
      center = _fromWorldPoint(Offset((west + east) / 2, (north + south) / 2));
      final scale = math.min(
        (size.width - effectivePadding.horizontal) /
            math.max(1e-12, east - west),
        (size.height - effectivePadding.vertical) /
            math.max(1e-12, south - north),
      );
      zoom = math.min(zoom, math.log(scale / 512) / math.ln2);
    }
    return _MapFrame(
      size: size,
      center: center,
      zoom: zoom.clamp(0.0, 22.0),
      padding: effectivePadding,
    );
  }

  double get scale => 512.0 * math.pow(2, zoom);
  Offset get screenCenter => Offset(
    padding.left + (size.width - padding.horizontal) / 2,
    padding.top + (size.height - padding.vertical) / 2,
  );
  Offset project(MapPoint point) =>
      screenCenter + (_worldPoint(point) - _worldPoint(center)) * scale;
}

List<MapPoint> _partialRoute(List<MapPoint> route, double progress) {
  if (route.length < 2 || progress >= 1) return route;
  final points = route.map(_worldPoint).toList();
  final lengths = [
    for (var i = 1; i < points.length; i++)
      (points[i] - points[i - 1]).distance,
  ];
  final total = lengths.fold(0.0, (sum, length) => sum + length);
  var remaining = total * progress;
  final result = <MapPoint>[route.first];
  for (var i = 0; i < lengths.length; i++) {
    if (remaining <= lengths[i] && lengths[i] > 0) {
      result.add(
        _fromWorldPoint(
          Offset.lerp(points[i], points[i + 1], remaining / lengths[i])!,
        ),
      );
      return result;
    }
    result.add(route[i + 1]);
    remaining -= lengths[i];
  }
  return result;
}

/// A neutral coordinate grid, not roads, tiles, or fabricated driver tracking.
class _PreviewPainter extends CustomPainter {
  final _MapFrame frame;
  final List<MapPoint> route;
  final bool routeIsEstimate;
  final Color routeColor;
  const _PreviewPainter({
    required this.frame,
    required this.route,
    required this.routeIsEstimate,
    required this.routeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFF171B21), BlendMode.src);
    final gridPaint = Paint()
      ..color = const Color(0xFF252B33)
      ..strokeWidth = 1;
    final step = math.pow(2, -frame.zoom.round()) / 8 * frame.scale;
    final origin = frame.screenCenter - _worldPoint(frame.center) * frame.scale;
    for (var x = origin.dx % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = origin.dy % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (route.length < 2) return;
    final first = frame.project(route.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final point in route.skip(1)) {
      final offset = frame.project(point);
      path.lineTo(offset.dx, offset.dy);
    }
    var drawnPath = path;
    if (routeIsEstimate) {
      drawnPath = Path();
      for (final metric in path.computeMetrics()) {
        for (var distance = 0.0; distance < metric.length; distance += 16) {
          drawnPath.addPath(
            metric.extractPath(distance, math.min(distance + 8, metric.length)),
            Offset.zero,
          );
        }
      }
    }
    for (final width in [10.0, 4.0]) {
      canvas.drawPath(
        drawnPath,
        Paint()
          ..color = width == 10
              ? routeColor.withValues(alpha: 0.18)
              : routeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.route != route ||
      oldDelegate.routeIsEstimate != routeIsEstimate ||
      oldDelegate.routeColor != routeColor;
}
