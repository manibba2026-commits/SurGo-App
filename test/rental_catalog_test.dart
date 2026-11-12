import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/models.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/rental_list_screen.dart';
import 'package:surgo/state/app_state.dart';

void main() {
  final state = AppState.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    await state.init();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RentalListScreen()));
    await tester.pump();
  }

  testWidgets('rental search filters names without changing the catalogue', (
    tester,
  ) async {
    await open(tester);
    final vehicle = MockData.rentalVehicles.first;
    await tester.enterText(find.byType(TextField), vehicle.name.toUpperCase());
    await tester.pump();
    expect(find.text(vehicle.name), findsOneWidget);
    for (final other in MockData.rentalVehicles.skip(1)) {
      if (!other.name.toLowerCase().contains(vehicle.name.toLowerCase())) {
        expect(find.text(other.name), findsNothing);
      }
    }
    expect(MockData.rentalVehicles.length, greaterThan(1));
  });

  testWidgets('empty search results recover when the query is cleared', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'no-such-surgo-vehicle');
    await tester.pump();
    expect(find.text('No vehicles match your search.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('No vehicles match your search.'), findsNothing);
    expect(find.text(MockData.rentalVehicles.first.name), findsOneWidget);
  });
}
