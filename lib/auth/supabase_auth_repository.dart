import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../data/db_models.dart';
import '../repositories/backend.dart';
import '../repositories/backend_rows.dart';
import '../repositories/profile_repository.dart';
import 'auth_models.dart';
import 'auth_repository.dart';

/// Resolves where the OAuth round trip should return to.
///
/// Supabase falls back to the project's Site URL when no target is given, and
/// that default is a localhost address. On web the callback must therefore
/// name the page the app is actually served from; on native it keeps the
/// registered custom scheme.
@visibleForTesting
String resolveOAuthRedirect({
  required bool isWeb,
  required Uri base,
  required String nativeRedirect,
}) {
  if (!isWeb) return nativeRedirect;
  final path = base.path.isEmpty ? '/' : base.path;
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: path,
  ).toString();
}

/// The production identity provider. Every credential, session and identity
/// link lives in Supabase Auth; this class only translates the SDK into the
/// app's own types.
class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository({
    SupabaseClient? client,
    ProfileRepository? profiles,
    this.redirectTo = defaultRedirectTo,
  })  : _client = client ?? Supabase.instance.client,
        _profiles = profiles ??
            SupabaseProfileRepository(SupabaseBackend(client: client));

  /// Custom scheme registered on Android and iOS. It must also be present in
  /// the hosted project's redirect allow-list.
  static const String defaultRedirectTo = 'io.supabase.surgo://login-callback';

  static const Duration _timeout = Duration(seconds: 20);

  final SupabaseClient _client;
  final ProfileRepository _profiles;
  final String redirectTo;

  String get _oauthRedirect => resolveOAuthRedirect(
        isWeb: kIsWeb,
        base: Uri.base,
        nativeRedirect: redirectTo,
      );

  @override
  bool get isMock => false;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges =>
      _client.auth.onAuthStateChange.map((state) {
        if (state.event == AuthChangeEvent.signedOut) return null;
        return _authUser(state.session?.user);
      });

  @override
  Future<AuthUser?> restoreSession() async {
    try {
      // getSession() refreshes an expired access token before returning, so a
      // restored session is valid rather than a stale stored token. A revoked
      // refresh token throws and is treated as signed out: the next screen is
      // sign-in, never a dashboard held open by an expired session.
      final session = await _client.auth.getSession();
      if (session == null || session.isExpired) return null;
      return _authUser(session.user);
    } on AuthException {
      return null;
    }
  }

  @override
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) {
    return _guard(() async {
      await _client.auth.signInWithOtp(
        phone: phone,
        shouldCreateUser: createUser,
        data: fullName == null || fullName.trim().isEmpty
            ? null
            : {'full_name': fullName.trim()},
      );
    });
  }

  @override
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) {
    return _guard(() async {
      final response = await _client.auth.verifyOTP(
        phone: phone,
        token: token,
        type: OtpType.sms,
      );
      final user = _authUser(response.user);
      if (user == null) {
        throw const AuthFailure(
          AuthFailureCode.unknown,
          'That code could not be verified. Request a new one.',
        );
      }
      return user;
    });
  }

  static final RegExp _demoPinPattern = RegExp(r'^\d{6}$');

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) {
    return _guard(() async {
      final normalized = normalizePhoneNumber(phone);
      if (normalized == null) {
        throw const AuthFailure(
          AuthFailureCode.invalidPhone,
          'Enter a valid Philippine mobile number, for example 0917 000 0001.',
        );
      }
      if (!_demoPinPattern.hasMatch(pin)) {
        throw const AuthFailure(
          AuthFailureCode.invalidPin,
          'Enter the 6-digit PIN for this demo account.',
        );
      }

      final FunctionResponse response;
      try {
        // The function owns the PIN comparison, the lockout counter and the
        // session exchange; the app only forwards what the user typed.
        response = await _client.functions.invoke(
          'demo-login',
          body: {'phone': normalized, 'pin': pin},
        );
      } on FunctionException catch (error) {
        throw AuthFailure.fromDemoLogin(error.status, error.details);
      }

      final data = response.data;
      final session = data is Map ? data['session'] : null;
      if (session is! Map) {
        throw const AuthFailure(
          AuthFailureCode.unknown,
          'Demo sign-in did not return a session. Try again.',
        );
      }

      // The function exchanged the PIN for a real GoTrue session. Adopting it
      // keeps the provider's own refresh and sign-out behaviour, so the rest of
      // the app treats this exactly like any other Supabase session.
      final recovered = await _client.auth.recoverSession(jsonEncode(session));
      final user = _authUser(recovered.user);
      if (user == null) {
        throw const AuthFailure(
          AuthFailureCode.unknown,
          'Demo sign-in did not complete. Try again.',
        );
      }
      return user;
    });
  }

  @override
  Future<bool> signInWithGoogle() {
    return _guard(() {
      return _client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: _oauthRedirect,
      );
    });
  }

  @override
  Future<void> signOut() {
    return _guard(() => _client.auth.signOut());
  }

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    ProfileRecord? profile;
    var profileLoaded = false;
    var rolesLoaded = true;
    final roles = <String>{};

    try {
      profile = await _profiles.fetchProfile(user.id).timeout(_timeout);
      profileLoaded = true;
    } catch (error) {
      debugPrint('Could not load SurGo profile: $error');
    }

    try {
      roles.addAll(await _profiles.fetchApprovedRoles(user.id).timeout(_timeout));
    } catch (error) {
      rolesLoaded = false;
      debugPrint('Could not load SurGo roles: $error');
    }

    final profileExists = profileLoaded && profile != null;
    var capabilities = capabilitiesFromRoles(roles);
    if (capabilities.isEmpty && (!rolesLoaded || !profileLoaded)) {
      // A degraded read must not lock a valid Supabase session out of the app.
      // This is only the network-failure path; a successful read that returns
      // no profile is handled as first-run onboarding instead of a silent
      // passenger grant.
      capabilities = const {CapabilityType.passenger};
    }

    // The auth trigger gives every new provider user a passenger profile, so a
    // "registered" account is one with a phone identity or an explicit marker.
    // A Google-only account is walked through onboarding instead of being
    // dropped into a dashboard it never finished creating. A provisioned demo
    // identity is already complete and never revisits onboarding.
    final onboarded = user.metadata['surgo_onboarded'] == true;
    final isDemoAccount = user.metadata['surgo_demo'] == true;
    final needsOnboarding = !isDemoAccount &&
        profileLoaded &&
        rolesLoaded &&
        ((!profileExists && capabilities.isEmpty) ||
            (profileExists &&
                capabilities.isNotEmpty &&
                !user.hasPhoneIdentity &&
                !onboarded));

    return SurgoIdentity(
      userId: user.id,
      phone: profile?.phone?.trim().isNotEmpty == true
          ? profile!.phone!.trim()
          : user.phone,
      email: profile?.email?.trim().isNotEmpty == true
          ? profile!.email!.trim()
          : user.email,
      fullName: profile != null && profile.fullName.trim().isNotEmpty
          ? profile.fullName.trim()
          : user.fullName,
      capabilities: capabilities,
      eligibleCapabilities: eligibleCapabilitiesFor(capabilities),
      roles: roles,
      providers: user.providers,
      profileExists: profileExists,
      needsOnboarding: needsOnboarding,
      isDemoAccount: isDemoAccount,
    );
  }

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) {
    return _guard(() async {
      await _client.auth.updateUser(UserAttributes(data: {
        'full_name': fullName.trim(),
        'surgo_phone': phone,
        'surgo_onboarded': true,
      }));
    });
  }

  @override
  Future<bool> linkGoogleIdentity() {
    return _guard(() {
      return _client.auth.linkIdentity(
        OAuthProvider.google,
        redirectTo: _oauthRedirect,
      );
    });
  }

  @override
  Future<void> requestPhoneLink(String phone) {
    return _guard(() async {
      await _client.auth.updateUser(UserAttributes(phone: phone));
    });
  }

  @override
  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  }) {
    return _guard(() async {
      await _client.auth.verifyOTP(
        phone: phone,
        token: token,
        type: OtpType.phoneChange,
      );
    });
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_timeout);
    } on AuthFailure {
      rethrow;
    } on AuthException catch (error) {
      throw AuthFailure.from(error);
    } catch (error) {
      throw AuthFailure.from(error);
    }
  }

  AuthUser? _authUser(User? user) {
    if (user == null) return null;
    final providers = <String>{};
    for (final identity in user.identities ?? const <UserIdentity>[]) {
      if (identity.provider.isNotEmpty) providers.add(identity.provider);
    }
    final metadataProviders = user.appMetadata['providers'];
    if (metadataProviders is List) {
      for (final provider in metadataProviders) {
        if (provider is String && provider.isNotEmpty) providers.add(provider);
      }
    }
    if (providers.isEmpty) {
      if (user.phone != null) providers.add('phone');
      if (user.email != null) providers.add('email');
    }

    return AuthUser(
      id: user.id,
      phone: user.phone,
      email: user.email,
      fullName: fullNameFromMetadata(user.userMetadata ?? const {}),
      metadata: user.userMetadata ?? const {},
      providers: providers,
    );
  }
}

/// Used when Supabase could not initialize. It keeps the app bootable while
/// refusing to fake a session: identity always comes from the provider.
class DisabledAuthRepository implements AuthRepository {
  const DisabledAuthRepository();

  static const AuthFailure _offline = AuthFailure(
    AuthFailureCode.providerUnavailable,
    'Sign-in is unavailable right now. Check your connection and try again.',
  );

  @override
  bool get isMock => false;

  @override
  bool get isAvailable => false;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();

  @override
  Future<AuthUser?> restoreSession() async => null;

  @override
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) async {
    throw _offline;
  }

  @override
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    throw _offline;
  }

  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async {
    throw _offline;
  }

  @override
  Future<bool> signInWithGoogle() async => throw _offline;

  @override
  Future<void> signOut() async {}

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async => throw _offline;

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {
    throw _offline;
  }

  @override
  Future<bool> linkGoogleIdentity() async => throw _offline;

  @override
  Future<void> requestPhoneLink(String phone) async => throw _offline;

  @override
  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  }) async {
    throw _offline;
  }
}
