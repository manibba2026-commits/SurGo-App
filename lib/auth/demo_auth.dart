import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_models.dart';

/// Compile-time switch for the presentation build:
/// `flutter run --dart-define=SURGO_DEMO_AUTH=true`.
///
/// When it is off, `main` installs Supabase Auth exactly as before. Tests flip
/// [enabled] directly because a `const bool.fromEnvironment` cannot vary within
/// one test run.
class DemoAuthConfig {
  const DemoAuthConfig._();

  static bool enabled = const bool.fromEnvironment('SURGO_DEMO_AUTH');

  static const String defaultOtpCode = '123456';
  static const String defaultPin = '123456';
  static const int pinLength = 6;
}

/// The four identities prepared for the presentation. Each one already exists
/// in `assets/db/accounts.json` (and its hosted profile/roles); no new person
/// or profile is created for the demo.
enum DemoRole { passenger, rider, vehicleOwner, helper }

class DemoAccountRef {
  final String accountNumber;
  final DemoRole role;

  const DemoAccountRef({required this.accountNumber, required this.role});

  String get roleLabel => switch (role) {
        DemoRole.passenger => 'Passenger',
        DemoRole.rider => 'Rider',
        DemoRole.vehicleOwner => 'Vehicle owner',
        DemoRole.helper => 'Helper · Pasuyo',
      };
}

/// The account number is the existing seed account id, kept unique by
/// `assets/db/accounts.json`.
const List<DemoAccountRef> demoAccountRefs = [
  DemoAccountRef(accountNumber: 'ACC003', role: DemoRole.passenger),
  DemoAccountRef(accountNumber: 'ACC006', role: DemoRole.rider),
  DemoAccountRef(accountNumber: 'ACC002', role: DemoRole.vehicleOwner),
  DemoAccountRef(accountNumber: 'ACC007', role: DemoRole.helper),
];

DemoAccountRef? demoAccountRefFor(String accountId) {
  final needle = accountId.trim().toUpperCase();
  for (final ref in demoAccountRefs) {
    if (ref.accountNumber == needle) return ref;
  }
  return null;
}

/// The session fields persisted between demo launches. It contains only what
/// [AuthUser] already exposes: no token or secret is written to disk.
class DemoSession {
  final String userId;
  final String phone;
  final String? email;
  final String? fullName;
  final Set<String> providers;

  const DemoSession({
    required this.userId,
    required this.phone,
    this.email,
    this.fullName,
    this.providers = const {'phone'},
  });

  factory DemoSession.fromUser(AuthUser user) => DemoSession(
        userId: user.id,
        phone: user.phone ?? '',
        email: user.email,
        fullName: user.fullName,
        providers: user.providers,
      );

  AuthUser toUser() => AuthUser(
        id: userId,
        phone: phone.isEmpty ? null : phone,
        email: email,
        fullName: fullName,
        providers: providers,
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'phone': phone,
        'email': email,
        'fullName': fullName,
        'providers': providers.toList(),
      };

  static DemoSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final userId = raw['userId'];
    final phone = raw['phone'];
    if (userId is! String || userId.isEmpty || phone is! String) return null;
    final email = raw['email'];
    final fullName = raw['fullName'];
    final providers = raw['providers'];
    return DemoSession(
      userId: userId,
      phone: phone,
      email: email is String ? email : null,
      fullName: fullName is String ? fullName : null,
      providers: providers is List
          ? {
              for (final value in providers)
                if (value is String) value,
            }
          : const {'phone'},
    );
  }
}

abstract class DemoSessionStore {
  Future<DemoSession?> read();

  Future<void> write(DemoSession session);

  Future<void> clear();
}

/// Stores the signed-in demo identity on the device. A reinstalled app starts
/// signed out, which is the same contract Supabase's own session has.
class SharedPreferencesDemoSessionStore implements DemoSessionStore {
  static const String storageKey = 'surgo.demo.session';

  @override
  Future<DemoSession?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(storageKey);
    if (raw == null) return null;
    try {
      return DemoSession.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(DemoSession session) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(storageKey);
  }
}

/// Device-level demo PIN. It is salted and SHA-256 hashed on the device; until
/// somebody changes it, [DemoAuthConfig.defaultPin] is the accepted value.
class DemoPinStore {
  DemoPinStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const String saltKey = 'surgo.demo.pin.salt';
  static const String hashKey = 'surgo.demo.pin.hash';

  final Future<SharedPreferences> Function() _preferences;

  Future<bool> get hasCustomPin async {
    final preferences = await _preferences();
    return preferences.getString(saltKey) != null &&
        preferences.getString(hashKey) != null;
  }

  Future<bool> verify(String pin) async {
    final preferences = await _preferences();
    final salt = preferences.getString(saltKey);
    final stored = preferences.getString(hashKey);
    if (salt == null || stored == null) {
      return pin == DemoAuthConfig.defaultPin;
    }
    return _digest(pin, salt) == stored;
  }

  Future<void> setPin(String pin) async {
    final preferences = await _preferences();
    final salt = _newSalt();
    await preferences.setString(saltKey, salt);
    await preferences.setString(hashKey, _digest(pin, salt));
  }

  /// Returns the device to the default demo PIN so a forgotten PIN can be
  /// replaced by signing in again.
  Future<void> reset() async {
    final preferences = await _preferences();
    await preferences.remove(saltKey);
    await preferences.remove(hashKey);
  }

  static String _newSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _digest(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}

enum PinUnlockResult { success, incorrect }

enum PinChangeResult {
  success,
  incorrectCurrent,
  invalidNew,
  sameAsCurrent,
}

bool isDemoPin(String value) =>
    RegExp('^\\d{${DemoAuthConfig.pinLength}}\$').hasMatch(value);
