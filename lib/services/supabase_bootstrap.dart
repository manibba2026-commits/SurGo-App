import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Connection settings for the hosted SurGo project.
///
/// Only the publishable key belongs on the client: it is designed to be public,
/// and row level security guards every table. The `sb_secret_` key and the
/// database password must never be shipped in the app. Both values can be
/// overridden at build time with `--dart-define`.
class SupabaseConfig {
  const SupabaseConfig._();

  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://lrhgktxmavnhjatqzbzr.supabase.co',
  );

  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_WszPDYOAKw3dYZ1QAElSXA_mpW1rckw',
  );
}

/// Initializes the Supabase client once.
///
/// Returns `false` when initialization fails (offline device, misconfigured
/// build), so the in-memory prototype can still boot without a network.
Future<bool> initializeSupabase() async {
  try {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
    return true;
  } catch (error, stackTrace) {
    debugPrint('Supabase initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    return false;
  }
}
