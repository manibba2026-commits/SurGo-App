import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/widgets/common.dart';

/// The map behind a sheet is a platform view with its own gesture handling.
/// These tests pin the shield that keeps a drag starting on the sheet from
/// panning the map, while leaving the sheet's own controls tappable.
void main() {
  testWidgets('a drag that starts on the overlay never reaches the map',
      (tester) async {
    var mapDrags = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (_) => mapDrags++,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SbMapOverlay(
                  child: Container(
                    width: 400,
                    height: 240,
                    color: Colors.blue,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.drag(find.byType(SbMapOverlay), const Offset(0, -120));
    expect(mapDrags, 0,
        reason: 'the shield must stop the drag at the overlay boundary');
  });

  testWidgets('buttons inside the overlay still receive taps', (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SbMapOverlay(
            child: SizedBox(
              width: 400,
              height: 240,
              child: Center(
                child: ElevatedButton(
                  onPressed: () => taps++,
                  child: const Text('Continue'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Continue'));
    expect(taps, 1);
  });
}
