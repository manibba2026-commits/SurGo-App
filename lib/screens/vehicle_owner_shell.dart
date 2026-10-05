import 'package:flutter/material.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import 'vehicle_owner_bookings_screen.dart';
import 'vehicle_owner_earnings_screen.dart';
import 'vehicle_owner_home_screen.dart';
import 'vehicle_owner_profile_screen.dart';
import 'vehicle_owner_vehicles_screen.dart';

/// Vehicle Owner dashboard shell: Home / Vehicles / Bookings / Earnings /
/// Profile as sliding tabs, mirroring the passenger and rider shells.
class VehicleOwnerShell extends StatelessWidget {
  final int initialIndex;
  const VehicleOwnerShell({super.key, this.initialIndex = 0});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AppShell(
        initialIndex: initialIndex,
        items: const [
          SbNavItem(Icons.home_rounded, 'Home'),
          SbNavItem(Icons.directions_car_filled_outlined, 'Vehicles'),
          SbNavItem(Icons.event_note_outlined, 'Bookings'),
          SbNavItem(Icons.account_balance_wallet_outlined, 'Earnings'),
          SbNavItem(Icons.person_outline, 'Profile'),
        ],
        pages: const [
          VehicleOwnerHomeScreen(embedded: true),
          VehicleOwnerVehiclesScreen(embedded: true),
          VehicleOwnerBookingsScreen(embedded: true),
          VehicleOwnerEarningsScreen(embedded: true),
          VehicleOwnerProfileScreen(embedded: true),
        ],
      ),
    );
  }
}
