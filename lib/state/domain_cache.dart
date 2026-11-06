import 'dart:async';

import 'package:flutter/foundation.dart';

import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_registry.dart';
import '../repositories/repository_state.dart';

/// Whose data a slot is read for.
///
/// A Supabase build has one profile row per signed-in user, so every role
/// resolves to the same id. A seeded build keeps a separate passenger, earner
/// and owner profile, and the screens show those, so the role selects which
/// seed row a read is keyed by. See [DomainCache._keyFor].
enum ActorRole { signedInUser, passenger, earner, vehicleOwner }

/// A screen read the repository layer can answer.
///
/// A migrated read is one member here plus one branch in [DomainCache._read],
/// so this enum doubles as the inventory of what screens take from repositories
/// rather than from the seed.
enum DomainSlot {
  profile,
  profileRoles,

  /// The profiles a mode's home screen greets, keyed by [ActorRole] so a seeded
  /// build reads the passenger and earner rows it shows.
  passengerProfile,
  earnerProfile,
  barangays,
  unreadPassengerNotifications,
  unreadEarnerNotifications,
  passengerWalletBalance,
  earnerWalletBalance,
  ownerWalletBalance,
}

/// Repository reads held for the screens, each in an explicit state.
///
/// Screens rebuild on every [AppState] notification, so a result is cached per
/// slot instead of re-fetched per frame. Mock mode re-runs the cached slots
/// when app data changes because the seed mutates in place; a Supabase slot is
/// read once and re-read only after a retry, and a failed read stays failed
/// instead of falling back to seed rows.
class DomainCache extends ChangeNotifier {
  DomainCache({
    required RepositoryRegistry Function() registry,
    required String Function() profileKey,
    required String Function(ActorRole role) seedProfileKey,
  })  : _registryOf = registry,
        _profileKeyOf = profileKey,
        _seedKeyOf = seedProfileKey;

  final RepositoryRegistry Function() _registryOf;
  final String Function() _profileKeyOf;
  final String Function(ActorRole role) _seedKeyOf;

  /// Forwards finished reads to [AppState] so everything listening to the app
  /// state rebuilds. The cache stays independent of the state object itself.
  VoidCallback? onChanged;

  final Map<DomainSlot, RepositoryState<Object?>> _states = {};
  final Map<DomainSlot, int> _generations = {};
  final Set<DomainSlot> _inFlight = {};
  bool _propagating = false;
  bool _notifyScheduled = false;
  bool _disposed = false;

  @override
  void dispose() {
    // A read can still be in flight when the app tears the cache down; the
    // deferred notification must not arrive after that.
    _disposed = true;
    super.dispose();
  }

  /// The cached state for [slot], re-typed for the calling screen.
  RepositoryState<T> stateOf<T>(DomainSlot slot) {
    final state = _states[slot];
    if (state == null) return RepositoryState<T>.idle();
    if (state.isLoading) return RepositoryState<T>.loading();
    if (state.isEmpty) return RepositoryState<T>.empty();
    if (state.hasFailure) return RepositoryState<T>.failure(state.failure!);
    return RepositoryState<T>.data(state.data as T);
  }

  /// The rows or record behind [slot], or null while it is unread.
  T? dataOf<T>(DomainSlot slot) => stateOf<T>(slot).data;

  /// Reads [slot] unless a result or an in-flight read already covers it.
  ///
  /// A screen calls this once when it opens; later updates arrive through
  /// [onAppDataChanged] in mock mode or [retry].
  Future<void> ensure(DomainSlot slot) =>
      _states.containsKey(slot) ? Future.value() : _load(slot, keepOld: false);

  /// Reads [slot] again, keeping the previous result on screen until it lands.
  Future<void> refresh(DomainSlot slot) => _load(slot, keepOld: true);

  /// Reads [slot] again and shows the loading state, for a screen that is
  /// displaying a failure or an empty list and was asked to try once more.
  Future<void> retry(DomainSlot slot) => _load(slot, keepOld: false);

  /// Re-reads every slot a screen has already asked for.
  ///
  /// A cached answer belongs to whoever was signed in when it was read, so a
  /// session or mode change must not leave it on screen. The slots are kept
  /// rather than dropped because a screen only reads once when it opens.
  void restart() {
    final slots = List.of(_states.keys);
    _states.clear();
    for (final slot in slots) {
      unawaited(_load(slot, keepOld: false));
    }
  }

  /// Reads every slot once, in mock mode only.
  ///
  /// The seed is already in memory, so a development build can have its cached
  /// reads settled before the first frame. A Supabase build must not do this:
  /// it would add network calls to start-up for data the screen may never show,
  /// and boot would end up looking like the source of truth when it is not.
  Future<void> prefill() async {
    if (_registryOf().isSupabaseBacked) return;
    for (final slot in DomainSlot.values) {
      await _load(slot, keepOld: false);
    }
  }

  /// Hook for [AppState] notifications.
  ///
  /// Mock reads mirror the seed, which is mutated in place by the prototype's
  /// write paths, so a write anywhere re-runs the settled slots. Supabase slots
  /// are left alone: a screen must not hammer the database every time some
  /// unrelated part of the app notifies.
  void onAppDataChanged() {
    if (_propagating || _registryOf().isSupabaseBacked) return;
    for (final slot in List.of(_states.keys)) {
      final state = _states[slot];
      if (state == null || state.isLoading) continue;
      unawaited(_load(slot, keepOld: true));
    }
  }

  Future<void> _load(DomainSlot slot, {required bool keepOld}) async {
    if (_inFlight.contains(slot)) return;
    final generation = (_generations[slot] ?? 0) + 1;
    _generations[slot] = generation;
    if (!keepOld) {
      _states[slot] = const RepositoryState.loading();
      _notify();
    }
    _inFlight.add(slot);
    final next = await _attempt(slot);
    _inFlight.remove(slot);

    // A newer read for this slot has started, so this answer is stale.
    if (_generations[slot] != generation) return;
    _states[slot] = next;
    _notify();
  }

  /// Runs [slot]'s read and turns any answer into a state.
  ///
  /// A repository raises [RepositoryFailure] for the cases it can name;
  /// anything else is a bug in this layer and is reported as such rather than
  /// being left to crash the screen that asked for the data.
  Future<RepositoryState<Object?>> _attempt(DomainSlot slot) async {
    try {
      return _stateFor(await _read(slot));
    } on RepositoryFailure catch (failure) {
      return RepositoryState<Object?>.failure(failure);
    } catch (error) {
      return RepositoryState<Object?>.failure(RepositoryFailure(
        RepositoryFailureKind.unknown,
        'This read did not complete as expected.',
        cause: error,
      ));
    }
  }

  Future<Object?> _read(DomainSlot slot) {
    final registry = _registryOf();
    final profileId = _keyFor(ActorRole.signedInUser);
    return switch (slot) {
      DomainSlot.profile => registry.profiles.fetchProfile(profileId),
      DomainSlot.profileRoles => registry.profiles.fetchApprovedRoles(profileId),
      DomainSlot.passengerProfile =>
        registry.profiles.fetchProfile(_keyFor(ActorRole.passenger)),
      DomainSlot.earnerProfile =>
        registry.profiles.fetchProfile(_keyFor(ActorRole.earner)),
      DomainSlot.barangays => _readBarangays(registry),
      DomainSlot.unreadPassengerNotifications =>
        registry.notifications.countUnread(_keyFor(ActorRole.passenger)),
      DomainSlot.unreadEarnerNotifications =>
        registry.notifications.countUnread(_keyFor(ActorRole.earner)),
      DomainSlot.passengerWalletBalance =>
        registry.wallet.fetchBalanceCentavos(_keyFor(ActorRole.passenger)),
      DomainSlot.earnerWalletBalance =>
        registry.wallet.fetchBalanceCentavos(_keyFor(ActorRole.earner)),
      DomainSlot.ownerWalletBalance =>
        registry.wallet.fetchBalanceCentavos(_keyFor(ActorRole.vehicleOwner)),
    };
  }

  /// The id a read for [role] is keyed by.
  ///
  /// A Supabase account is its own profile row, so the role is the same id in
  /// every case. The seed splits one demo account across several profile rows,
  /// so there the role selects which one.
  String _keyFor(ActorRole role) =>
      _registryOf().isSupabaseBacked || role == ActorRole.signedInUser
          ? _profileKeyOf()
          : _seedKeyOf(role);

  /// The same rule, for a caller outside the cache.
  ///
  /// Live position sharing has to know which earner this build is acting as,
  /// and two answers to that question would mean the publisher and the screens
  /// disagree about whose trip is whose.
  String profileKeyFor(ActorRole role) => _keyFor(role);

  /// Barangays belong to the area a build actually serves, so the area is read
  /// first rather than assuming the seed's stand-in id.
  Future<List<BarangayRecord>> _readBarangays(
      RepositoryRegistry registry) async {
    final areas = await registry.catalog.fetchServiceAreas();
    if (areas.isEmpty) {
      throw RepositoryFailure.unsupported(
        'No service area is active yet, so there is nothing to list.',
      );
    }
    return registry.catalog.fetchBarangays(areas.first.id);
  }

  RepositoryState<Object?> _stateFor(Object? value) {
    if (value == null) return const RepositoryState.empty();
    if (value is List && value.isEmpty) return const RepositoryState.empty();
    return RepositoryState<Object?>.data(value);
  }

  /// Notifies on the next microtask.
  ///
  /// A read can finish while the app is mid-build, and marking screens dirty
  /// from there throws. Deferring by a microtask lands the rebuild before the
  /// next frame, which is where the app already expects it.
  void _notify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
      final forward = onChanged;
      if (forward == null) return;
      _propagating = true;
      try {
        forward();
      } finally {
        _propagating = false;
      }
    });
  }
}
