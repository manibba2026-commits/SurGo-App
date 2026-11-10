import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/db_models.dart';

/// The identity provider SurGo uses for every account.
///
/// Business data still lives in the local demo layer for now, but sessions,
/// linked identities and OTP verification always come from Supabase Auth.
enum AuthStatus { uninitialized, restoring, signedOut, signedIn, error }

enum AuthFailureCode {
  invalidPhone,
  invalidCode,
  rateLimited,
  noAccount,
  providerUnavailable,
  smsFailed,
  redirectMisconfigured,
  network,
  cancelled,
  unknown,
}

/// A user-facing auth error. Repositories translate provider exceptions into
/// this type so screens never render raw Supabase errors.
class AuthFailure implements Exception {
  final AuthFailureCode code;
  final String message;

  const AuthFailure(this.code, this.message);

  static AuthFailure from(Object error) {
    if (error is AuthFailure) return error;
    if (error is AuthException) return _fromAuthException(error);
    if (error is TimeoutException) {
      return const AuthFailure(
        AuthFailureCode.network,
        'The connection timed out. Check your signal and try again.',
      );
    }

    final text = error.toString().toLowerCase();
    if (text.contains('socketexception') ||
        text.contains('clientexception') ||
        text.contains('failed host lookup') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable')) {
      return const AuthFailure(
        AuthFailureCode.network,
        'You appear to be offline. Check your connection and try again.',
      );
    }
    return const AuthFailure(
      AuthFailureCode.unknown,
      'Something went wrong signing you in. Please try again.',
    );
  }

  static AuthFailure _fromAuthException(AuthException error) {
    final text = error.message.toLowerCase();

    if (text.contains('token has expired') ||
        text.contains('invalid otp') ||
        (text.contains('token') && text.contains('invalid')) ||
        text.contains('invalid verification code')) {
      return const AuthFailure(
        AuthFailureCode.invalidCode,
        'That code is incorrect or has expired. Request a new one.',
      );
    }
    if (text.contains('for security purposes') ||
        text.contains('rate limit') ||
        text.contains('too many requests')) {
      return const AuthFailure(
        AuthFailureCode.rateLimited,
        'Too many attempts. Wait a moment before requesting another code.',
      );
    }
    if (text.contains('provider is not enabled') ||
        text.contains('unsupported provider') ||
        text.contains('phone provider') ||
        text.contains('email provider')) {
      return const AuthFailure(
        AuthFailureCode.providerUnavailable,
        'This sign-in method is not available right now.',
      );
    }
    if (text.contains('redirect') &&
        (text.contains('not allowed') || text.contains('invalid'))) {
      return const AuthFailure(
        AuthFailureCode.redirectMisconfigured,
        'Sign-in could not return to SurGo. Contact SurGo support.',
      );
    }
    if (text.contains('sms') &&
        (text.contains('error') || text.contains('failed'))) {
      return const AuthFailure(
        AuthFailureCode.smsFailed,
        'We could not send the text message. Try again in a moment.',
      );
    }
    if (text.contains('signups not allowed') ||
        text.contains('user not found') ||
        text.contains('no user')) {
      return const AuthFailure(
        AuthFailureCode.noAccount,
        'We could not find a SurGo account with those details.',
      );
    }
    if (text.contains('phone') && text.contains('invalid')) {
      return const AuthFailure(
        AuthFailureCode.invalidPhone,
        'Enter a valid phone number with the country code.',
      );
    }
    return AuthFailure(AuthFailureCode.unknown, error.message);
  }

  @override
  String toString() => 'AuthFailure($code): $message';
}

/// The Supabase Auth user fields SurGo needs. No tokens or secrets are kept.
class AuthUser {
  final String id;
  final String? phone;
  final String? email;
  final String? fullName;
  final Map<String, dynamic> metadata;
  final Set<String> providers;

  const AuthUser({
    required this.id,
    this.phone,
    this.email,
    this.fullName,
    this.metadata = const {},
    this.providers = const {},
  });

  bool get hasPhoneIdentity => providers.contains('phone');
  bool get hasGoogleIdentity => providers.contains('google');

  AuthUser copyWith({
    String? phone,
    String? email,
    String? fullName,
    Map<String, dynamic>? metadata,
    Set<String>? providers,
  }) {
    return AuthUser(
      id: id,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      fullName: fullName ?? this.fullName,
      metadata: metadata ?? this.metadata,
      providers: providers ?? this.providers,
    );
  }
}

/// Profile plus approved roles loaded after authentication.
///
/// [capabilities] is the only role truth the app uses to unlock modes. Admin
/// is tracked for account settings, but the admin dashboard is a separate app.
class SurgoIdentity {
  final String userId;
  final String? phone;
  final String? email;
  final String? fullName;
  final Set<CapabilityType> capabilities;
  final Set<CapabilityType> eligibleCapabilities;
  final Set<String> roles;
  final Set<String> providers;

  /// Whether the provider returned a SurGo profile row for this auth user.
  /// A missing row on a successful read is different from a failed read.
  final bool profileExists;

  /// Whether this Google account still has to finish registration. A returned
  /// profile is not enough: the auth trigger creates a passenger placeholder
  /// for every new provider user, so onboarding is keyed on the missing phone
  /// identity and the `surgo_onboarded` metadata marker instead.
  final bool needsOnboarding;

  const SurgoIdentity({
    required this.userId,
    required this.capabilities,
    required this.eligibleCapabilities,
    required this.roles,
    required this.providers,
    this.phone,
    this.email,
    this.fullName,
    this.profileExists = false,
    this.needsOnboarding = false,
  });

  bool get hasPhoneIdentity => providers.contains('phone');
  bool get hasGoogleIdentity => providers.contains('google');
  bool get isAdmin => roles.contains('admin');

  String get displayName {
    final name = fullName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mail = email?.trim();
    if (mail != null && mail.isNotEmpty) return mail.split('@').first;
    final number = phone?.trim();
    if (number != null && number.isNotEmpty) return number;
    return 'SurGo User';
  }
}

/// Supabase requires E.164, and the pilot only accepts Philippine mobiles.
///
/// Accept the shapes people type in: `09171234567`, `+639171234567`,
/// `9171234567`, `639171234567` and `00639171234567`. Separators are tolerated
/// because this runs at submit time; the input formatter never inserts them.
/// A country code that is not `63`, a landline, a duplicated `63`/`0` prefix or
/// a wrong length returns null so the caller can show an error without editing
/// the number the user sees.
String? normalizePhoneNumber(String raw) {
  var cleaned = raw.trim().replaceAll(RegExp(r'[\s\-().]'), '');
  if (cleaned.isEmpty) return null;

  if (cleaned.startsWith('00')) {
    cleaned = '+${cleaned.substring(2)}';
  }

  late final String national;
  if (cleaned.startsWith('+')) {
    final digits = cleaned.substring(1);
    if (!RegExp(r'^\d+$').hasMatch(digits)) return null;
    if (!digits.startsWith('63')) return null;
    national = digits.substring(2);
  } else {
    if (!RegExp(r'^\d+$').hasMatch(cleaned)) return null;
    if (cleaned.startsWith('63') && cleaned.length > 10) {
      national = cleaned.substring(2);
    } else if (cleaned.length == 11 && cleaned.startsWith('0')) {
      national = cleaned.substring(1);
    } else {
      national = cleaned;
    }
  }

  // PH mobile: 9 + 9 digits (0917 123 4567 / +63 917 123 4567).
  if (!RegExp(r'^9\d{9}$').hasMatch(national)) return null;
  return '+63$national';
}

/// Maps approved `user_roles.role` values to the app's capability gates.
Set<CapabilityType> capabilitiesFromRoles(Iterable<String> roles) {
  final capabilities = <CapabilityType>{};
  for (final role in roles.map((r) => r.toLowerCase())) {
    switch (role) {
      case 'passenger':
        capabilities.add(CapabilityType.passenger);
      case 'earner':
        capabilities.add(CapabilityType.earner);
      case 'rider':
        capabilities
          ..add(CapabilityType.rider)
          ..add(CapabilityType.earner);
      case 'vehicle_owner':
        capabilities.add(CapabilityType.vehicleOwner);
    }
  }
  return capabilities;
}

Set<CapabilityType> eligibleCapabilitiesFor(Set<CapabilityType> approved) {
  return {
    for (final capability in CapabilityType.values)
      if (!approved.contains(capability)) capability,
  };
}

String? fullNameFromMetadata(Map<String, dynamic> metadata) {
  for (final key in const ['full_name', 'name', 'display_name']) {
    final value = metadata[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  final given = metadata['given_name'];
  final family = metadata['family_name'];
  if ((given is String && given.trim().isNotEmpty) ||
      (family is String && family.trim().isNotEmpty)) {
    return [
      if (given is String && given.trim().isNotEmpty) given.trim(),
      if (family is String && family.trim().isNotEmpty) family.trim(),
    ].join(' ');
  }
  return null;
}
