import 'dart:async';

import '../data/db_models.dart';
import '../data/db_service.dart';
import 'auth_models.dart';
import 'auth_repository.dart';
import 'demo_auth.dart';

/// In-memory identity provider for tests and previews. It mirrors the Supabase
/// contract without passwords: a fixed OTP stands in for the SMS code and the
/// seed accounts supply the profiles and approved roles.
///
/// Production never constructs this class; `main` installs
/// `SupabaseAuthRepository` (or `DisabledAuthRepository` when it cannot boot).
/// The presentation build opts in with `SURGO_DEMO_AUTH=true` and passes a
/// [DemoSessionStore] so the identity survives a restart.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({
    this.otpCode = defaultOtpCode,
    this.sessionStore,
  });

  static const String defaultOtpCode = '123456';

  final String otpCode;
  final DemoSessionStore? sessionStore;
  final StreamController<AuthUser?> _controller =
      StreamController<AuthUser?>.broadcast();

  final Map<String, _PendingOtp> _pending = {};
  String? _pendingLinkPhone;
  AuthUser? _user;

  @override
  bool get isMock => true;

  @override
  bool get isAvailable => true;

  @override
  Stream<AuthUser?> get authStateChanges => _controller.stream;

  @override
  Future<AuthUser?> restoreSession() async {
    if (_user != null) return _user;
    final store = sessionStore;
    if (store == null) return null;
    final session = await store.read();
    if (session == null) return null;
    return _user = session.toUser();
  }

  /// Resolves the login box's input: an account number (`ACC003`) or any phone
  /// shape [normalizePhoneNumber] accepts. Returns null when neither matches an
  /// existing seed account.
  Account? accountForIdentifier(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    for (final account in DbService.instance.accounts) {
      if (account.id.toLowerCase() == value.toLowerCase()) return account;
    }
    final phone = normalizePhoneNumber(value);
    return phone == null ? null : _accountForPhone(phone);
  }

  @override
  Future<void> requestPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) async {
    final normalized = normalizePhoneNumber(phone);
    if (normalized == null) {
      throw const AuthFailure(
        AuthFailureCode.invalidPhone,
        'Enter a valid phone number with the country code.',
      );
    }
    final account = _accountForPhone(normalized);
    if (!createUser && account == null) {
      throw const AuthFailure(
        AuthFailureCode.noAccount,
        'We could not find a SurGo account with that number. Sign up first.',
      );
    }
    _pending[normalized] = _PendingOtp(
      createUser: createUser,
      fullName: fullName?.trim(),
    );
  }

  @override
  Future<AuthUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    final normalized = normalizePhoneNumber(phone);
    if (normalized == null) {
      throw const AuthFailure(
        AuthFailureCode.invalidPhone,
        'Enter a valid phone number with the country code.',
      );
    }
    final pending = _pending[normalized];
    if (pending == null) {
      throw const AuthFailure(
        AuthFailureCode.invalidCode,
        'Request a new code before verifying.',
      );
    }
    if (token.trim() != otpCode) {
      throw const AuthFailure(
        AuthFailureCode.invalidCode,
        'That code is incorrect or has expired. Request a new one.',
      );
    }

    final account = _accountForPhone(normalized);
    final user = AuthUser(
      id: account?.authUserId ?? 'mock:phone:$normalized',
      phone: normalized,
      email: account?.email,
      fullName: pending.fullName ?? account?.name,
      providers: const {'phone'},
    );
    _pending.remove(normalized);
    _user = user;
    await _persist(user);
    _emit(user);
    return user;
  }

  /// Preview stand-in for the server-verified demo PIN. It matches a seed
  /// account by phone and accepts the same fixed code the preview uses for
  /// OTP; the hosted build verifies each account's real PIN server-side.
  @override
  Future<AuthUser> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async {
    final normalized = normalizePhoneNumber(phone);
    if (normalized == null) {
      throw const AuthFailure(
        AuthFailureCode.invalidPhone,
        'Enter a valid Philippine mobile number, for example 0917 000 0001.',
      );
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const AuthFailure(
        AuthFailureCode.invalidPin,
        'Enter the 6-digit PIN for this demo account.',
      );
    }
    final account = _accountForPhone(normalized);
    if (account == null || pin != otpCode) {
      throw const AuthFailure(
        AuthFailureCode.invalidPin,
        'That phone number and PIN do not match a demo account.',
      );
    }
    final user = AuthUser(
      id: account.authUserId ?? 'mock:pin:$normalized',
      phone: normalized,
      email: account.email,
      fullName: account.name,
      providers: const {'phone'},
      metadata: const {'surgo_onboarded': true},
      isDemoAccount: true,
    );
    _user = user;
    await _persist(user);
    _emit(user);
    return user;
  }

  @override
  Future<bool> signInWithGoogle() async {
    return _signInWithProvider('google');
  }

  @override
  Future<bool> signInWithFacebook() async {
    return _signInWithProvider('facebook');
  }

  Future<bool> _signInWithProvider(String provider) async {
    final accounts = DbService.instance.accounts;
    if (accounts.isEmpty) {
      throw AuthFailure(
        AuthFailureCode.providerUnavailable,
        '${_providerLabel(provider)} sign-in is unavailable in this preview.',
      );
    }
    final account = accounts.first;
    final user = AuthUser(
      id: account.authUserId ?? 'mock:$provider:${account.id}',
      phone: account.phone,
      email: account.email,
      fullName: account.name,
      providers: {provider},
    );
    _user = user;
    await _persist(user);
    _emit(user);
    return true;
  }

  @override
  Future<AuthUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!_isValidEmail(email)) {
      throw const AuthFailure(
        AuthFailureCode.invalidEmail,
        'Enter a valid email address.',
      );
    }
    if (password.length < 8) {
      throw const AuthFailure(
        AuthFailureCode.weakPassword,
        'Use a password with at least 8 characters.',
      );
    }
    final account = _accountForEmail(email);
    if (account == null) {
      throw const AuthFailure(
        AuthFailureCode.noAccount,
        'We could not find a SurGo account with that email. Create one first.',
      );
    }
    final user = AuthUser(
      id: account.authUserId ?? 'mock:email:${account.id}',
      phone: account.phone,
      email: account.email,
      fullName: account.name,
      providers: const {'email'},
    );
    _user = user;
    await _persist(user);
    _emit(user);
    return user;
  }

  @override
  Future<AuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async {
    if (!_isValidEmail(email)) {
      throw const AuthFailure(
        AuthFailureCode.invalidEmail,
        'Enter a valid email address.',
      );
    }
    if (password.length < 8) {
      throw const AuthFailure(
        AuthFailureCode.weakPassword,
        'Use a password with at least 8 characters.',
      );
    }
    if (_accountForEmail(email) != null) {
      throw const AuthFailure(
        AuthFailureCode.emailInUse,
        'An account with that email already exists. Sign in instead.',
      );
    }
    final name = fullName?.trim();
    final user = AuthUser(
      id: 'mock:email:${email.trim().toLowerCase()}',
      email: email.trim().toLowerCase(),
      fullName: name == null || name.isEmpty ? null : name,
      providers: const {'email'},
      metadata: const {'surgo_onboarded': true},
    );
    _user = user;
    await _persist(user);
    _emit(user);
    return user;
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _pending.clear();
    _pendingLinkPhone = null;
    await sessionStore?.clear();
    _emit(null);
  }

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    final account = _accountForUser(user);
    final capabilities = account?.approvedCapabilities ??
        const <CapabilityType>{CapabilityType.passenger};
    final eligible =
        account?.eligibleCapabilities ?? eligibleCapabilitiesFor(capabilities);

    return SurgoIdentity(
      userId: user.id,
      phone: user.phone ?? account?.phone,
      email: user.email ?? account?.email,
      fullName: user.fullName ?? account?.name,
      capabilities: capabilities,
      eligibleCapabilities: eligible,
      roles: _rolesFromCapabilities(capabilities),
      providers: user.providers,
      profileExists: true,
      isDemoAccount: user.isDemoAccount,
    );
  }

  @override
  Future<void> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {
    final user = _user;
    if (user == null) {
      throw const AuthFailure(
        AuthFailureCode.noAccount,
        'Sign in before completing your account.',
      );
    }
    final updated = user.copyWith(
      phone: phone,
      fullName: fullName.trim(),
      metadata: {
        ...user.metadata,
        'full_name': fullName.trim(),
        'surgo_phone': phone,
        'surgo_onboarded': true,
      },
      providers: {...user.providers, 'phone'},
    );
    _user = updated;
    await _persist(updated);
    _emit(updated);
  }

  @override
  Future<bool> linkGoogleIdentity() async {
    final user = _user;
    if (user == null) {
      throw const AuthFailure(
        AuthFailureCode.noAccount,
        'Sign in before linking a Google account.',
      );
    }
    final linked = user.copyWith(providers: {...user.providers, 'google'});
    _user = linked;
    await _persist(linked);
    _emit(linked);
    return true;
  }

  @override
  Future<void> requestPhoneLink(String phone) async {
    final normalized = normalizePhoneNumber(phone);
    if (normalized == null) {
      throw const AuthFailure(
        AuthFailureCode.invalidPhone,
        'Enter a valid phone number with the country code.',
      );
    }
    if (_accountForPhone(normalized) != null) {
      throw const AuthFailure(
        AuthFailureCode.invalidPhone,
        'That number is already linked to a SurGo account.',
      );
    }
    _pendingLinkPhone = normalized;
  }

  @override
  Future<void> verifyPhoneLink({
    required String phone,
    required String token,
  }) async {
    final user = _user;
    if (user == null) {
      throw const AuthFailure(
        AuthFailureCode.noAccount,
        'Sign in before linking a phone number.',
      );
    }
    final normalized = normalizePhoneNumber(phone);
    if (normalized == null || normalized != _pendingLinkPhone) {
      throw const AuthFailure(
        AuthFailureCode.invalidPhone,
        'Request a new code before verifying.',
      );
    }
    if (token.trim() != otpCode) {
      throw const AuthFailure(
        AuthFailureCode.invalidCode,
        'That code is incorrect or has expired. Request a new one.',
      );
    }
    _pendingLinkPhone = null;
    final linked = user.copyWith(
      phone: normalized,
      providers: {...user.providers, 'phone'},
    );
    _user = linked;
    await _persist(linked);
    _emit(linked);
  }

  Future<void> _persist(AuthUser user) async {
    final store = sessionStore;
    if (store == null) return;
    await store.write(DemoSession.fromUser(user));
  }

  void _emit(AuthUser? user) {
    if (!_controller.isClosed) _controller.add(user);
  }

  Account? _accountForPhone(String phone) {
    final digits = _digits(phone);
    for (final account in DbService.instance.accounts) {
      if (_digits(account.phone) == digits) return account;
    }
    return null;
  }

  Account? _accountForEmail(String email) {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    for (final account in DbService.instance.accounts) {
      if (account.email.trim().toLowerCase() == normalized) return account;
    }
    return null;
  }

  Account? _accountForUser(AuthUser user) {
    for (final account in DbService.instance.accounts) {
      if (account.authUserId == user.id) return account;
    }
    if (user.phone != null) {
      final phone = _accountForPhone(user.phone!);
      if (phone != null) return phone;
    }
    final email = user.email;
    return email == null ? null : _accountForEmail(email);
  }

  bool _isValidEmail(String raw) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(raw.trim());

  String _providerLabel(String provider) => provider.isEmpty
      ? 'Social'
      : '${provider[0].toUpperCase()}${provider.substring(1)}';

  Set<String> _rolesFromCapabilities(Set<CapabilityType> capabilities) {
    return {
      if (capabilities.contains(CapabilityType.passenger)) 'passenger',
      if (capabilities.contains(CapabilityType.rider)) 'rider',
      if (capabilities.contains(CapabilityType.earner)) 'earner',
      if (capabilities.contains(CapabilityType.vehicleOwner)) 'vehicle_owner',
    };
  }

  String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');
}

class _PendingOtp {
  final bool createUser;
  final String? fullName;

  const _PendingOtp({required this.createUser, this.fullName});
}
