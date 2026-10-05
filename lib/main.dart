import 'package:flutter/material.dart';
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/otp_screen.dart';
import 'screens/passenger_shell.dart';
import 'screens/booking_screen.dart';
import 'screens/matching_screen.dart';
import 'screens/live_trip_screen.dart';
import 'screens/rental_list_screen.dart';
import 'screens/rider_shell.dart';
import 'screens/vehicle_owner_shell.dart';
import 'screens/profile_screen.dart';
import 'screens/rate_trip_screen.dart';
import 'screens/passenger_map_screen.dart';
import 'screens/rider_map_screen.dart';
import 'screens/vehicle_owner_map_screen.dart';
import 'screens/active_rental_screen.dart';
import 'screens/pasuyo_screen.dart';
import 'screens/pasuyo_post_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const SurGoApp());
}

/// SurGo — offline UI simulation.
///
/// There is no backend here: every screen reads and writes to an in-memory
/// AppState (see lib/state/app_state.dart) and lib/data/models.dart holds
/// all the mock seed data. It's meant purely to demonstrate what the real
/// app would look and feel like on-device.
class SurGoApp extends StatelessWidget {
  const SurGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SurGo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/otp': (context) => const OtpScreen(),
        // The three dashboards are each a sliding-tab "shell" — Home,
        // Activity/Trips/Bookings, Wallet/Earnings, and Profile all live as
        // pages inside a PageView instead of being separate pushed routes.
        '/home': (context) => const PassengerShell(),
        '/rider': (context) => const RiderShell(),
        '/owner': (context) => const VehicleOwnerShell(),
        '/booking': (context) => const BookingScreen(),
        '/pasuyo': (context) => const PasuyoScreen(),
        '/pasuyo_post': (context) => const PasuyoPostScreen(),
        '/matching': (context) => const MatchingScreen(),
        '/livetrip': (context) => const LiveTripScreen(),
        '/rental': (context) => const RentalListScreen(),
        '/profile': (context) => const ProfileScreen(embedded: false),
        '/rate': (context) => const RateTripScreen(),
        // Map V1 — one live-map view per role (passenger/rider/vehicle owner).
        '/map/passenger': (context) => const PassengerMapScreen(),
        '/map/rider': (context) => const RiderMapScreen(),
        '/map/owner': (context) => const VehicleOwnerMapScreen(),
        '/active_rental': (context) => const ActiveRentalScreen(),
      },
    );
  }
}
