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
    return _authUser(_client.auth.currentUser);
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
    var rolesLoaded = true;
    final roles = <String>{};

    try {
      profile = await _profiles.fetchProfile(user.id).timeout(_timeout);
    } catch (error) {
      debugPrint('Could not load SurGo profile: $error');
    }

    try {
      roles.addAll(await _profiles.fetchApprovedRoles(user.id).timeout(_timeout));
    } catch (error) {
      rolesLoaded = false;
      debugPrint('Could not load SurGo roles: $error');
    }

    var capabilities = capabilitiesFromRoles(roles);
    if (capabilities.isEmpty && (!rolesLoaded || profile == null)) {
      // A missing profile or a degraded read must not lock a valid Supabase
      // session out of the app; the auth trigger guarantees passenger for a
      // newly created user, so this only fills the gap for a failed read.
      capabilities = const {CapabilityType.passenger};
    }

    return SurgoIdentity(
      userId: user.id,
      phone: user.phone,
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
    );
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
  Future<bool> signInWithGoogle() async => throw _offline;

  @override
  Future<void> signOut() async {}

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async => throw _offline;

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
