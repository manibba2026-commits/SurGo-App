import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/models.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/rental_status.dart';

void main() {
  final state = AppState.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
    await state.init();
  });

  tearDown(() async {
    state.cancelRentalBooking();
    await state.logout();
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock());
  });

  RentalBooking request() => state.requestRental(
    vehicleId: null,
    vehicleName: 'Session test vehicle',
    vehicleType: 'Van',
    icon: Icons.airport_shuttle,
    ownerName: 'Demo owner',
    ownerInitials: 'DO',
    pickupLabel: 'Today',
    returnLabel: 'Tomorrow',
    pickupDate: DateTime.now(),
    returnDate: DateTime.now().add(const Duration(days: 1)),
    days: 1,
    totalFare: 10000,
  );

  testWidgets('logout clears the rental and retires demo owner approval', (
    tester,
  ) async {
    final booking = request();
    expect(state.activeRentalBooking, same(booking));
    await state.logout();
    await tester.pump(const Duration(seconds: 11));
    expect(state.activeRentalBooking, isNull);
    expect(state.lastRentalBreakdown, isNull);
    expect(booking.status, RentalStatus.requested);
  });

  testWidgets('a replaced identity provider cannot run old demo approval', (
    tester,
  ) async {
    final booking = request();
    state.configureAuth(MockAuthRepository());
    await tester.pump(const Duration(seconds: 11));
    expect(booking.status, RentalStatus.requested);
    expect(state.lastRentalBreakdown, isNull);
  });

  testWidgets('a replaced repository cannot run old demo approval', (
    tester,
  ) async {
    final booking = request();
    state.configureRepositories(RepositoryRegistry.mock());
    await tester.pump(const Duration(seconds: 11));
    expect(booking.status, RentalStatus.requested);
    expect(state.lastRentalBreakdown, isNull);
  });
}
