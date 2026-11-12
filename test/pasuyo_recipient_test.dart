import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/pasuyo_task_screen.dart';
import 'package:surgo/state/app_state.dart';

void main() {
  final state = AppState.instance;
  PasuyoTask? task;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    await state.init();
  });

  tearDown(() {
    state.db.pasuyoTasks.remove(task);
    task = null;
  });

  PasuyoTask post({required bool forSomeone}) => state.postPasuyoTask(
    category: PasuyoCategory.groceries,
    title: 'Recipient test',
    items: const ['Milk'],
    pickupBarangay: 'Poblacion',
    pickupPurok: 'Purok 1',
    pickup: 'Market',
    dropoffBarangay: 'Poblacion',
    dropoffPurok: 'Purok 2',
    dropoff: 'Home',
    budget: 15000,
    bookedForSomeone: forSomeone,
    recipientName: 'Demo recipient',
    recipientPhone: '+639170009911',
  );

  testWidgets('demo task retains and displays its intended recipient', (
    tester,
  ) async {
    task = post(forSomeone: true);
    expect(task!.bookedForSomeone, isTrue);
    expect(task!.recipientName, 'Demo recipient');
    expect(task!.recipientPhone, '+639170009911');
    await tester.pumpWidget(
      MaterialApp(home: PasuyoTaskScreen(taskId: task!.id)),
    );
    await tester.pump();
    expect(find.text('Recipient'), findsOneWidget);
    expect(find.text('Demo recipient · +639170009911'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('self-booked demo task does not retain hidden recipient fields', () {
    task = post(forSomeone: false);
    expect(task!.bookedForSomeone, isFalse);
    expect(task!.recipientName, isEmpty);
    expect(task!.recipientPhone, isEmpty);
  });
}
