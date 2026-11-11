import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart'
    show MapLibrePlatform;
import 'package:surgo/data/db_models.dart';
import 'package:surgo/theme/app_colors.dart';
import 'package:surgo/widgets/surgo_map.dart';

const _center = MapPoint(9.0785, 126.1985);
const _pickup = MapPoint(9.065, 126.18);
const _destination = MapPoint(9.095, 126.22);
const _previewKey = ValueKey('surgo-offline-preview');
const _canvasKey = ValueKey('surgo-offline-canvas');
const _hasKey =
    bool.hasEnvironment('MAPTILER_API_KEY') &&
    String.fromEnvironment('MAPTILER_API_KEY') != '';

// No native view, network, style URL logging, or real key is used by this fake.
class _FakeMapPlatform extends MapLibrePlatform {
  final states = <_FakeMapState>[];

  @override
  ml.MapLibreMapState createWidgetState() {
    final state = _FakeMapState();
    states.add(state);
    return state;
  }
}

class _FakeMapState extends ml.MapLibreMapState {
  final moves = <(ml.Geographic?, double?, EdgeInsets)>[];

  @override
  Widget buildPlatformWidget(BuildContext context) => const SizedBox.expand();

  @override
  Future<void> moveCamera({
    ml.Geographic? center,
    double? zoom,
    double? bearing,
    double? pitch,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    moves.add((center, zoom, padding));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStyle extends ml.StyleController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SurgoMapMarker _marker(
  String id,
  MapPoint point, {
  bool faded = false,
  Color color = AppColors.primary,
  VoidCallback? onAction,
}) => SurgoMapMarker(
  id: id,
  position: point,
  icon: Icons.two_wheeler,
  title: 'Rider $id',
  subtitle: 'Motorcycle · Tandag',
  details: const [MapEntry('Fare', 'PHP 50')],
  faded: faded,
  color: color,
  actionLabel: onAction == null ? null : 'Book this ride',
  onAction: onAction,
);

Widget _host(SurgoMap map, {bool reduceMotion = true}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 600,
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: map,
          ),
        ),
      ),
    ),
  ),
);

Finder _pin(String id) => find.byKey(ValueKey('surgo-marker-$id'));

// Inspect only the local Canvas geometry, without constructing a platform map
// or supplying an API key. No road geometry or driver GPS is generated here.
List<MapPoint> _drawnRoute(WidgetTester tester) {
  final painter = tester.widget<CustomPaint>(find.byKey(_canvasKey)).painter;
  return (painter as dynamic).route as List<MapPoint>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('existing API defaults remain compatible', () {
    final marker = _marker('default', _center);
    final map = SurgoMap(markers: [marker]);
    expect(marker.color, AppColors.primary);
    expect(marker.faded, isFalse);
    expect(map.route, isEmpty);
    expect(map.routeIsEstimate, isFalse);
    expect(map.cameraPadding, EdgeInsets.zero);
    expect(map.showUserLocation, isTrue);
    expect(map.initialZoom, 15);
    expect(surgoMarkerIcon('motorcycle'), Icons.two_wheeler);
    expect(surgoMarkerIcon('unknown'), Icons.place);
  });

  group('offline (no key)', () {
    testWidgets(
      'no key renders a labelled offline preview without native views',
      (tester) async {
        await tester.pumpWidget(
          _host(
            SurgoMap(
              markers: [_marker('one', _center)],
              showUserLocation: false,
            ),
          ),
        );
        expect(find.text('Offline map preview'), findsOneWidget);
        expect(
          find.textContaining('MAPTILER_API_KEY not set.'),
          findsOneWidget,
        );
        expect(find.byKey(_canvasKey), findsOneWidget);
        expect(find.byType(ml.MapLibreMap), findsNothing);
        expect(find.byType(AndroidView), findsNothing);
        expect(find.byType(UiKitView), findsNothing);
        expect(find.textContaining('© OpenStreetMap'), findsNothing);
        expect(_pin('one'), findsOneWidget);
        expect(find.text('Loading map…'), findsNothing);
        await tester.pump(const Duration(seconds: 16));
        expect(find.text('Map did not finish loading.'), findsNothing);
        expect(find.text('Retry'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'offline pins retain the information sheet and primary action',
      (tester) async {
        var bookings = 0;
        await tester.pumpWidget(
          _host(
            SurgoMap(
              markers: [_marker('one', _center, onAction: () => bookings++)],
              showUserLocation: false,
            ),
          ),
        );
        await tester.tap(_pin('one'));
        await tester.pumpAndSettle();
        expect(find.text('Rider one'), findsOneWidget);
        expect(find.text('Motorcycle · Tandag'), findsOneWidget);
        expect(find.text('Fare'), findsOneWidget);
        expect(find.text('PHP 50'), findsOneWidget);
        await tester.tap(find.text('Book this ride'));
        await tester.pumpAndSettle();
        expect(bookings, 1);
        expect(find.text('Book this ride'), findsNothing);
        expect(_pin('one'), findsOneWidget);
      },
    );

    testWidgets(
      'static previews disable pin taps, panning and location controls',
      (tester) async {
        await tester.pumpWidget(
          _host(
            SurgoMap(
              markers: [_marker('one', _center)],
              interactive: false,
              showUserLocation: false,
            ),
          ),
        );
        final preview = tester.widget<GestureDetector>(find.byKey(_previewKey));
        expect(preview.onScaleStart, isNull);
        expect(preview.onScaleUpdate, isNull);
        expect(tester.widget<GestureDetector>(_pin('one')).onTap, isNull);
        final before = tester.getRect(_pin('one'));
        await tester.tap(_pin('one'));
        await tester.drag(find.byKey(_previewKey), const Offset(70, 30));
        await tester.pumpAndSettle();
        expect(tester.getRect(_pin('one')), before);
        expect(find.text('Rider one'), findsNothing);
        expect(find.byIcon(Icons.my_location), findsNothing);
      },
    );

    testWidgets('interactive gating can change on an existing map', (
      tester,
    ) async {
      SurgoMap map(bool interactive) => SurgoMap(
        key: const ValueKey('shared-map'),
        markers: [_marker('one', _center)],
        interactive: interactive,
        showUserLocation: false,
      );
      await tester.pumpWidget(_host(map(false)));
      expect(tester.widget<GestureDetector>(_pin('one')).onTap, isNull);
      await tester.pumpWidget(_host(map(true)));
      expect(tester.widget<GestureDetector>(_pin('one')).onTap, isNotNull);
      expect(
        tester.widget<GestureDetector>(find.byKey(_previewKey)).onScaleUpdate,
        isNotNull,
      );
      await tester.tap(_pin('one'));
      await tester.pumpAndSettle();
      expect(find.text('Rider one'), findsOneWidget);
      Navigator.of(tester.element(find.text('Rider one'))).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(_host(map(false)));
      expect(tester.widget<GestureDetector>(_pin('one')).onTap, isNull);
    });

    testWidgets('preview projects longitude east and latitude north', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SurgoMap(
            markers: [
              _marker('center', _center),
              _marker('east', const MapPoint(9.0785, 126.1995)),
              _marker('north', const MapPoint(9.0795, 126.1985)),
            ],
            fallbackCenter: _center,
            showUserLocation: false,
          ),
        ),
      );
      final center = tester.getRect(_pin('center')).bottomCenter;
      final east = tester.getRect(_pin('east')).bottomCenter;
      final north = tester.getRect(_pin('north')).bottomCenter;
      expect(east.dx, greaterThan(center.dx));
      expect(east.dy, closeTo(center.dy, 0.01));
      expect(north.dx, closeTo(center.dx, 0.01));
      expect(north.dy, lessThan(center.dy));
      final mapRect = tester.getRect(find.byKey(_previewKey));
      expect(center.dx, closeTo(mapRect.center.dx, 0.01));
    });

    testWidgets(
      'interactive offline preview pans without changing coordinates',
      (tester) async {
        final marker = _marker('one', _center);
        await tester.pumpWidget(
          _host(SurgoMap(markers: [marker], showUserLocation: false)),
        );
        final before = tester.getRect(_pin('one'));
        await tester.drag(find.byKey(_previewKey), const Offset(80, 20));
        await tester.pump();
        final after = tester.getRect(_pin('one'));
        expect(after.left, greaterThan(before.left + 30));
        expect(marker.position.latitude, _center.latitude);
        expect(marker.position.longitude, _center.longitude);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'route endpoints fit above padded sheets on creation and updates',
      (tester) async {
        SurgoMap map(double bottom, MapPoint destination) => SurgoMap(
          markers: [
            _marker('pickup', _pickup),
            _marker('destination', destination, color: AppColors.yellow),
          ],
          route: [_pickup, destination],
          routeIsEstimate: true,
          cameraPadding: EdgeInsets.only(bottom: bottom),
          height: 520,
          showUserLocation: false,
        );
        void expectVisible(double bottom) {
          final bounds = tester.getRect(find.byKey(_previewKey));
          for (final id in ['pickup', 'destination']) {
            final pin = tester.getRect(_pin(id));
            expect(pin.left, greaterThanOrEqualTo(bounds.left + 10));
            expect(pin.right, lessThanOrEqualTo(bounds.right - 10));
            expect(pin.top, greaterThanOrEqualTo(bounds.top + 20));
            expect(pin.bottom, lessThanOrEqualTo(bounds.bottom - bottom - 60));
          }
        }

        await tester.pumpWidget(_host(map(160, _destination)));
        expectVisible(160);
        expect(
          find.text('Offline map preview\nStraight-line estimate'),
          findsOneWidget,
        );
        const updatedDestination = MapPoint(9.14, 126.27);
        await tester.pumpWidget(_host(map(240, updatedDestination)));
        await tester.pump();
        expectVisible(240);
        expect(
          _drawnRoute(tester).last.longitude,
          updatedDestination.longitude,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('rider movement preserves fitted camera and user pan', (
      tester,
    ) async {
      SurgoMap map(MapPoint rider, {bool reverse = false}) {
        final markers = [
          _marker('pickup', _pickup),
          _marker('destination', _destination),
          _marker('rider', rider),
        ];
        return SurgoMap(
          markers: reverse ? markers.reversed.toList() : markers,
          route: const [_pickup, _destination],
          fallbackCenter: MapPoint(_pickup.latitude, _pickup.longitude),
          height: 520,
          showUserLocation: false,
        );
      }

      await tester.pumpWidget(_host(map(_center)));
      final fitted = tester.getRect(_pin('pickup'));
      await tester.pumpWidget(_host(map(const MapPoint(9.2, 126.4))));
      await tester.pump();
      expect(tester.getRect(_pin('pickup')), fitted);

      await tester.drag(find.byKey(_previewKey), const Offset(80, 20));
      await tester.pump();
      final panned = tester.getRect(_pin('pickup'));
      expect(panned.left, greaterThan(fitted.left + 30));
      await tester.pumpWidget(
        _host(map(const MapPoint(9.3, 126.5), reverse: true)),
      );
      await tester.pump();
      expect(tester.getRect(_pin('pickup')), panned);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'marker id set changes intentionally refit, including reused lists',
      (tester) async {
        final markers = [
          _marker('pickup', _pickup),
          _marker('destination', _destination),
        ];
        SurgoMap map() => SurgoMap(
          markers: markers,
          route: const [_pickup, _destination],
          height: 520,
          showUserLocation: false,
        );
        await tester.pumpWidget(_host(map()));
        final fitted = tester.getRect(_pin('pickup'));
        await tester.drag(find.byKey(_previewKey), const Offset(80, 20));
        await tester.pump();
        expect(tester.getRect(_pin('pickup')), isNot(fitted));
        // A same-sized replacement is still an id-set change.
        markers[1] = _marker('new-destination', _destination);
        await tester.pumpWidget(_host(map()));
        await tester.pump();
        expect(tester.getRect(_pin('pickup')), fitted);
        markers.add(_marker('rider', const MapPoint(9.13, 126.26)));
        await tester.pumpWidget(_host(map()));
        await tester.pump();
        expect(tester.getRect(_pin('pickup')), isNot(fitted));
        markers.removeLast();
        await tester.pumpWidget(_host(map()));
        await tester.pump();
        expect(tester.getRect(_pin('pickup')), fitted);
      },
    );

    testWidgets('road routes are solid offline; only estimates are dashed', (
      tester,
    ) async {
      SurgoMap map(bool estimate) => SurgoMap(
        markers: const [],
        route: const [_pickup, _destination],
        routeIsEstimate: estimate,
        showUserLocation: false,
      );
      List<Path> paintedPaths(CustomPainter painter) {
        final canvas = TestRecordingCanvas();
        painter.paint(canvas, tester.getSize(find.byKey(_canvasKey)));
        return [
          for (final call in canvas.invocations)
            if (call.invocation.memberName == #drawPath)
              call.invocation.positionalArguments.first as Path,
        ];
      }

      await tester.pumpWidget(_host(map(false)));
      expect(
        find.text('Offline map preview\nRoad route · offline basemap'),
        findsOneWidget,
      );
      expect(find.textContaining('Straight-line estimate'), findsNothing);
      final roadPainter = tester
          .widget<CustomPaint>(find.byKey(_canvasKey))
          .painter!;
      final roadPaths = paintedPaths(roadPainter);
      expect(roadPaths, hasLength(2));
      expect(roadPaths.first.computeMetrics().length, 1);

      await tester.pumpWidget(_host(map(true)));
      expect(
        find.text('Offline map preview\nStraight-line estimate'),
        findsOneWidget,
      );
      expect(find.textContaining('Road route'), findsNothing);
      final estimatePainter = tester
          .widget<CustomPaint>(find.byKey(_canvasKey))
          .painter!;
      expect(estimatePainter.shouldRepaint(roadPainter), isTrue);
      final estimatePaths = paintedPaths(estimatePainter);
      expect(estimatePaths, hasLength(2));
      expect(estimatePaths.first.computeMetrics().length, greaterThan(1));
      expect(
        estimatePaths.first.computeMetrics().fold(
          0.0,
          (sum, metric) => sum + metric.length,
        ),
        lessThan(roadPaths.first.computeMetrics().single.length),
      );
    });

    testWidgets('route updates detect a reused mutable route list', (
      tester,
    ) async {
      final route = <MapPoint>[_pickup, _destination];
      SurgoMap map() =>
          SurgoMap(markers: const [], route: route, showUserLocation: false);
      await tester.pumpWidget(_host(map()));
      route[1] = const MapPoint(9.11, 126.25);
      await tester.pumpWidget(_host(map()));
      expect(_drawnRoute(tester).last.longitude, 126.25);
    });

    testWidgets('route draws over 1.1 seconds and pin animations settle', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SurgoMap(
            markers: [_marker('one', _pickup)],
            route: const [_pickup, _destination],
            showUserLocation: false,
          ),
          reduceMotion: false,
        ),
      );
      expect(
        _drawnRoute(tester).last.longitude,
        closeTo(_pickup.longitude, 1e-8),
      );
      await tester.pump(const Duration(milliseconds: 550));
      final midpoint = _drawnRoute(tester).last.longitude;
      expect(midpoint, greaterThan(_pickup.longitude));
      expect(midpoint, lessThan(_destination.longitude));
      await tester.pump(const Duration(milliseconds: 550));
      expect(_drawnRoute(tester).last.longitude, _destination.longitude);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'reduced motion draws the complete route and skips pin animations',
      (tester) async {
        await tester.pumpWidget(
          _host(
            SurgoMap(
              markers: [_marker('one', _pickup)],
              route: const [_pickup, _destination],
              showUserLocation: false,
            ),
          ),
        );
        expect(_drawnRoute(tester).last.longitude, _destination.longitude);
        expect(
          find.descendant(of: _pin('one'), matching: find.byType(Transform)),
          findsNothing,
        );
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );

    testWidgets(
      'custom destination color and unavailable pin dimming are retained',
      (tester) async {
        await tester.pumpWidget(
          _host(
            SurgoMap(
              markers: [
                _marker('destination', _center, color: AppColors.yellow),
                _marker(
                  'unavailable',
                  const MapPoint(9.0795, 126.1985),
                  faded: true,
                ),
              ],
              showUserLocation: false,
            ),
          ),
        );
        Color pinColor(String id) {
          final paint = tester.widget<CustomPaint>(
            find.descendant(of: _pin(id), matching: find.byType(CustomPaint)),
          );
          return (paint.painter as dynamic).color as Color;
        }

        expect(pinColor('destination'), AppColors.yellow);
        expect(pinColor('unavailable'), AppColors.muted2);
        expect(
          tester
              .widget<Opacity>(
                find.descendant(
                  of: _pin('unavailable'),
                  matching: find.byType(Opacity),
                ),
              )
              .opacity,
          0.55,
        );
      },
    );

    testWidgets(
      'a single route point is safe and not presented as a road route',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const SurgoMap(
              markers: [],
              route: [_center],
              showUserLocation: false,
            ),
          ),
        );
        expect(_drawnRoute(tester), hasLength(1));
        expect(find.text('Offline map preview'), findsOneWidget);
        expect(find.textContaining('Straight-line estimate'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('denied location keeps preview usable and the locate warning', (
      tester,
    ) async {
      const channel = MethodChannel('flutter.baseflow.com/geolocator');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isLocationServiceEnabled') return false;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(_host(const SurgoMap(markers: [])));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.my_location), findsOneWidget);
      expect(find.text('Offline map preview'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.my_location));
      await tester.pumpAndSettle();
      expect(find.textContaining('Location permission is off'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }, skip: _hasKey);

  group('keyed map (fake platform)', () {
    late MapLibrePlatform previousPlatform;
    late _FakeMapPlatform platform;

    setUp(() {
      previousPlatform = MapLibrePlatform.instance;
      platform = _FakeMapPlatform();
      MapLibrePlatform.instance = platform;
    });
    tearDown(() => MapLibrePlatform.instance = previousPlatform);

    ml.MapLibreMap renderer(WidgetTester tester) =>
        tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));

    const emptyMap = SurgoMap(markers: [], showUserLocation: false);

    testWidgets(
      'creation, style and camera idle do not complete tile loading',
      (tester) async {
        await tester.pumpWidget(_host(emptyMap));
        final map = renderer(tester);
        expect(find.text('Loading map…'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        map.onMapCreated!(platform.states.single);
        map.onStyleLoaded!(_FakeStyle());
        map.onEvent!(const ml.MapEventCameraIdle());
        await tester.pump(const Duration(milliseconds: 14999));
        expect(find.text('Loading map…'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        expect(find.text('Map did not finish loading.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('error'), findsNothing);
        expect(find.textContaining('https://'), findsNothing);
        expect(find.textContaining('key='), findsNothing);
        expect(find.byKey(_previewKey), findsNothing);
        expect(
          find.text('© MapTiler · © OpenStreetMap contributors'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('loading retry stays inside the unoccluded map area', (
      tester,
    ) async {
      const map = SurgoMap(
        markers: [],
        showUserLocation: false,
        height: 520,
        cameraPadding: EdgeInsets.fromLTRB(24, 80, 24, 320),
      );
      await tester.pumpWidget(_host(map));
      await tester.pump(const Duration(seconds: 15));
      final mapRect = tester.getRect(find.byType(SurgoMap));
      final retryRect = tester.getRect(
        find.widgetWithText(TextButton, 'Retry'),
      );
      expect(retryRect.top, greaterThanOrEqualTo(mapRect.top + 80));
      expect(retryRect.bottom, lessThanOrEqualTo(mapRect.bottom - 320));
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(platform.states, hasLength(2));
      expect(find.text('Loading map…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets('first map idle clears loading and cancels the timeout', (
      tester,
    ) async {
      await tester.pumpWidget(_host(emptyMap));
      final map = renderer(tester);
      await tester.pump(const Duration(seconds: 14));
      map.onEvent!(const ml.MapEventIdle());
      await tester.pump();
      expect(find.text('Loading map…'), findsNothing);
      map.onStyleLoaded!(_FakeStyle());
      map.onEvent!(const ml.MapEventCameraIdle());
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('Map did not finish loading.'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(ml.MapLibreMap), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'late idle can complete a map that did not finish in 15 seconds',
      (tester) async {
        await tester.pumpWidget(_host(emptyMap));
        await tester.pump(const Duration(seconds: 15));
        expect(find.text('Map did not finish loading.'), findsOneWidget);
        renderer(tester).onEvent!(const ml.MapEventIdle());
        await tester.pump();
        expect(find.text('Map did not finish loading.'), findsNothing);
        expect(find.text('Loading map…'), findsNothing);
        expect(find.text('Retry'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'retry recreates the map and ignores callbacks from the old attempt',
      (tester) async {
        await tester.pumpWidget(_host(emptyMap));
        final oldMap = renderer(tester);
        final oldState = platform.states.single;
        oldMap.onMapCreated!(oldState);
        await tester.pump(const Duration(seconds: 15));
        await tester.tap(find.text('Retry'));
        await tester.pump();
        final newMap = renderer(tester);
        expect(newMap.key, isNot(oldMap.key));
        expect(platform.states, hasLength(2));
        expect(oldState.mounted, isFalse);
        expect(find.text('Loading map…'), findsOneWidget);
        expect(find.text('Map did not finish loading.'), findsNothing);
        final oldMoves = oldState.moves.length;
        oldMap.onMapCreated!(oldState);
        oldMap.onStyleLoaded!(_FakeStyle());
        oldMap.onEvent!(const ml.MapEventIdle());
        await tester.pump(const Duration(seconds: 14));
        expect(find.text('Loading map…'), findsOneWidget);
        expect(oldState.moves, hasLength(oldMoves));
        newMap.onMapCreated!(platform.states.last);
        expect(platform.states.last.moves, hasLength(1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Map did not finish loading.'), findsOneWidget);
        newMap.onEvent!(const ml.MapEventIdle());
        await tester.pump();
        expect(find.text('Retry'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'dispose cancels pending timeout and makes late callbacks harmless',
      (tester) async {
        await tester.pumpWidget(_host(emptyMap));
        final map = renderer(tester);
        final state = platform.states.single;
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox.shrink());
        map.onMapCreated!(state);
        map.onStyleLoaded!(_FakeStyle());
        map.onEvent!(const ml.MapEventIdle());
        await tester.pump(const Duration(seconds: 16));
        expect(state.moves, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'rider updates and marker reorder do not move the native camera',
      (tester) async {
        SurgoMap map(
          MapPoint rider, {
          bool reverse = false,
          MapPoint destination = _destination,
          bool extra = false,
        }) {
          final markers = [
            _marker('pickup', _pickup),
            _marker('destination', destination),
            _marker('rider', rider),
            if (extra) _marker('extra', _center),
          ];
          return SurgoMap(
            markers: reverse ? markers.reversed.toList() : markers,
            route: [_pickup, destination],
            fallbackCenter: MapPoint(_pickup.latitude, _pickup.longitude),
            height: 520,
            showUserLocation: false,
          );
        }

        await tester.pumpWidget(_host(map(_center)));
        final firstMap = renderer(tester);
        final state = platform.states.single;
        firstMap.onMapCreated!(state);
        firstMap.onEvent!(const ml.MapEventIdle());
        await tester.pump();
        // Simulate a user-chosen camera, then ensure rebuilds don't reset it.
        await state.moveCamera(
          center: const ml.Geographic(lat: 9.1, lon: 126.3),
          zoom: 17,
        );
        final moveCount = state.moves.length;
        await tester.pumpWidget(
          _host(map(const MapPoint(9.2, 126.4), reverse: true)),
        );
        await tester.pump();
        expect(state.moves, hasLength(moveCount));
        expect(state.moves.last.$2, 17);
        expect(renderer(tester).key, firstMap.key);
        expect(platform.states, hasLength(1));
        await tester.pumpWidget(_host(map(_center, extra: true)));
        await tester.pump();
        expect(state.moves, hasLength(moveCount + 1));
        const newDestination = MapPoint(9.14, 126.27);
        await tester.pumpWidget(
          _host(map(_center, extra: true, destination: newDestination)),
        );
        await tester.pump();
        expect(state.moves, hasLength(moveCount + 2));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('native route layers honor the estimate flag', (tester) async {
      SurgoMap map(bool estimate) => SurgoMap(
        markers: const [],
        route: const [_pickup, _destination],
        routeIsEstimate: estimate,
        showUserLocation: false,
      );
      await tester.pumpWidget(_host(map(false)));
      expect(find.textContaining('Straight-line estimate'), findsNothing);
      for (final layer in renderer(tester).layers.cast<ml.PolylineLayer>()) {
        expect(layer.dashArray, isNull);
      }
      await tester.pumpWidget(_host(map(true)));
      expect(find.text('Straight-line estimate'), findsOneWidget);
      for (final layer in renderer(tester).layers.cast<ml.PolylineLayer>()) {
        expect(layer.dashArray, [2, 2]);
      }
      renderer(tester).onEvent!(const ml.MapEventIdle());
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }, skip: !_hasKey);
}
