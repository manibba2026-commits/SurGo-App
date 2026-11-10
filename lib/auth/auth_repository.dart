import 'auth_models.dart';

/// The identity operations SurGo needs. Supabase Auth is the only production
/// implementation; the in-memory implementation exists for tests and previews.
///
/// Implementations never store passwords or tokens themselves: the provider
/// SDK owns credential storage and session persistence.
abstract class AuthRepository {
  /// True for the in-memory implementation used by tests and previews.
  bool get isMock;

  /// False when the provider could not be reached at boot, so screens can say
  /// so up front instead of failing on the first tap.
  bool get isAvailable;

  /// Emits the authenticated user after sign-in, session restore, token
  /// refresh or identity linking. `null` means the session ended.
  Stream<AuthUser?> get authStateChanges;

  /// The session persisted by the provider, or null when signed out.
  Future<AuthUser?> restoreSession();

  /// Sends a one-time code to [phone] (E.164). [fullName] is stored as profile
  /// metadata for a new account. [createUser] is false when signing an existing
  /// account in, so a typo cannot silently create a second account.
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  });

  /// Verifies the SMS code and establishes a session.
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  });

  /// Opens the Google consent screen. The session arrives through
  /// [authStateChanges] (or on the next launch after a web redirect).
  Future<bool> signInWithGoogle();

  Future<void> signOut();

  /// Loads the SurGo profile and approved roles for [user].
  Future<SurgoIdentity> loadIdentity(AuthUser user);

  /// Completes first-run registration for a provider account that has no phone
  /// identity yet. The marker is written to the provider's user metadata, so it
  /// survives restarts without a database migration.
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  });

  /// Links a Google identity to the signed-in account.
  Future<bool> linkGoogleIdentity();

  /// Starts adding a phone identity to the signed-in account. Supabase sends a
  /// code to the new number; complete it with [verifyPhoneLink].
  Future<void> requestPhoneLink(String phone);

  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  });
}
