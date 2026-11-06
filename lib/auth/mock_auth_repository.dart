import 'dart:async';

import '../data/db_models.dart';
import '../data/db_service.dart';
import 'auth_models.dart';
import 'auth_repository.dart';

/// In-memory identity provider for tests and previews. It mirrors the Supabase
/// contract without passwords: a fixed OTP stands in for the SMS code and the
/// seed accounts supply the profiles and approved roles.
///
/// Production never constructs this class; `main` installs
/// `SupabaseAuthRepository` (or `DisabledAuthRepository` when it cannot boot).
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({this.otpCode = defaultOtpCode});

  static const String defaultOtpCode = '123456';

  final String otpCode;
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
  Future<AuthUser?> restoreSession() async => _user;

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
    _emit(user);
    return user;
  }

  @override
  Future<bool> signInWithGoogle() async {
    final accounts = DbService.instance.accounts;
    if (accounts.isEmpty) {
      throw const AuthFailure(
        AuthFailureCode.providerUnavailable,
        'Google sign-in is unavailable in this preview.',
      );
    }
    final account = accounts.first;
    final user = AuthUser(
      id: account.authUserId ?? 'mock:google:${account.id}',
      phone: account.phone,
      email: account.email,
      fullName: account.name,
      providers: const {'google'},
    );
    _user = user;
    _emit(user);
    return true;
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _pending.clear();
    _pendingLinkPhone = null;
    _emit(null);
  }

  @override
  Future<SurgoIdentity> loadIdentity(AuthUser user) async {
    final account = _accountForUser(user);
    final capabilities = account?.approvedCapabilities ??
        const <CapabilityType>{CapabilityType.passenger};
    final eligible = account?.eligibleCapabilities ??
        eligibleCapabilitiesFor(capabilities);

    return SurgoIdentity(
      userId: user.id,
      phone: user.phone ?? account?.phone,
      email: user.email ?? account?.email,
      fullName: user.fullName ?? account?.name,
      capabilities: capabilities,
      eligibleCapabilities: eligible,
      roles: _rolesFromCapabilities(capabilities),
      providers: user.providers,
    );
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
    _emit(linked);
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

  Account? _accountForUser(AuthUser user) {
    for (final account in DbService.instance.accounts) {
      if (account.authUserId == user.id) return account;
    }
    if (user.phone != null) {
      final phone = _accountForPhone(user.phone!);
      if (phone != null) return phone;
    }
    final email = user.email?.trim().toLowerCase();
    if (email != null && email.isNotEmpty) {
      for (final account in DbService.instance.accounts) {
        if (account.email.trim().toLowerCase() == email) return account;
      }
    }
    return null;
  }

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
