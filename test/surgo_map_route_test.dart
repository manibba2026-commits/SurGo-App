import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/theme/app_colors.dart';
import 'package:surgo/widgets/surgo_map.dart';

/// The active-trip route is green. The offline painter is the path a build
/// without a MapTiler key uses, so pin that it receives the caller's color
/// rather than the neutral blue default.
void main() {
  testWidgets('the offline route painter uses the requested color',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SurgoMap(
            height: 320,
            showUserLocation: false,
            markers: const [],
            routeColor: AppColors.success,
            route: const [
              MapPoint(9.0780, 126.1980),
              MapPoint(9.0800, 126.2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final canvas = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('surgo-offline-canvas')),
    );
    final painter = canvas.painter as dynamic;
    expect(painter.routeColor, AppColors.success);
  });

  testWidgets('the default route color stays neutral before a match',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SurgoMap(
            height: 320,
            showUserLocation: false,
            markers: [],
            route: [
              MapPoint(9.0780, 126.1980),
              MapPoint(9.0800, 126.2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final canvas = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('surgo-offline-canvas')),
    );
    final painter = canvas.painter as dynamic;
    expect(painter.routeColor, SurgoMap.defaultRouteColor);
  });
}
