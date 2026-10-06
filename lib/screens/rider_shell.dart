import 'package:flutter/material.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import 'rider_earnings_screen.dart';
import 'rider_home_screen.dart';
import 'rider_profile_screen.dart';
import 'rider_trips_screen.dart';

/// Earner dashboard shell: Home / Trips / Earnings / Profile as sliding tabs,
/// same "no back button, no in-dashboard mode switch" root behaviour as before
/// — switching modes only happens from the Profile tab's mode dropdown.
///
/// Named for the role rather than the vehicle: an earner here may be doing
/// rides, errands or deliveries depending on their enabled capabilities, which
/// the Profile tab edits.
class EarnerShell extends StatelessWidget {
  final int initialIndex;
  const EarnerShell({super.key, this.initialIndex = 0});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AppShell(
        initialIndex: initialIndex,
        items: const [
          SbNavItem(Icons.home_rounded, 'Home'),
          SbNavItem(Icons.view_agenda_outlined, 'Trips'),
          SbNavItem(Icons.account_balance_wallet_outlined, 'Earnings'),
          SbNavItem(Icons.person_outline, 'Profile'),
        ],
        pages: const [
          RiderHomeScreen(embedded: true),
          RiderTripsScreen(embedded: true),
          RiderEarningsScreen(embedded: true),
          EarnerProfileScreen(embedded: true),
        ],
      ),
    );
  }
}