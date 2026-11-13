import 'package:flutter/material.dart';
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/email_login_screen.dart';
import 'screens/otp_screen.dart';
import 'screens/passenger_shell.dart';
import 'screens/booking_screen.dart';
import 'screens/matching_screen.dart';
import 'screens/live_trip_screen.dart';
import 'screens/ride_chat_screen.dart';
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
import 'screens/pin_lock_screen.dart';
import 'screens/onboarding_screen.dart';
import 'auth/demo_auth.dart';
import 'auth/mock_auth_repository.dart';
import 'auth/supabase_auth_repository.dart';
import 'data/data_source.dart';
import 'repositories/backend.dart';
import 'repositories/repository_registry.dart';
import 'services/supabase_bootstrap.dart';
import 'services/map_bootstrap.dart';
import 'services/passenger_ride_session.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Start the map stack before the first screen: the style document is
  // fetched once and reused by every map, and the Geoapify warm-up runs as
  // soon as a hosted session exists.
  MapBootstrap.instance.start();
  // The presentation build signs in against the existing seed accounts. It
  // skips Supabase entirely so the demo works offline and no hosted identity
  // or session is touched. Without the flag nothing below changes.
  if (DemoAuthConfig.enabled) {
    AppState.instance.configureAuth(
      MockAuthRepository(
        otpCode: DemoAuthConfig.defaultOtpCode,
        sessionStore: SharedPreferencesDemoSessionStore(),
      ),
    );
    AppState.instance.configureRepositories(RepositoryRegistry.mock());
    AppState.instance.demoRideStore = SharedPreferencesDemoRideRequestStore();
    runApp(const SurGoApp());
    return;
  }
  final supabaseReady = await initializeSupabase();
  AppState.instance.configureAuth(
    supabaseReady ? SupabaseAuthRepository() : const DisabledAuthRepository(),
  );
  AppState.instance.configureRepositories(
    buildRepositoryRegistry(supabaseReady: supabaseReady),
  );
  runApp(const SurGoApp());
}

/// Picks the data layer for this build.
///
/// A `SURGO_DATA_SOURCE=supabase` build that could not reach Supabase at boot
/// still gets the Supabase repositories: failing with a typed failure is the
/// honest answer, whereas quietly serving the seed would show data that is not
/// the source of truth.
RepositoryRegistry buildRepositoryRegistry({required bool supabaseReady}) {
  if (DataSourceConfig.usesSupabase && supabaseReady) {
    return RepositoryRegistry.supabase(SupabaseBackend());
  }
  if (DataSourceConfig.usesSupabase) {
    return RepositoryRegistry.supabase(const UnreachableBackend());
  }
  return RepositoryRegistry.mock();
}

/// SurGo — offline UI simulation, connected to the hosted Supabase project.
///
/// Supabase Auth is live and owns every session. Reads of business data go
/// through [RepositoryRegistry]: Supabase tables in a
/// `SURGO_DATA_SOURCE=supabase` build, the `assets/db/` seed otherwise. Every
/// screen still renders from [AppState]'s in-memory state until its domain is
/// moved onto a repository.
class SurGoApp extends StatefulWidget {
  const SurGoApp({super.key});

  @override
  State<SurGoApp> createState() => _SurGoAppState();
}

class _SurGoAppState extends State<SurGoApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      builder: (context, child) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final recovering = state.passwordRecoveryRequired;
          final provider = state.emailRecovery;
          final epoch = state.recoveryEpoch;
          final userId = state.identity?.userId;
          return Stack(
            children: [
              Offstage(offstage: recovering, child: child),
              if (recovering)
                Positioned.fill(
                  child: HeroControllerScope.none(
                    child: Navigator(
                      key: ValueKey(epoch),
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => ResetPasswordScreen(
                          recoveryResolver: () =>
                              state.passwordRecoveryRequired &&
                                  state.recoveryEpoch == epoch &&
                                  state.identity?.userId == userId &&
                                  identical(state.emailRecovery, provider)
                              ? provider
                              : null,
                          onCompleted: () async {
                            if (provider == null) return;
                            await state.completePasswordRecovery(
                              repository: provider,
                              epoch: epoch,
                              userId: userId,
                            );
                            if (!mounted) return;
                            _navigatorKey.currentState?.pushNamedAndRemoveUntil(
                              state.requiresOnboarding
                                  ? '/onboarding'
                                  : state.requiresPin
                                  ? '/pin'
                                  : state.homeRoute,
                              (_) => false,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      title: 'SurGo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      initialRoute: '/',
      // Browser history must not bypass data loading or the restored-session gate.
      onGenerateInitialRoutes: (_) => [
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/'),
          builder: (_) => const SplashScreen(),
        ),
      ],
      routes: {
        '/': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/pin': (context) => const PinLockScreen(),
        '/onboarding': (context) => const OnboardingScreen(),
        '/register': (context) => const RegisterScreen(),
        '/forgot-password': (context) =>
            ForgotPasswordScreen(recoveryResolver: () => state.emailRecovery),
        '/email-login': (context) => const EmailLoginScreen(),
        '/otp': (context) => const OtpScreen(),
        // The three dashboards are each a sliding-tab "shell" — Home,
        // Activity/Trips/Bookings, Wallet/Earnings, and Profile all live as
        // pages inside a PageView instead of being separate pushed routes.
        '/home': (context) => const PassengerShell(),
        '/earner': (context) => const EarnerShell(),
        '/owner': (context) => const VehicleOwnerShell(),
        '/booking': (context) => const BookingScreen(),
        '/pasuyo': (context) => const PasuyoScreen(),
        '/pasuyo_post': (context) => const PasuyoPostScreen(),
        '/matching': (context) => const MatchingScreen(),
        '/livetrip': (context) => const LiveTripScreen(),
        '/ride_chat': (context) => const RideChatScreen(),
        '/rental': (context) => const RentalListScreen(),
        '/profile': (context) => const ProfileScreen(embedded: false),
        '/rate': (context) => const RateTripScreen(),
        // Map V1 — one live-map view per role (passenger/rider/vehicle owner).
        '/map/passenger': (context) => const PassengerMapScreen(),
        '/map/earner': (context) => const EarnerMapScreen(),
        '/map/owner': (context) => const VehicleOwnerMapScreen(),
        '/active_rental': (context) => const ActiveRentalScreen(),
      },
    );
  }
}
