import 'package:flutter/material.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import 'activity_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'wallet_screen.dart';

/// Top-level passenger dashboard. Home / Activity / Wallet / Profile are
/// swipeable tabs sharing one bottom nav bar — tapping or swiping between
/// them slides the page instead of pushing a new route. Anything opened
/// from *within* a tab (ride history detail, saved places, settings, a
/// top-up sheet, etc.) still uses normal push navigation.
class PassengerShell extends StatelessWidget {
  final int initialIndex;
  const PassengerShell({super.key, this.initialIndex = 0});

  @override
  Widget build(BuildContext context) {
    return AppShell(
      initialIndex: initialIndex,
      items: const [
        SbNavItem(Icons.home_rounded, 'Home'),
        SbNavItem(Icons.receipt_long, 'Activity'),
        SbNavItem(Icons.account_balance_wallet_outlined, 'Wallet'),
        SbNavItem(Icons.person_outline, 'Profile'),
      ],
      pages: const [
        HomeScreen(embedded: true),
        ActivityScreen(embedded: true),
        WalletScreen(embedded: true),
        ProfileScreen(embedded: true),
      ],
    );
  }
}
