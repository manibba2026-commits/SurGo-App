import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../auth/auth_repository.dart';
import '../auth/demo_auth.dart';
import '../auth/mock_auth_repository.dart';
import '../data/models.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../data/verification_policy.dart';
import '../repositories/backend.dart' show mapBackendError;
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_mappers.dart';
import '../repositories/repository_registry.dart';
import '../repositories/ride_location_repository.dart';
import '../repositories/verification_repository.dart';
import '../services/fee_calculator.dart';
import '../services/geoapify_service.dart';
import '../services/location_publisher.dart';
import '../services/location_service.dart';
import '../services/money.dart';
import '../services/notification_session.dart';
import '../services/passenger_ride_session.dart';
import '../services/ride_pricing.dart';
import 'domain_cache.dart';
import 'geo.dart';
import 'pasuyo_status.dart';
import 'rental_availability.dart';
import 'rental_status.dart';
import 'ride_chat.dart';
import 'ride_match.dart';
import 'ride_status.dart';

/// The three ways a person can use SurGo.
///
/// [earner] is not named `rider` because the role covers errand and delivery
/// work as well as passenger rides - see `EarnerCapability`.
enum UserMode { passenger, earner, vehicleOwner }

/// Why [AppState.submitVerification] refused, or null-equivalent confirmation
/// that the application moved into review.
enum VerificationSubmitResult {
  ok,

  /// No application with that id belongs to the signed-in account.
  notFound,

  /// Not every required document has been uploaded yet.
  incomplete,

  /// The account cannot apply for this capability.
  notEligible,

  /// The application is already submitted or under review.
  alreadyInReview;

  String get message => switch (this) {
    VerificationSubmitResult.ok =>
      'Submitted — the demo auto-approves after a few seconds.',
    VerificationSubmitResult.notFound => 'That application no longer exists.',
    VerificationSubmitResult.incomplete =>
      'Upload every required document before submitting.',
    VerificationSubmitResult.notEligible =>
      'You are not eligible to apply for this yet.',
    VerificationSubmitResult.alreadyInReview =>
      'This application is already under review.',
  };
}

/// Outcome of submitting a verification application for a hosted account.
///
/// Kept separate from [VerificationSubmitResult] because a hosted failure
/// carries the backend's own explanation, which the demo flow has no source
/// for.
class HostedVerificationResult {
  const HostedVerificationResult._(this.application, this.error);

  const HostedVerificationResult.submitted(VerificationApplicationRecord record)
    : this._(record, null);

  const HostedVerificationResult.failed(String message) : this._(null, message);

  final VerificationApplicationRecord? application;
  final String? error;

  bool get ok => application != null;
}

/// First element matching [test], or null.
///
/// Written out rather than pulled from `package:collection`, which is not a
/// declared dependency of this package.
T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// Why [AppState.acceptPasuyoTask] turned an errand down, or null when it was
/// claimed.
enum PasuyoAcceptRefusal {
  /// Someone else already claimed it, or it was cancelled/completed.
  notOpen,

  /// This helper already has an errand in progress. Accepting a second one
  /// would overwrite the active errand and strand the first one, which the
  /// helper could then no longer reach or progress.
  alreadyHasTask,

  /// The errand belongs to the same account trying to accept it.
  ownCustomer;

  /// What the helper is told when [AppState.acceptPasuyoTask] refuses. Each
  /// refusal needs different advice, and a rejected tap with no explanation
  /// reads as a broken button rather than a rule.
  String get label => switch (this) {
    PasuyoAcceptRefusal.notOpen => 'Someone already claimed this errand.',
    PasuyoAcceptRefusal.alreadyHasTask =>
      'Finish your current errand before taking another.',
    PasuyoAcceptRefusal.ownCustomer =>
      'You posted this errand, so you cannot be the helper for it.',
  };
}

/// Everything here lives only in memory for the lifetime of the app run.
/// There is no backend, no local storage, no network — purely a UI
/// simulation of what SurGo would look and feel like. Seed data is loaded
/// once from the manifest-driven files under `assets/db/` via [DbService], and
/// every "write" (accepting a ride, adding a saved place, topping up a
/// wallet, etc.) just mutates these in-memory lists and calls
/// notifyListeners().
class AppState extends ChangeNotifier {
  AppState._internal() {
    bookingRouting.addListener(notifyListeners);
    rideRouting.addListener(notifyListeners);
  }
  static final AppState instance = AppState._internal();

  final RideRouting bookingRouting = RideRouting();
  final RideRouting rideRouting = RideRouting();

  final DbService db = DbService.instance;

  /// The data layer screens read once a domain is migrated. It defaults to the
  /// seeded set so tests and offline demos behave exactly as before; `main`
  /// installs the Supabase set for a `SURGO_DATA_SOURCE=supabase` build.
  RepositoryRegistry repositories = RepositoryRegistry.mock();

  /// Installs the data layer. Safe to call before [init]; nothing reads it
  /// until a screen is wired to a repository.
  void configureRepositories(RepositoryRegistry registry) {
    final monitored = _notifications != null;
    _stopNotifications();
    _passengerRides?.stop();
    _passengerRides = null;
    _passengerRideGeneration++;
    _creatingHostedRide = null;
    repositories = registry;
    if (monitored) _cache?.restart();
    _startNotifications();
  }

  NotificationSession? _notifications;

  void _stopNotifications() {
    _notifications?.stop();
    _notifications = null;
  }

  void _startNotifications() {
    final profileId = identity?.userId;
    if (!ready ||
        !isSignedIn ||
        !usesHostedRideDispatch ||
        profileId == null ||
        _notifications != null) {
      return;
    }
    final session = NotificationSession(
      cache: cache,
      profileId: profileId,
      realtime: repositories.realtime,
    );
    _notifications = session;
    session.start();
    unawaited(session.refresh());
  }

  DemoRideRequestStore? demoRideStore;
  PassengerRideSession? _passengerRides;
  int _passengerRideGeneration = 0;
  bool _restoringPassengerRide = false;
  String? _persistedDemoRide;
  RepositoryFailure? passengerRideFailure;
  bool passengerRideLoading = false;
  Future<RideRequestItem>? _creatingHostedRide;

  Future<void> restorePassengerRide() async {
    final generation = ++_passengerRideGeneration;
    _passengerRides?.stop();
    _passengerRides = null;
    _restoringPassengerRide = true;
    passengerRideLoading = true;
    passengerRideFailure = null;
    try {
      if (usesHostedRideDispatch) {
        final profileId = identity?.userId;
        if (profileId == null) return;
        final session = PassengerRideSession(
          rides: repositories.rides,
          realtime: repositories.realtime,
          profileId: profileId,
          onChanged: (record, failure) {
            if (generation != _passengerRideGeneration) return;
            passengerRideFailure = failure;
            if (failure == null) {
              if (record != null) {
                applyHostedRideUpdate(record);
              } else if (liveRideRequest != null) {
                final requestId = myRideRequest?.id;
                myRideRequest = null;
                rideProposal = null;
                if (activeRide?.id == requestId) {
                  activeRide = null;
                  activeRideBreakdown = null;
                }
              }
            }
            notifyListeners();
          },
        );
        _passengerRides = session;
        session.start();
        await session.refresh();
      } else if (demoRideStore != null) {
        final profileId = cache.profileKeyFor(ActorRole.passenger);
        final request = await demoRideStore!.read(profileId);
        if (generation != _passengerRideGeneration) return;
        myRideRequest = request;
        rideProposal = null;
        activeRide = request != null && request.status.isCommitted
            ? request
            : null;
        activeRideBreakdown = activeRide == null
            ? null
            : RidePricing.breakdown(priceFor(activeRide!));
        if (request != null) {
          db.rideRequests.removeWhere((ride) => ride.id == request.id);
          db.rideRequests.insert(0, request);
          syncRideRoute(request);
        }
        _persistedDemoRide = null;
      }
    } catch (error) {
      if (generation == _passengerRideGeneration) {
        passengerRideFailure = mapBackendError(error);
      }
    } finally {
      if (generation == _passengerRideGeneration) {
        _restoringPassengerRide = false;
        passengerRideLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshPassengerRide() async {
    if (!usesHostedRideDispatch || identity == null) return;
    if (_passengerRides == null) {
      await restorePassengerRide();
      return;
    }
    final generation = _passengerRideGeneration;
    passengerRideLoading = true;
    notifyListeners();
    try {
      await _passengerRides!.refresh();
    } finally {
      if (generation == _passengerRideGeneration) {
        passengerRideLoading = false;
        notifyListeners();
      }
    }
  }

  void _persistDemoRide() {
    if (!ready ||
        usesHostedRideDispatch ||
        _restoringPassengerRide ||
        demoRideStore == null ||
        !isSignedIn) {
      return;
    }
    final profileId = cache.profileKeyFor(ActorRole.passenger);
    final request = liveRideRequest;
    final fingerprint =
        '$profileId:${request?.id}:${request?.status.wireValue}:${request?.riderId}';
    if (_persistedDemoRide == fingerprint) return;
    _persistedDemoRide = fingerprint;
    unawaited(
      demoRideStore!.write(profileId, request).catchError((Object error) {
        _persistedDemoRide = null;
        passengerRideFailure = RepositoryFailure.unavailable();
      }),
    );
  }

  DomainCache? _cache;

  /// The repository reads screens take through `RepositoryView`.
  ///
  /// Both the registry and the profile key are read lazily, so a build that
  /// installs Supabase after boot still ends up on its own data layer and a
  /// signed-out demo keeps showing the primary seeded person it always showed.
  /// The cache listens for app writes so a mock snapshot cannot go stale, and
  /// forwards finished reads back here so existing listeners rebuild.
  DomainCache get cache {
    final installed = _cache;
    if (installed != null) return installed;
    final created = DomainCache(
      registry: () => repositories,
      // A seeded build keys its people by demo account id; a Supabase build has
      // to use the auth uuid, because that is what `profiles.id` is there.
      profileKey: () => repositories.isSupabaseBacked
          ? identity?.userId ??
                currentAccount?.id ??
                DbService.primaryPassengerId
          : currentAccount?.id ?? DbService.primaryPassengerId,
      // The seed keeps one profile row per role, so a read for a role is keyed
      // by that row rather than by the demo account that unlocks it.
      seedProfileKey: (role) => switch (role) {
        ActorRole.passenger => db.passenger.id,
        ActorRole.earner => db.earner.id,
        ActorRole.vehicleOwner => db.vehicleOwner.id,
        ActorRole.signedInUser =>
          currentAccount?.id ?? DbService.primaryPassengerId,
      },
    )..onChanged = notifyListeners;
    addListener(created.onAppDataChanged);
    return _cache = created;
  }

  // ---- live position sharing ----

  /// The fixes this device published in a seeded build.
  ///
  /// A hosted build writes through the publishing function instead and never
  /// touches this, so the prototype map still has a rider that moves while the
  /// production path stays honest about having no local trail to show.
  final InMemoryLocationSink seedLocations = InMemoryLocationSink();

  LocationPublisher? _locationPublisher;

  /// Shares this device's position while the signed-in account is a rider
  /// committed to a trip, and stops the moment it is not.
  ///
  /// It is driven from [notifyListeners] rather than from a screen, because
  /// whether sharing is allowed depends on state the whole app holds — online
  /// toggle, which trip is active, which role is signed in — and a rider who
  /// navigates away from the trip must not keep broadcasting.
  LocationPublisher get locationPublisher {
    final created = _locationPublisher;
    if (created != null) return created;
    return _locationPublisher = LocationPublisher(
      sink: () =>
          repositories.isSupabaseBacked ? EdgeLocationSink() : seedLocations,
    );
  }

  bool _syncingLocation = false;

  @override
  void notifyListeners() {
    // The publisher is asked on the way out, and a screen that reacts to it can
    // write app state back, which would otherwise re-enter this method.
    if (!_syncingLocation) {
      _syncingLocation = true;
      try {
        _syncLocationPublisher();
      } finally {
        _syncingLocation = false;
      }
    }
    _persistDemoRide();
    super.notifyListeners();
  }

  void _syncLocationPublisher() {
    // The earner row only exists once the seed is loaded, and no trip can be
    // committed before then, so there is nothing to decide until the app is up.
    if (!ready) return;
    final request = activeRide;
    locationPublisher.sync(
      online: riderOnline,
      rideId: request?.id,
      riderId: request?.riderId,
      // The same key the screens read profiles by, so the publisher and the
      // trip can never disagree about who is riding.
      signedInProfileId: cache.profileKeyFor(ActorRole.earner),
      status: request?.status,
    );
  }

  bool ready = false;

  Future<void>? _initFuture;

  /// Loads the seed once, then restores whatever Supabase session the provider
  /// persisted. Callers may init concurrently; they all await one load.
  Future<void> init() => _initFuture ??= _load();

  Future<void> _load() async {
    if (ready) return;
    await db.load();
    PlatformLedger.instance.seedFromHistory(
      // A seeded trip is the fare its rider kept; the platform fee is priced
      // from the distance that trip was seeded with, so history and live
      // settlements are measured the same way.
      completedRides: [
        for (final t in db.riderTrips.where(
          (t) => t.status == 'Completed' && t.fare > 0,
        ))
          (
            fare: t.fare,
            platformFee: RidePricing.platformFee(
              TripDistance.seeded(t.distanceKm),
            ),
          ),
      ],
      completedRentalTotals: db.rentalHistory
          .where((r) => r.status == 'Completed' || r.status == 'Active')
          .map((r) => r.totalFare)
          .toList(),
      // SurGo takes commission on delivered errands too, so they belong in the
      // platform revenue figures alongside rides and rentals.
      completedPasuyoBudgets: db.pasuyoTasks
          .where((t) => t.status == PasuyoStatus.delivered)
          .map((t) => t.budget)
          .toList(),
    );
    // A seeded build reads from memory, so its migrated screens can hold their
    // repository answers before the first frame. A Supabase build leaves this
    // alone and each screen shows its own loading state instead.
    await cache.prefill();
    ready = true;
    authStatus = AuthStatus.restoring;
    notifyListeners();

    final provider = _auth;
    final revision = _authSessionRevision;
    try {
      final user = await provider.restoreSession();
      if (!identical(provider, _auth) || revision != _authSessionRevision) {
        return;
      }
      if (user == null) {
        authStatus = AuthStatus.signedOut;
        notifyListeners();
      } else {
        // A restored session starts locked: the device PIN replaces the OTP on
        // every relaunch, for the demo and a hosted Supabase session alike.
        if (devicePinEnabled) _pinRequired = true;
        await _applyAuthUser(user);
      }
    } on AuthFailure catch (failure) {
      if (!identical(provider, _auth) || revision != _authSessionRevision) {
        return;
      }
      authStatus = AuthStatus.error;
      authError = failure;
      notifyListeners();
    } catch (error) {
      if (!identical(provider, _auth) || revision != _authSessionRevision) {
        return;
      }
      authStatus = AuthStatus.error;
      authError = AuthFailure.from(error);
      notifyListeners();
    }
  }

  // ---- authentication ----

  /// The provider in use. Production installs [SupabaseAuthRepository] from
  /// `main`; tests and previews keep the in-memory implementation.
  AuthRepository _auth = MockAuthRepository();
  StreamSubscription<AuthUser?>? _authSubscription;
  StreamSubscription<bool>? _recoverySubscription;
  int _authProviderGeneration = 0;
  int _authSessionRevision = 0;
  bool passwordRecoveryRequired = false;
  int recoveryEpoch = 0;

  EmailRecoveryRepository? get emailRecovery {
    final provider = _auth;
    return provider is EmailRecoveryRepository
        ? provider as EmailRecoveryRepository
        : null;
  }

  Future<void> completePasswordRecovery({
    required EmailRecoveryRepository repository,
    required int epoch,
    required String? userId,
  }) async {
    final revision = _authSessionRevision;
    bool valid() =>
        passwordRecoveryRequired &&
        identical(repository, emailRecovery) &&
        recoveryEpoch == epoch &&
        isSignedIn &&
        userId != null &&
        identity?.userId == userId &&
        _authSessionRevision == revision;
    if (!valid()) {
      throw const AuthFailure(
        AuthFailureCode.invalidCredentials,
        'Your recovery session changed. Open a new reset link.',
      );
    }
    final user = await _auth.restoreSession();
    if (!valid() || user?.id != userId) {
      throw const AuthFailure(
        AuthFailureCode.invalidCredentials,
        'Your recovery session expired. Open a new reset link.',
      );
    }
    passwordRecoveryRequired = false;
    _pinRequired = devicePinEnabled && !isDemoAccount;
    notifyListeners();
  }

  /// In-flight identity loads. It is created on first use and cleared once it
  /// drains so every chain starts in its caller's zone.
  Future<void>? _identityQueue;

  AuthStatus authStatus = AuthStatus.uninitialized;
  AuthFailure? authError;

  /// The profile and approved roles Supabase returned for the session.
  SurgoIdentity? identity;

  bool get isMockAuth => _auth.isMock;
  bool get authAvailable => _auth.isAvailable;

  /// Installs the identity provider and starts listening for session changes.
  /// Safe to call before [init]; events wait for the seed to load.
  void configureAuth(AuthRepository repository) {
    final monitored = _notifications != null;
    _stopNotifications();
    if (monitored) _cache?.restart();
    _authSubscription?.cancel();
    _recoverySubscription?.cancel();
    final generation = ++_authProviderGeneration;
    _authSessionRevision++;
    _auth = repository;
    _pinRequired = false;
    passwordRecoveryRequired = false;
    recoveryEpoch++;
    final recovery = emailRecovery;
    _recoverySubscription = recovery?.passwordRecoveryEvents.listen(
      (required) {
        if (generation != _authProviderGeneration) return;
        passwordRecoveryRequired = required;
        recoveryEpoch++;
        notifyListeners();
      },
      onError: (Object error) {
        if (generation != _authProviderGeneration) return;
        authError = AuthFailure.from(error);
        notifyListeners();
      },
    );
    _authSubscription = repository.authStateChanges.listen(
      (user) => unawaited(_handleAuthEvent(user, generation)),
      onError: (Object error) {
        if (generation != _authProviderGeneration) return;
        authError = AuthFailure.from(error);
        authStatus = AuthStatus.error;
        notifyListeners();
      },
    );
  }

  Future<void> _handleAuthEvent(AuthUser? user, int generation) async {
    final revision = _authSessionRevision;
    if (!ready) await init();
    if (generation != _authProviderGeneration ||
        revision != _authSessionRevision) {
      return;
    }
    // Trust the provider's current session rather than the event payload: an
    // initialSession emitted before a failed refresh must not resurrect a
    // revoked session. restoreSession() validates (and refreshes) it first.
    final current = user == null ? null : await _auth.restoreSession();
    if (generation != _authProviderGeneration ||
        revision != _authSessionRevision) {
      return;
    }
    if (current == null) {
      if (currentAccount != null || identity != null) {
        _clearSession();
      } else {
        authStatus = AuthStatus.signedOut;
        notifyListeners();
      }
      return;
    }
    // A new account passes the device PIN before the dashboard. The flag is
    // set before the identity lands so a screen listening for isSignedIn
    // already sees requiresPin. The same account refreshing its token keeps
    // the unlock it already earned instead of being relocked. A demo identity
    // never gets the device lock: its PIN was just verified by the server.
    final isDemo = current.isDemoAccount;
    if (devicePinEnabled && !isDemo && identity?.userId != current.id) {
      _pinRequired = true;
    }
    await _applyAuthUser(current);
  }

  /// Serially applies identity loads. The auth listener and the explicit
  /// restore after verification can both fire for the same sign-in; queuing
  /// keeps the newest identity from being overwritten by an older load.
  Future<void> _applyAuthUser(AuthUser user) {
    final provider = _auth;
    final revision = _authSessionRevision;
    final next = (_identityQueue ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => _applyAuthUserNow(user, provider, revision));
    late final Future<void> tracked;
    tracked = next.whenComplete(() {
      if (identical(_identityQueue, tracked)) _identityQueue = null;
    });
    _identityQueue = tracked;
    return tracked;
  }

  Future<void> _applyAuthUserNow(
    AuthUser user,
    AuthRepository provider,
    int revision,
  ) async {
    bool valid() =>
        identical(provider, _auth) && revision == _authSessionRevision;
    if (!valid()) return;
    try {
      final loaded = await provider.loadIdentity(user);
      if (!valid()) return;
      final unchanged =
          currentAccount != null &&
          identity?.userId == loaded.userId &&
          identity?.phone == loaded.phone &&
          identity?.email == loaded.email &&
          identity?.needsOnboarding == loaded.needsOnboarding &&
          setEquals(identity!.providers, loaded.providers) &&
          // An admin approval changes roles without touching the session, so
          // the reload must not be short-circuited on contact fields alone.
          setEquals(identity!.capabilities, loaded.capabilities);
      if (unchanged) {
        authStatus = AuthStatus.signedIn;
        _startNotifications();
        return;
      }

      _stopNotifications();
      _restoringPassengerRide = true;
      if (identity?.userId != loaded.userId) {
        if (passwordRecoveryRequired) recoveryEpoch++;
        _rentalApprovalTimer?.cancel();
        _rentalApprovalTimer = null;
        activeRentalBooking = null;
        _rentalBookings.clear();
        lastRentalBreakdown = null;
        myRideRequest = null;
        rideProposal = null;
        activeRide = null;
        activeRideBreakdown = null;
        lastCompletedRide = null;
        lastCompletedRideDriver = null;
        lastRideBreakdown = null;
        rideReceiptPending = false;
      }
      identity = loaded;
      // A demo identity signed in with its server-verified PIN, so any lock
      // carried in from a restored session is released here.
      if (loaded.isDemoAccount) _pinRequired = false;
      final account = _syncLocalAccount(loaded);
      currentAccount = account;
      if (_auth.isMock) {
        // A demo session may keep the seeded business data; it is the point of
        // the offline presentation build.
        db.endIsolatedSession();
      } else {
        // A hosted account never inherits another person's seed rows.
        db.beginIsolatedSession(account.id);
      }
      db.activateAccount(account);
      // Whatever was cached belongs to the previous session's profile key.
      cache.restart();
      mode = _preferredModeFor(account);
      authStatus = AuthStatus.signedIn;
      authError = null;
      _startNotifications();
      await restorePassengerRide();
      if (valid()) notifyListeners();
    } on AuthFailure catch (failure) {
      if (!valid()) return;
      _restoringPassengerRide = false;
      authStatus = AuthStatus.error;
      authError = failure;
      notifyListeners();
    } catch (error) {
      if (!valid()) return;
      _restoringPassengerRide = false;
      authStatus = AuthStatus.error;
      authError = AuthFailure.from(error);
      notifyListeners();
    }
  }

  /// Bridges the Supabase identity onto the demo record the business screens
  /// read. Roles come from Supabase; the profile, wallet and history stay in the
  /// local seed until the business tables are wired up.
  Account _syncLocalAccount(SurgoIdentity loaded) {
    final existing = db.findAccountForIdentity(
      authUserId: loaded.userId,
      phone: _auth.isMock ? loaded.phone : null,
      email: _auth.isMock ? loaded.email : null,
      // Demo identities are seeded locally, so the mock provider may resolve a
      // profile by contact. A hosted Supabase identity may only ever match the
      // same auth user id.
      allowContactMatch: _auth.isMock,
    );
    final base =
        existing ??
        db.registerAccount(
          name: loaded.displayName,
          phone: loaded.phone ?? '',
          email: loaded.email ?? '',
          authUserId: loaded.userId,
        ) ??
        Account(
          id: loaded.userId,
          name: loaded.displayName,
          phone: loaded.phone ?? '',
          email: loaded.email ?? '',
          authUserId: loaded.userId,
          approvedCapabilities: loaded.capabilities,
          eligibleCapabilities: loaded.eligibleCapabilities,
        );

    final synced = base.copyWith(
      name: loaded.displayName,
      // The seed owns the demo profile's contact rows; a newly linked identity
      // must not overwrite the seeded phone other tests and demo data rely on.
      phone: base.phone.isEmpty ? loaded.phone ?? '' : base.phone,
      email: base.email.isEmpty ? loaded.email ?? '' : base.email,
      authUserId: loaded.userId,
      approvedCapabilities: loaded.capabilities,
      eligibleCapabilities: loaded.eligibleCapabilities,
    );
    _replaceAccount(synced);
    return synced;
  }

  /// Asks the provider to send a code. Returns the failure to show, or null
  /// when the SMS is on its way.
  Future<AuthFailure?> sendPhoneOtp({
    required String phone,
    String? fullName,
    bool createUser = false,
  }) {
    return _performAuth(
      () => _auth.requestPhoneOtp(
        phone: phone,
        fullName: fullName,
        createUser: createUser,
      ),
    );
  }

  Future<AuthFailure?> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    // Every sign-in ends behind the PIN: an account without one creates it, a
    // returning account unlocks with its own. Set before the identity lands so
    // the navigation listener already sees requiresPin.
    _pinRequired = devicePinEnabled;
    final failure = await _performAuth(() async {
      final user = await _auth.verifyPhoneOtp(phone: phone, token: token);
      await _applyAuthUser(user);
    });
    if (failure != null) return failure;
    if (!devicePinEnabled) _pinRequired = false;
    return currentAccount == null
        ? authError ?? AuthFailure.from('Sign-in did not complete.')
        : null;
  }

  /// Signs in a fictional demo identity with its phone number and PIN. The PIN
  /// is verified on the server and exchanged for a real session, so this is the
  /// account's only credential and the device lock is not stacked on top.
  Future<AuthFailure?> signInWithDemoPin({
    required String phone,
    required String pin,
  }) async {
    _pinRequired = false;
    final failure = await _performAuth(() async {
      final user = await _auth.signInWithDemoPin(phone: phone, pin: pin);
      await _applyAuthUser(user);
    });
    if (failure != null) return failure;
    return currentAccount == null
        ? authError ?? AuthFailure.from('Sign-in did not complete.')
        : null;
  }

  Future<AuthFailure?> signInWithGoogle() async {
    return _signInWithOAuth(
      launch: _auth.signInWithGoogle,
      unavailableMessage: 'Google sign-in could not open. Try again.',
    );
  }

  Future<AuthFailure?> signInWithFacebook() async {
    return _signInWithOAuth(
      launch: _auth.signInWithFacebook,
      unavailableMessage: 'Facebook sign-in could not open. Try again.',
    );
  }

  Future<AuthFailure?> _signInWithOAuth({
    required Future<bool> Function() launch,
    required String unavailableMessage,
  }) async {
    _pinRequired = devicePinEnabled;
    final failure = await _performAuth(() async {
      final launched = await launch();
      if (!launched) {
        throw AuthFailure(
          AuthFailureCode.providerUnavailable,
          unavailableMessage,
        );
      }
      // The browser returns through the auth listener. Restoring here also
      // completes immediately for the in-memory provider used by tests.
      final user = await _auth.restoreSession();
      if (user != null) await _applyAuthUser(user);
    });
    if (!devicePinEnabled) _pinRequired = false;
    return failure;
  }

  /// Signs in with the email/password identity Supabase already holds. A new
  /// email account still passes through onboarding because it has no verified
  /// phone identity yet.
  Future<AuthFailure?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    _pinRequired = devicePinEnabled;
    final failure = await _performAuth(() async {
      final user = await _auth.signInWithEmail(
        email: email,
        password: password,
      );
      await _applyAuthUser(user);
    });
    if (!devicePinEnabled) _pinRequired = false;
    return failure;
  }

  /// Creates an email/password account. A null failure with no signed-in
  /// account means the project requires email confirmation first; the screen
  /// shows that instruction instead of treating it as an error.
  Future<AuthFailure?> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async {
    _pinRequired = devicePinEnabled;
    final failure = await _performAuth(() async {
      final user = await _auth.signUpWithEmail(
        email: email,
        password: password,
        fullName: fullName,
      );
      if (user != null) await _applyAuthUser(user);
    });
    if (!devicePinEnabled) _pinRequired = false;
    return failure;
  }

  Future<AuthFailure?> linkGoogleIdentity() {
    return _performAuth(() async {
      final launched = await _auth.linkGoogleIdentity();
      if (!launched) {
        throw const AuthFailure(
          AuthFailureCode.providerUnavailable,
          'Google linking could not open. Try again.',
        );
      }
      // Production completes through the auth listener; the in-memory provider
      // links synchronously, so reload here to keep its result observable.
      if (_auth.isMock) {
        final user = await _auth.restoreSession();
        if (user == null) {
          throw const AuthFailure(
            AuthFailureCode.unknown,
            'Google linking did not complete.',
          );
        }
        await _applyAuthUser(user);
      }
    });
  }

  Future<AuthFailure?> requestPhoneLink(String phone) {
    return _performAuth(() => _auth.requestPhoneLink(phone));
  }

  Future<AuthFailure?> verifyPhoneLink({
    required String phone,
    required String token,
  }) {
    return _performAuth(() async {
      await _auth.verifyPhoneLink(phone: phone, token: token);
      final user = await _auth.restoreSession();
      if (user != null) await _applyAuthUser(user);
    });
  }

  Future<AuthFailure?> _performAuth(Future<void> Function() action) async {
    authError = null;
    try {
      await action();
      return null;
    } on AuthFailure catch (failure) {
      authError = failure;
      return failure;
    } catch (error) {
      final failure = AuthFailure.from(error);
      authError = failure;
      return failure;
    }
  }

  // ---- session and account mode ----

  /// The demo account signed in this run, or null while signed out. The Supabase
  /// session itself is persisted by the provider; this cache is in memory.
  Account? currentAccount;

  bool get isSignedIn => currentAccount != null;

  /// True when the presentation build opted into the local demo provider.
  bool get demoAuthEnabled => DemoAuthConfig.enabled && _auth.isMock;

  /// The device PIN guards a session in the offline demo and in a hosted
  /// Supabase build alike. Plain mock tests (no demo flag) keep no PIN, a
  /// provider that could not initialize has nothing to lock, and a provisioned
  /// demo identity already authenticated with its own PIN.
  bool get devicePinEnabled =>
      _auth.isAvailable && (demoAuthEnabled || !_auth.isMock);

  /// True when the hosted provider is installed, so the `demo-login` function
  /// can be reached. The offline presentation build keeps using its seeded
  /// account numbers, fixed OTP and device PIN instead.
  bool get demoPinLoginAvailable => _auth.isAvailable && !_auth.isMock;

  /// The PIN is device-level, like a phone's lock screen.
  final DemoPinStore pinStore = DemoPinStore();

  bool _pinRequired = false;

  /// A restored session must be unlocked before the dashboard is shown.
  bool get requiresPin =>
      devicePinEnabled && isSignedIn && _pinRequired && !isDemoAccount;

  /// Whether the signed-in account is one of the provisioned fictional demo
  /// identities. Its PIN is the sign-in credential itself, so the app offers
  /// neither a second device lock nor a PIN-management tile for it.
  bool get isDemoAccount => identity?.isDemoAccount ?? false;

  /// The device-local key the signed-in account's PIN is stored under.
  ///
  /// A demo account keeps its stable seed id. A hosted account is keyed by the
  /// Supabase auth uuid: the local ACC id is regenerated each launch, so keying
  /// by it would lose the PIN on the next browser restart.
  String? get _pinAccountKey {
    if (!devicePinEnabled) return null;
    return demoAuthEnabled ? currentAccount?.id : identity?.userId;
  }

  /// A hosted Google account that has not completed registration yet. Demo
  /// accounts are seeded and never pass through onboarding.
  bool get requiresOnboarding =>
      isSignedIn && !_auth.isMock && (identity?.needsOnboarding ?? false);

  /// True for a real Supabase session. Screens use this to avoid presenting
  /// seeded business rows as if they belonged to the signed-in account.
  bool get usesHostedIdentity => !_auth.isMock;

  /// True only when the signed-in account and the data layer can both perform
  /// hosted dispatch. A hosted session on the seeded repositories keeps using
  /// the local ride flow: the auth provider says who is signed in, not where
  /// business rows are written.
  bool get usesHostedRideDispatch =>
      usesHostedIdentity && repositories.isSupabaseBacked;

  /// Persists the first-run details and reloads the identity. Returns the
  /// failure to show, or null when the account is ready for its dashboard.
  Future<AuthFailure?> completeOnboarding({
    required String fullName,
    required String phone,
  }) async {
    final failure = await _performAuth(() async {
      await _auth.completeOnboarding(fullName: fullName, phone: phone);
      final user = await _auth.restoreSession();
      if (user == null) {
        throw const AuthFailure(
          AuthFailureCode.unknown,
          'Your account could not be reloaded. Sign in again.',
        );
      }
      await _applyAuthUser(user);
    });
    if (failure == null && requiresOnboarding) {
      return const AuthFailure(
        AuthFailureCode.unknown,
        'Your account details did not save. Please try again.',
      );
    }
    return failure;
  }

  /// The four prepared identities, in presentation order. Only the account ids
  /// are hardcoded; names, phones and roles come from the existing seed rows.
  List<Account> get demoLoginAccounts {
    if (!demoAuthEnabled) return const [];
    final byId = {for (final account in db.accounts) account.id: account};
    return [
      for (final ref in demoAccountRefs)
        if (byId[ref.accountNumber] != null) byId[ref.accountNumber]!,
    ];
  }

  /// Resolves an account number (`ACC003`) or a registered phone number.
  Account? demoAccountFor(String identifier) {
    final auth = _auth;
    return auth is MockAuthRepository
        ? auth.accountForIdentifier(identifier)
        : null;
  }

  /// Whether the signed-in account already has a PIN on this device.
  ///
  /// False for a new account (or one whose PIN was forgotten), which is what
  /// makes the PIN screen open in creation mode instead of asking for a code
  /// nobody ever chose.
  Future<bool> pinConfiguredForCurrentAccount() async {
    final key = _pinAccountKey;
    if (key == null) return false;
    return pinStore.hasPin(key);
  }

  /// Saves the first PIN for the signed-in account.
  Future<bool> setPin(String pin) async {
    final key = _pinAccountKey;
    if (key == null || !isDemoPin(pin)) return false;
    await pinStore.setPin(key, pin);
    return true;
  }

  /// Verifies the PIN of the account currently signed in, then releases the
  /// session. A PIN belonging to a different account never unlocks this one.
  Future<PinUnlockResult> unlockWithPin(String pin) async {
    if (!devicePinEnabled) return PinUnlockResult.success;
    final key = _pinAccountKey;
    if (key == null) return PinUnlockResult.incorrect;
    if (!await pinStore.verify(key, pin)) {
      return PinUnlockResult.incorrect;
    }
    _pinRequired = false;
    notifyListeners();
    return PinUnlockResult.success;
  }

  Future<PinChangeResult> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    final key = _pinAccountKey;
    if (key == null) return PinChangeResult.invalidNew;
    if (!isDemoPin(newPin)) return PinChangeResult.invalidNew;
    if (currentPin == newPin) return PinChangeResult.sameAsCurrent;
    if (!await pinStore.verify(key, currentPin)) {
      return PinChangeResult.incorrectCurrent;
    }
    await pinStore.setPin(key, newPin);
    return PinChangeResult.success;
  }

  /// Forgot PIN returns to authentication. Only this account's PIN is removed,
  /// so signing back in asks for a new one without touching another identity's
  /// lock on the same device.
  Future<void> forgotPin() async {
    final key = _pinAccountKey;
    _pinRequired = false;
    if (key != null) await pinStore.reset(key);
    await logout();
  }

  UserMode mode = UserMode.passenger;

  /// The demo identities land on their prepared dashboard; a multi-role account
  /// keeps the existing first-mode behaviour. Normal Supabase sign-in is
  /// untouched because this only runs with the demo provider installed.
  UserMode _preferredModeFor(Account account) {
    final fallback = availableModes.isEmpty
        ? UserMode.passenger
        : availableModes.first;
    if (!demoAuthEnabled) return fallback;
    final preferred = switch (demoAccountRefFor(account.id)?.role) {
      DemoRole.rider || DemoRole.helper => UserMode.earner,
      DemoRole.vehicleOwner => UserMode.vehicleOwner,
      _ => UserMode.passenger,
    };
    return availableModes.contains(preferred) ? preferred : fallback;
  }

  /// The modes the signed-in account can act as, in a stable order. A mode is
  /// unlocked only by an *approved* capability, not an eligible one: approving
  /// `rider` or `earner` opens the Earner shell, approving `passenger` opens
  /// the Passenger shell, approving `vehicleOwner` opens the Owner shell.
  /// Signed out or unknown accounts keep all three so the demo can still be
  /// explored. A suspended account has none.
  List<UserMode> get availableModes {
    final account = currentAccount;
    if (account == null) return UserMode.values;
    final caps = account.usableCapabilities;
    return [
      if (caps.contains(CapabilityType.passenger)) UserMode.passenger,
      if (caps.contains(CapabilityType.rider) ||
          caps.contains(CapabilityType.earner))
        UserMode.earner,
      if (caps.contains(CapabilityType.vehicleOwner)) UserMode.vehicleOwner,
    ];
  }

  /// Whether the signed-in account, if any, is approved for [capability].
  bool authorizedFor(CapabilityType capability) =>
      currentAccount?.authorizedFor(capability) ?? false;

  /// Whether the signed-in account, if any, may apply for [capability].
  bool canApplyFor(CapabilityType capability) =>
      currentAccount?.canApplyFor(capability) ?? false;

  /// Ends the provider session, then clears the local session cache.
  ///
  /// The local clear runs even when the provider call fails, so a network error
  /// cannot leave the app looking signed in.
  Future<void> logout() async {
    try {
      await _auth.signOut();
    } catch (_) {
      // The local clear below is the part the UI depends on.
    } finally {
      _clearSession();
    }
  }

  void _clearSession() {
    _stopNotifications();
    _rentalApprovalTimer?.cancel();
    _rentalApprovalTimer = null;
    activeRentalBooking = null;
    _rentalBookings.clear();
    lastRentalBreakdown = null;
    _authSessionRevision++;
    passwordRecoveryRequired = false;
    recoveryEpoch++;
    _passengerRideGeneration++;
    _creatingHostedRide = null;
    passengerRideLoading = false;
    _passengerRides?.stop();
    _passengerRides = null;
    _restoringPassengerRide = false;
    _persistedDemoRide = null;
    myRideRequest = null;
    rideProposal = null;
    activeRide = null;
    activeRideBreakdown = null;
    lastCompletedRide = null;
    lastCompletedRideDriver = null;
    lastRideBreakdown = null;
    rideReceiptPending = false;
    passengerRideFailure = null;
    currentAccount = null;
    identity = null;
    _pinRequired = false;
    _pickedPickup = null;
    _pickedDestination = null;
    bookingRouting.sync(start: null, end: null, enabled: false);
    rideRouting.sync(start: null, end: null, enabled: false);
    // The hosted session's empty slices must not survive into the signed-out
    // demo, and the seed must not survive into the next hosted session.
    db.endIsolatedSession();
    db.activatePrimary();
    // Nothing cached under the old key may survive into the signed-out demo.
    cache.restart();
    mode = UserMode.passenger;
    authStatus = AuthStatus.signedOut;
    notifyListeners();
  }

  void switchToEarner() => switchToMode(UserMode.earner);

  void switchToPassenger() => switchToMode(UserMode.passenger);

  void switchToVehicleOwner() => switchToMode(UserMode.vehicleOwner);

  /// Central switcher used by the mode dropdown. Refuses a mode the signed-in
  /// account cannot act as, rather than dropping the user into an empty shell.
  void switchToMode(UserMode m) {
    if (!availableModes.contains(m)) return;
    mode = m;
    notifyListeners();
  }

  /// The dashboard route for the current [mode], so sign-in and registration
  /// land a passenger, rider or owner on their own shell.
  String get homeRoute => switch (mode) {
    UserMode.passenger => '/home',
    UserMode.earner => '/earner',
    UserMode.vehicleOwner => '/owner',
  };

  // ---- verification & document requirements ----

  /// Every verification application in this run, seed and new alike.
  List<VerificationApplication> get verificationApplications =>
      db.verificationApplications;

  /// The applications belonging to the signed-in account, if any.
  List<VerificationApplication> get myVerifications {
    final account = currentAccount;
    if (account == null) return const [];
    return db.verificationApplications
        .where((a) => a.accountId == account.id)
        .toList();
  }

  /// The signed-in account's application for [capability], or null.
  ///
  /// Also advances any due simulated review steps, so reading a status can
  /// observe the auto-approval without the UI needing its own timer.
  VerificationApplication? verificationFor(CapabilityType capability) {
    final account = currentAccount;
    if (account == null) return null;
    processDueVerifications();
    return _applicationFor(account.id, capability);
  }

  /// How far the signed-in account is for [capability]: null means they have
  /// neither applied nor been approved.
  VerificationStatus? verificationStatusFor(CapabilityType capability) {
    final account = currentAccount;
    if (account == null) return null;
    final app = verificationFor(capability);
    if (app != null) return app.status;
    return account.authorizedFor(capability)
        ? VerificationStatus.approved
        : null;
  }

  /// One-line summary for the profile tiles: how many capabilities still need
  /// documents, or which state the account is in.
  String get verificationSummaryLabel {
    final account = currentAccount;
    if (account == null) return 'Not signed in';
    if (!account.isActive) return 'Suspended';
    final open = account.eligibleCapabilities
        .where((c) => c != CapabilityType.passenger)
        .toList();
    if (open.isEmpty) return 'Fully verified';
    final inFlight = myVerifications.any(
      (a) =>
          a.status == VerificationStatus.draft ||
          a.status == VerificationStatus.submitted ||
          a.status == VerificationStatus.underReview,
    );
    if (inFlight) return 'In progress';
    return '${open.length} ${open.length == 1 ? 'step' : 'steps'} to go';
  }

  // ---- hosted verification ----
  //
  // A Supabase account's applications live in `verification_applications`,
  // which only the admin dashboard may decide. These methods read and submit
  // through the repositories; the demo's simulated review below never runs for
  // such an account.

  /// The signed-in hosted account's applications, newest first. Empty until
  /// the slot has been read, and empty for a demo account.
  List<VerificationApplicationRecord> get hostedVerificationApplications =>
      cache.dataOf<List<VerificationApplicationRecord>>(
        DomainSlot.verificationApplications,
      ) ??
      const [];

  /// True once the backend has answered for this account, including the empty
  /// answer; the screen uses it to tell "no application yet" from "loading".
  bool get hostedVerificationLoaded => cache
      .stateOf<List<VerificationApplicationRecord>>(
        DomainSlot.verificationApplications,
      )
      .isSettled;

  /// Makes sure the hosted application list has been read at least once.
  Future<void> ensureHostedVerification() async {
    if (!usesHostedIdentity || !isSignedIn) return;
    await cache.ensure(DomainSlot.verificationApplications);
  }

  /// Re-reads the profile, roles and applications.
  ///
  /// This is what makes an admin decision visible: the approval grants a role
  /// in the database, and only a fresh identity read turns it into an unlocked
  /// mode in the app.
  Future<void> refreshHostedVerification() async {
    if (!usesHostedIdentity || !isSignedIn) return;
    await refreshIdentity();
    await cache.ensure(DomainSlot.verificationApplications);
  }

  /// Reloads the session identity without signing out.
  Future<void> refreshIdentity() async {
    if (!usesHostedIdentity || !isSignedIn) return;
    final user = await _auth.restoreSession();
    if (user == null) return;
    await _applyAuthUser(user);
  }

  /// Uploads the picked files and submits one hosted verification application.
  Future<HostedVerificationResult> submitHostedVerification({
    required CapabilityType capability,
    required List<VerificationUpload> documents,
  }) async {
    if (!usesHostedIdentity) {
      return const HostedVerificationResult.failed(
        'Hosted verification is only available for a signed-in Supabase account.',
      );
    }
    final userId = identity?.userId;
    if (userId == null || !isSignedIn) {
      return const HostedVerificationResult.failed(
        'Sign in again before submitting verification.',
      );
    }
    try {
      final record = await repositories.verifications.submitApplication(
        profileId: userId,
        capability: verificationCapabilityToken(capability),
        documents: documents,
      );
      await cache.retry(DomainSlot.verificationApplications);
      await refreshIdentity();
      return HostedVerificationResult.submitted(record);
    } on RepositoryFailure catch (failure) {
      return HostedVerificationResult.failed(failure.message);
    } catch (_) {
      return const HostedVerificationResult.failed(
        'Verification could not be submitted. Please try again.',
      );
    }
  }

  /// Opens (or reopens) the signed-in account's application for [capability].
  ///
  /// Returns null when the account cannot apply: not signed in, not eligible,
  /// or already mid-flow. Reopening resets a rejected or needs-resubmission
  /// application back to draft so the checklist is editable again.
  VerificationApplication? startVerification(CapabilityType capability) {
    final account = currentAccount;
    if (account == null || !account.canApplyFor(capability)) return null;
    var app = _applicationFor(account.id, capability);
    if (app == null) {
      app = VerificationApplication(
        id: 'VAPP-${DateTime.now().microsecondsSinceEpoch}',
        accountId: account.id,
        capabilityType: capability,
        status: VerificationStatus.draft,
        documents: [
          for (final spec in VerificationPolicy.requirementsFor(capability))
            VerificationDocumentItem(
              id: spec.id,
              capabilityType: capability,
              label: spec.label,
              hint: spec.hint,
              required: spec.required,
            ),
        ],
      );
      db.verificationApplications.add(app);
    } else if (app.status == VerificationStatus.needsResubmission ||
        app.status == VerificationStatus.rejected) {
      app.status = VerificationStatus.draft;
      app.reviewerNote = null;
    }
    notifyListeners();
    return app;
  }

  /// Marks one document uploaded. Only works on a draft application that
  /// belongs to the signed-in account. Returns false when nothing changed —
  /// the document was already uploaded, is unknown, or the application is not
  /// a draft.
  bool markDocumentUploaded(String appId, String docId, {String? fileName}) {
    final account = currentAccount;
    if (account == null) return false;
    final app = _applicationForAccount(account, appId);
    if (app == null || app.status != VerificationStatus.draft) return false;
    for (final doc in app.documents) {
      if (doc.id == docId) {
        if (doc.uploaded) return false;
        doc.uploaded = true;
        doc.fileName = fileName ?? doc.label;
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  /// Submits a finished draft for the simulated review.
  VerificationSubmitResult submitVerification(String appId) {
    final account = currentAccount;
    if (account == null) return VerificationSubmitResult.notEligible;
    final app = _applicationForAccount(account, appId);
    if (app == null) return VerificationSubmitResult.notFound;
    if (!account.eligibleCapabilities.contains(app.capabilityType)) {
      return VerificationSubmitResult.notEligible;
    }
    if (app.status != VerificationStatus.draft) {
      return VerificationSubmitResult.alreadyInReview;
    }
    if (!app.isComplete) return VerificationSubmitResult.incomplete;
    app.status = VerificationStatus.submitted;
    app.submittedAt = DateTime.now();
    notifyListeners();
    return VerificationSubmitResult.ok;
  }

  /// Advances any reviews whose simulated window has elapsed: Submitted ->
  /// Under review -> Approved, which grants the capability.
  ///
  /// Runs on demand from the verification screen and when a status is read, so
  /// the demo needs no background timers. [at] lets tests drive the clock.
  void processDueVerifications({DateTime? at}) {
    final now = at ?? DateTime.now();
    var changed = false;
    for (final app in db.verificationApplications) {
      final submitted = app.submittedAt;
      if (submitted == null) continue;
      final elapsed = now.difference(submitted);
      if (app.status == VerificationStatus.submitted &&
          elapsed >= VerificationPolicy.submittedUnderReview) {
        app.status = VerificationStatus.underReview;
        app.reviewerNote = 'Documents received, checking credentials…';
        changed = true;
      } else if (app.status == VerificationStatus.underReview &&
          elapsed >= VerificationPolicy.underReviewApproval) {
        _approveApplication(app);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _approveApplication(VerificationApplication app) {
    Account? account;
    for (final a in db.accounts) {
      if (a.id == app.accountId) {
        account = a;
        break;
      }
    }
    if (account == null) return;
    app.status = VerificationStatus.approved;
    app.reviewedAt = DateTime.now();
    app.reviewerNote = 'Approved automatically in the local demo.';
    if (!account.authorizedFor(app.capabilityType)) {
      _grantCapability(account, app.capabilityType);
    }
  }

  /// Moves [capability] from the account's eligible set to its approved set.
  /// Account fields are held by immutable-styled instances, so the grant
  /// replaces the account in [DbService.accounts] and re-points the session.
  void _grantCapability(Account account, CapabilityType capability) {
    final approved = {...account.approvedCapabilities, capability};
    final eligible = {...account.eligibleCapabilities}..remove(capability);
    final updated = account.copyWith(
      approvedCapabilities: approved,
      eligibleCapabilities: eligible,
    );
    _replaceAccount(updated);
    if (currentAccount?.id == updated.id) {
      currentAccount = updated;
      db.activateAccount(updated);
    }
  }

  void _replaceAccount(Account updated) {
    db.accounts = [
      for (final a in db.accounts) a.id == updated.id ? updated : a,
    ];
  }

  VerificationApplication? _applicationFor(
    String accountId,
    CapabilityType capability,
  ) {
    for (final app in db.verificationApplications) {
      if (app.accountId == accountId && app.capabilityType == capability) {
        return app;
      }
    }
    return null;
  }

  VerificationApplication? _applicationForAccount(
    Account account,
    String appId,
  ) {
    for (final app in db.verificationApplications) {
      if (app.id == appId && app.accountId == account.id) return app;
    }
    return null;
  }

  // ---- booking draft ----
  String pickupLabel = 'Purok 3, Barangay Poblacion';
  String destinationLabel = 'SM Terminal, Downtown';
  MapPoint? _pickedPickup;
  MapPoint? _pickedDestination;
  RideOption get rideQuote => MockData.rideOptions.first;

  MapPoint? get bookingPickup => _pickedPickup ?? _coordinatesFor(pickupLabel);
  MapPoint? get bookingDestination =>
      _pickedDestination ?? _coordinatesFor(destinationLabel);

  void refreshBookingRoute({bool retry = false}) {
    bookingRouting.sync(
      start: bookingPickup,
      end: bookingDestination,
      enabled: usesHostedRideDispatch,
      retry: retry,
    );
  }

  void syncRideRoute(RideRequestItem request) {
    final start =
        request.pickupLatitude == null || request.pickupLongitude == null
        ? null
        : MapPoint(request.pickupLatitude!, request.pickupLongitude!);
    final end =
        request.dropoffLatitude == null || request.dropoffLongitude == null
        ? null
        : MapPoint(request.dropoffLatitude!, request.dropoffLongitude!);
    final matchesDraft =
        start?.latitude == bookingPickup?.latitude &&
        start?.longitude == bookingPickup?.longitude &&
        end?.latitude == bookingDestination?.latitude &&
        end?.longitude == bookingDestination?.longitude;
    rideRouting.sync(
      start: start,
      end: end,
      enabled: usesHostedRideDispatch,
      seed: matchesDraft ? bookingRouting.route : null,
    );
  }

  int get bookingTravelMinutes {
    final route = bookingRouting.route;
    if (route == null) return rideQuote.etaMinutes;
    final minutes = (route.durationSeconds / 60).ceil();
    return minutes < 1 ? 1 : minutes;
  }

  void setPickup(String label, {MapPoint? coordinates}) {
    pickupLabel = label;
    _pickedPickup = coordinates;
    refreshBookingRoute();
    notifyListeners();
  }

  void setDestination(String label, {MapPoint? coordinates}) {
    destinationLabel = label;
    _pickedDestination = coordinates;
    refreshBookingRoute();
    notifyListeners();
  }

  // ---- ride request lifecycle (passenger side) ----

  /// The request the passenger just created and is currently matching, or null.
  /// One at a time: a second request would have nowhere to be shown.
  RideRequestItem? myRideRequest;

  /// The rider currently proposed for [myRideRequest]. Non-null only while the
  /// passenger has a proposal to accept or decline.
  RideMatchProposal? rideProposal;

  /// Creates the request and starts looking for a rider.
  ///
  /// Returns the stored request so the matching screen can follow it. The
  /// request is inserted before any matching happens: an unpersisted request
  /// would mean a proposal the app cannot trace back to a trip.
  RideRequestItem createRideRequest({
    String? forPassenger,
    String? contactNumber,
    String? requestChannel,
  }) {
    final existing = liveRideRequest;
    if (existing != null) return existing;
    final option = rideQuote;
    final pickup = pickupLabel;
    final destination = destinationLabel;

    // Assisted booking: the account holder books on behalf of someone who
    // cannot use the app, so the request carries that person's name while the
    // account stays the one paying. The rider should see who is travelling.
    final assistedName = forPassenger?.trim();
    final ridesFor = (assistedName == null || assistedName.isEmpty)
        ? passenger.name
        : assistedName;

    final request = RideRequestItem(
      id: _nextRequestId(),
      passengerId: passenger.id,
      vehicleId: option.name,
      passengerName: ridesFor,
      passengerInitials: ridesFor == passenger.name
          ? passenger.initials
          : _initialsFor(ridesFor),
      passengerRating: passenger.rating,
      pickupBarangay: pickup.split(',').first.trim(),
      pickupPurok: _purokFrom(pickup),
      pickup: pickup,
      pickupLatitude: bookingPickup?.latitude,
      pickupLongitude: bookingPickup?.longitude,
      dropoffBarangay: destination.split(',').first.trim(),
      dropoffPurok: _purokFrom(destination),
      dropoff: destination,
      dropoffLatitude: bookingDestination?.latitude,
      dropoffLongitude: bookingDestination?.longitude,
      distanceKm: bookingDistance.kilometres,
      etaMinutes: bookingTravelMinutes,
      fare: option.fare,
      platformFeeCentavos: bookingPrice.platformFee,
      paymentMethod: 'Cash',
      note: assistedName == null || assistedName.isEmpty
          ? ''
          : 'Booking for $assistedName${contactNumber == null ? '' : ' · Contact: $contactNumber'}${requestChannel == null ? '' : ' · Requested via $requestChannel'}',
      requestedAt: 'Just now',
      status: RideStatus.searching,
    );

    db.rideRequests.insert(0, request);
    myRideRequest = request;
    rideProposal = null;
    rideReceiptPending = false;
    syncRideRoute(request);
    notifyListeners();
    return request;
  }

  // ---- hosted ride dispatch ----
  //
  // A hosted build has no local request list to mutate. These methods write
  // through the repository functions and keep the presentation model pointed at
  // the row the database returned. They deliberately do not fall back to the
  // seed: a failed write is shown as a failure, never as a fake local booking.

  /// Creates the request in Postgres for the signed-in passenger.
  ///
  /// Returns the presentation model for the inserted row. Throws a
  /// [RepositoryFailure] when the database refused the request, so the booking
  /// screen can show the database's own reason.
  Future<RideRequestItem> createHostedRideRequest({
    String? forPassenger,
    String? contactNumber,
    String? requestChannel,
  }) {
    if (!usesHostedRideDispatch) {
      return Future.error(
        RepositoryFailure.unsupported('Hosted ride dispatch is not enabled.'),
      );
    }
    final existing = liveRideRequest;
    if (existing != null) return Future.value(existing);
    final pending = _creatingHostedRide;
    if (pending != null) return pending;
    final operation = _createHostedRideRequest(
      forPassenger: forPassenger,
      contactNumber: contactNumber,
      requestChannel: requestChannel,
    );
    _creatingHostedRide = operation;
    return operation.whenComplete(() {
      if (identical(_creatingHostedRide, operation)) _creatingHostedRide = null;
    });
  }

  Future<RideRequestItem> _createHostedRideRequest({
    String? forPassenger,
    String? contactNumber,
    String? requestChannel,
  }) async {
    final generation = _passengerRideGeneration;
    final rides = repositories.rides;
    final pickup = pickupLabel;
    final destination = destinationLabel;
    final price = bookingPrice;
    final distance = bookingDistance;

    final assistedName = forPassenger?.trim();
    final note = (assistedName == null || assistedName.isEmpty)
        ? null
        : 'Booking for $assistedName${contactNumber == null ? '' : ' · Contact: $contactNumber'}${requestChannel == null ? '' : ' · Requested via $requestChannel'}';

    final record = await rides.createRideRequest(
      pickupAddress: pickup,
      // The full label is passed as the barangay hint. The database function
      // strips a leading "Barangay" and matches the known barangay name inside
      // the label, so "Purok 3, San Isidro" still resolves to San Isidro.
      pickupBarangay: pickup,
      pickupPurok: _purokFrom(pickup),
      pickupLatitude: bookingPickup?.latitude,
      pickupLongitude: bookingPickup?.longitude,
      dropoffAddress: destination,
      dropoffBarangay: destination,
      dropoffPurok: _purokFrom(destination),
      dropoffLatitude: bookingDestination?.latitude,
      dropoffLongitude: bookingDestination?.longitude,
      distanceKm: distance.kilometres,
      etaMinutes: bookingTravelMinutes,
      fareCentavos: price.providerFare,
      platformFeeCentavos: price.platformFee,
      note: note,
    );

    if (generation != _passengerRideGeneration) {
      throw RepositoryFailure.conflict(
        'Your session changed. Reopen your current request after signing in.',
      );
    }
    _passengerRides?.recordWrite(record);
    final request = rideRequestFromRecord(record);
    myRideRequest = request;
    rideProposal = null;
    rideReceiptPending = false;
    passengerRideFailure = null;
    syncRideRoute(request);
    notifyListeners();
    return request;
  }

  /// Finds an online, available rider for a hosted request.
  ///
  /// The database ranks candidates by distance from the pickup, then rating.
  /// The exclusion set is applied client-side so "Find Another" walks down that
  /// order without a second query shape.
  Future<MatchOutcome> proposeHostedRider(
    RideRequestItem request, {
    Set<String> excludeRiderIds = const {},
  }) async {
    if (request.status != RideStatus.searching ||
        myRideRequest?.id != request.id) {
      return MatchOutcome.noRidersAvailable;
    }
    final generation = _passengerRideGeneration;
    final candidates = await repositories.rides.findAvailableRiders(
      pickupLatitude: request.pickupLatitude,
      pickupLongitude: request.pickupLongitude,
      excludeProfileId: currentAccount?.riderId,
    );
    if (generation != _passengerRideGeneration ||
        myRideRequest?.id != request.id ||
        myRideRequest?.status != RideStatus.searching) {
      return MatchOutcome.noRidersAvailable;
    }

    final available = [
      for (final candidate in candidates)
        if (!excludeRiderIds.contains(candidate.profileId) &&
            candidate.hasPosition)
          candidate,
    ];

    if (available.isEmpty) {
      if (rideProposal != null) {
        rideProposal = null;
        notifyListeners();
      }
      return MatchOutcome.noRidersAvailable;
    }

    final best = available.first;
    final rider = mapRiderFromCandidate(best);
    final distance = best.distanceKm;
    rideProposal = RideMatchProposal(
      rider: rider,
      requestId: request.id,
      etaMinutes: _etaMinutesFor(distance, rider),
      fare: request.fare,
      distanceKm: distance,
    );
    notifyListeners();
    return MatchOutcome.proposed;
  }

  /// Sends the hosted request to the proposed rider.
  ///
  /// Throws a [RepositoryFailure] when the rider went offline between the
  /// proposal and the tap, so the matching screen can refresh instead of
  /// pretending the offer landed.
  Future<bool> confirmHostedRideMatch() async {
    final request = myRideRequest;
    final proposal = rideProposal;
    if (request == null || proposal == null) return false;

    final generation = _passengerRideGeneration;
    final record = await repositories.rides.assignRider(
      rideId: request.id,
      riderId: proposal.rider.id,
    );
    if (generation != _passengerRideGeneration ||
        myRideRequest?.id != record.id) {
      return false;
    }
    _passengerRides?.recordWrite(record);
    myRideRequest = rideRequestFromRecord(record);
    rideProposal = null;
    passengerRideFailure = null;
    notifyListeners();
    return true;
  }

  /// Cancels the hosted request as the passenger.
  ///
  /// A request that has already ended is left alone: cancellation is not a way
  /// to rewrite a completed trip's history.
  Future<void> cancelHostedRideRequest({String? reason}) async {
    final request = myRideRequest;
    if (request == null || request.status.isTerminal) return;
    final generation = _passengerRideGeneration;
    final record = await repositories.rides.cancelRide(
      rideId: request.id,
      reason: reason ?? 'Cancelled by passenger',
    );
    if (generation != _passengerRideGeneration ||
        myRideRequest?.id != record.id) {
      return;
    }
    _passengerRides?.recordWrite(record);
    myRideRequest = rideRequestFromRecord(record);
    if (activeRide?.id == record.id) {
      activeRide = null;
      activeRideBreakdown = null;
    }
    rideProposal = null;
    passengerRideFailure = null;
    notifyListeners();
  }

  /// Refreshes the rider's presence and inbox from Postgres.
  ///
  /// The rider home calls this on a timer so a request assigned while the
  /// screen was open appears without the rider toggling online or reopening
  /// the tab. Failures stay in the cache and are shown by the slots' own
  /// failure states; a refresh must not throw from a timer.
  Future<void> refreshRiderWorkspace() async {
    if (!usesHostedIdentity || !isSignedIn) return;
    await cache.refresh(DomainSlot.riderPresence);
    await cache.refresh(DomainSlot.riderIncomingRides);
    await cache.refresh(DomainSlot.earnerSettlements);
    restoreHostedRiderTrip();
    // Helper mode shares the rider account, so the errand slots are part of
    // the same workspace refresh.
    await cache.refresh(DomainSlot.providerErrands);
    await cache.refresh(DomainSlot.openErrands);
  }

  /// Re-seats the rider's committed hosted trip after a reopen.
  ///
  /// The active-trip banner is driven by [activeRide], which only the accept
  /// tap sets. Without this, reloading or coming back to the rider tab would
  /// leave a live trip as a read-only card with no way to advance it.
  void restoreHostedRiderTrip() {
    if (!usesHostedRideDispatch) return;
    final profileId = identity?.userId;
    if (profileId == null) return;
    final records = cache.dataOf<List<RideRecord>>(
      DomainSlot.riderIncomingRides,
    );
    if (records == null) return;
    // [isActive] excludes completed and cancelled history, which the same
    // rider read also returns; re-seating one of those would resurrect a
    // finished trip as a live banner.
    RideRecord? mine;
    for (final record in records) {
      if (record.riderId == profileId && record.status.isActive) {
        mine = record;
        break;
      }
    }
    if (mine == null) {
      if (activeRide?.riderId == profileId) {
        activeRide = null;
        activeRideBreakdown = null;
        notifyListeners();
      }
      return;
    }
    if (activeRide?.id == mine.id) return;
    final updated = rideRequestFromRecord(mine);
    activeRide = updated;
    activeRideBreakdown = RidePricing.breakdown(priceFor(updated));
    notifyListeners();
  }

  /// Moves the signed-in participant's hosted trip to its next state.
  ///
  /// The database owns the transition table, so this asks for the enum's next
  /// state and lets the RPC refuse anything else. Completion also releases the
  /// rider's availability and increments the passenger's trip count inside the
  /// database; no money or history is written here. Returns the new status, or
  /// null when there is nothing legal to do.
  void applyHostedRideUpdate(RideRecord record) {
    if (!usesHostedRideDispatch) return;
    final profileId = identity?.userId;
    final ownsRequest = profileId != null && record.passengerId == profileId;
    final ownsActiveTrip =
        profileId != null &&
        record.riderId == profileId &&
        activeRide?.id == record.id;
    if (!ownsRequest && !ownsActiveTrip) return;
    final updated = rideRequestFromRecord(record);
    if (ownsRequest) myRideRequest = updated;
    if (updated.status.isTerminal) {
      if (activeRide?.id == updated.id) {
        activeRide = null;
        activeRideBreakdown = null;
      }
      rideProposal = null;
      if (updated.status == RideStatus.completed) {
        lastCompletedRide = rideHistoryFromRow(record);
        // The trip ended here, so Home can offer the receipt instead of
        // dropping back to an empty request card.
        rideReceiptPending = true;
        final riderName = record.riderName?.trim();
        final name = riderName == null || riderName.isEmpty
            ? 'Rider'
            : riderName;
        lastCompletedRideDriver = Driver(
          name: name,
          initials: _initialsFor(name),
          rating: 0,
          trips: 0,
          plate: '',
          vehicleType: 'Ride',
        );
        lastRideBreakdown = RidePricing.breakdown(priceFor(updated));
      }
    } else if (updated.status.isCommitted) {
      activeRide = updated;
      activeRideBreakdown = RidePricing.breakdown(priceFor(updated));
      rideProposal = null;
    } else {
      if (activeRide?.id == updated.id) {
        activeRide = null;
        activeRideBreakdown = null;
      }
      if (updated.status != RideStatus.searching ||
          rideProposal?.requestId != updated.id) {
        rideProposal = null;
      }
    }
    syncRideRoute(updated);
    passengerRideFailure = null;
    notifyListeners();
  }

  Future<RideStatus?> advanceHostedRide() async {
    final request = activeRide ?? myRideRequest;
    if (request == null) return null;
    final next = request.nextStatus;
    if (next == null) return null;

    final generation = _passengerRideGeneration;
    final rides = repositories.rides;
    final record = await rides.advanceRideStatus(
      rideId: request.id,
      status: next.wireValue,
    );
    if (generation != _passengerRideGeneration) return null;
    _passengerRides?.recordWrite(record);
    applyHostedRideUpdate(record);
    RideRecord? full;
    try {
      full = await rides.fetchRide(record.id);
    } on RepositoryFailure {
      unawaited(_passengerRides?.refresh());
    }
    if (generation != _passengerRideGeneration) return null;
    if (full != null) applyHostedRideUpdate(full);
    await cache.refresh(DomainSlot.riderPresence);
    await cache.refresh(DomainSlot.riderIncomingRides);
    await cache.refresh(DomainSlot.earnerSettlements);
    return (full ?? record).status;
  }

  /// Reads the device fix used when a real rider goes online.
  ///
  /// Tests replace it so the location plugin is not exercised; production
  /// leaves it null and falls back to [LocationService].
  Future<MapPoint?> Function()? riderFixReader;

  /// Turns the signed-in rider online or offline in Postgres.
  ///
  /// A real rider shares a device fix when going online because the database
  /// refuses an online row without coordinates and discovery needs a position
  /// to rank them. A demo rider keeps the seeded simulated fix: overwriting it
  /// with the device's location would misrepresent simulated presence as real
  /// GPS. If the device cannot produce a fix, no coordinates are sent and the
  /// database's "share your location" refusal is shown.
  Future<void> setHostedRiderOnline(bool online) async {
    MapPoint? fix;
    if (online && !isDemoAccount) {
      final readFix =
          riderFixReader ?? LocationService.instance.getCurrentLocation;
      fix = await readFix();
    }
    await repositories.rides.setPresence(
      online: online,
      latitude: fix?.latitude,
      longitude: fix?.longitude,
    );
    riderOnline = online;
    notifyListeners();
    await cache.refresh(DomainSlot.riderPresence);
    await cache.refresh(DomainSlot.riderIncomingRides);
  }

  /// Accepts or declines a request assigned to the signed-in rider.
  Future<void> respondToHostedRequest(
    RideRequestItem request, {
    required bool accepted,
  }) async {
    final record = await repositories.rides.respondToRide(
      rideId: request.id,
      accept: accepted,
    );
    final full = await repositories.rides.fetchRide(record.id) ?? record;
    final updated = rideRequestFromRecord(full);
    if (accepted) {
      activeRide = updated;
      activeRideBreakdown = RidePricing.breakdown(priceFor(updated));
      riderOnline = true;
    }
    notifyListeners();
    await cache.refresh(DomainSlot.riderPresence);
    await cache.refresh(DomainSlot.riderIncomingRides);
  }

  /// Cancels the hosted trip the signed-in rider is currently running.
  ///
  /// The banner's cancel button used to mutate only the in-memory trip, which
  /// left the database row accepted forever. This goes through the same
  /// participant-checked RPC the passenger path uses.
  Future<void> cancelHostedActiveRide({String? reason}) async {
    final ride = activeRide;
    if (ride == null || ride.status.isTerminal) return;
    final record = await repositories.rides.cancelRide(
      rideId: ride.id,
      reason: reason ?? 'Cancelled by rider',
    );
    if (activeRide?.id == record.id) {
      activeRide = null;
      activeRideBreakdown = null;
    }
    notifyListeners();
    await cache.refresh(DomainSlot.riderPresence);
    await cache.refresh(DomainSlot.riderIncomingRides);
  }

  /// Initials for an assisted-booking passenger's name, matching the seed
  /// convention: first letter of the first and last word.
  String _initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  /// Picks a rider for [request] and holds them as a proposal.
  ///
  /// [excludeRiderIds] carries the riders the passenger already turned down, so
  /// "Find Another" walks down the ranking instead of offering the same person
  /// twice. Returns [MatchOutcome.noRidersAvailable] when nothing suitable is
  /// free. Matching is deterministic: candidates are ranked, not picked at
  /// random, so the same request and exclusion set always propose the same
  /// rider and the flow is testable.
  MatchOutcome proposeRider(
    RideRequestItem request, {
    Set<String> excludeRiderIds = const {},
  }) {
    if (request.status != RideStatus.searching) {
      // Already matched or finished; a second proposal would strand the first.
      return MatchOutcome.noRidersAvailable;
    }

    // Riders on their own account must not be offered their own request, and
    // the seeded fleet has no account column, so the id and the name are both
    // checked rather than trusting either alone.
    final selfRiderId = currentAccount?.riderId;
    final selfNames = {
      passenger.name.toLowerCase(),
      if (request.passengerName.trim().isNotEmpty)
        request.passengerName.trim().toLowerCase(),
    };

    final candidates = db.mapRiders.where((r) {
      return r.available &&
          r.verified &&
          r.id != selfRiderId &&
          !selfNames.contains(r.name.toLowerCase()) &&
          activeRide?.riderId != r.id &&
          !excludeRiderIds.contains(r.id);
    }).toList();

    if (candidates.isEmpty) {
      // A rider offered a moment ago must not stay on screen as if they were
      // still the answer to this search.
      if (rideProposal != null) {
        rideProposal = null;
        notifyListeners();
      }
      return MatchOutcome.noRidersAvailable;
    }

    // Nearest first, so the passenger is shown the rider who can actually get
    // there soonest. Riders whose distance is unknown sort last rather than
    // first: "we don't know" must not outrank a known closer rider. Ties break
    // on rating then id, so the order is total and a rerun proposes the same
    // rider.
    final ranked = [...candidates]
      ..sort((a, b) {
        final da = _distanceKmBetween(a.position, request);
        final db_ = _distanceKmBetween(b.position, request);
        if (da != null && db_ != null) {
          final byDistance = da.compareTo(db_);
          if (byDistance != 0) return byDistance;
        } else if (da != null) {
          return -1;
        } else if (db_ != null) {
          return 1;
        }
        final byRating = b.rating.compareTo(a.rating);
        if (byRating != 0) return byRating;
        return a.id.compareTo(b.id);
      });

    final best = ranked.first;
    final distance = _distanceKmBetween(best.position, request);
    rideProposal = RideMatchProposal(
      rider: best,
      requestId: request.id,
      etaMinutes: _etaMinutesFor(distance, best),
      fare: request.fare,
      distanceKm: distance,
    );
    notifyListeners();
    return MatchOutcome.proposed;
  }

  /// The passenger accepts the proposed rider: the request becomes pending.
  ///
  /// This is the point the request stops being open, and it is deliberately not
  /// the point the trip starts: the rider has not agreed yet. Selecting also
  /// files the request under the chosen rider so only they see it, and tells
  /// the passenger's notification feed where it went.
  bool confirmRideMatch() {
    final request = myRideRequest;
    final proposal = rideProposal;
    if (request == null || proposal == null) return false;
    if (!request.advanceTo(RideStatus.awaitingAcceptance)) return false;
    request.riderId = proposal.rider.id;
    rideProposal = null;
    _notifyRideRequestSent(request, proposal.rider);
    notifyListeners();
    return true;
  }

  /// Records the dispatch in both inboxes.
  ///
  /// Mock builds only: a Supabase build has no INSERT grant on `notifications`,
  /// so a row written here would never reach the database and would present a
  /// local fabrication as a real notification.
  void _notifyRideRequestSent(RideRequestItem request, MapRider rider) {
    if (usesHostedIdentity) return;
    final now = DateTime.now();
    final stamp = now.microsecondsSinceEpoch;
    _notificationFeed(db.passenger.id).insert(
      0,
      NotificationItem(
        id: 'n${stamp}_p',
        type: 'ride',
        title: 'Request sent to ${rider.name}',
        body:
            '${request.pickup} → ${request.dropoff}. '
            'The trip starts once ${rider.name} accepts.',
        time: 'Just now',
        read: false,
        createdAt: now,
      ),
    );
    _notificationFeed(rider.id).insert(
      0,
      NotificationItem(
        id: 'n${stamp}_r',
        type: 'ride',
        title: 'New ride request',
        body:
            '${request.passengerName} wants a ride: '
            '${request.pickup} → ${request.dropoff}.',
        time: 'Just now',
        read: false,
        createdAt: now,
      ),
    );
  }

  /// The editable list behind one profile's notification feed.
  ///
  /// The seed keeps the signed-in passenger and earner slices as fields as well
  /// as map entries, so those two must mutate the field list rather than a
  /// detached copy. Any other profile gets a list of its own: falling back to
  /// the passenger's would put the rider's copy in the passenger's feed.
  List<NotificationItem> _notificationFeed(String profileId) {
    final existing = db.notificationsByUser[profileId];
    if (existing != null) return existing;
    final List<NotificationItem> list;
    if (profileId == db.passenger.id) {
      list = db.passengerNotifications;
    } else if (profileId == db.earner.id) {
      list = db.earnerNotifications;
    } else {
      list = <NotificationItem>[];
    }
    db.notificationsByUser[profileId] = list;
    return list;
  }

  /// The passenger declines the proposal, putting the request back to matching.
  void declineRideMatch() {
    final request = myRideRequest;
    if (request == null) return;
    // Declining is not cancelling: the request goes back to searching so a
    // different rider can be proposed, and the rider's id is cleared so no
    // screen still shows the rejected rider.
    request.status = RideStatus.searching;
    request.riderId = null;
    rideProposal = null;
    notifyListeners();
  }

  /// The rider accepts. Unlocks chat and the trip states.
  ///
  /// This is the simulated counterpart of the rider tapping Accept; the
  /// matching screen calls it after a pause so the pending state is visible.
  void riderAccepts(RideRequestItem request) {
    if (!request.advanceTo(RideStatus.accepted)) return;
    activeRide = request;
    activeRideBreakdown = RidePricing.breakdown(priceFor(request));
    notifyListeners();
  }

  /// Whether the rider has accepted and the trip may begin.
  bool get canChatOnRide {
    final request = myRideRequest;
    return request != null && request.status.allowsChat;
  }

  // ---- ride chat ----
  //
  // Chat is scoped to a ride and lasts exactly as long as the trip. Threads are
  // held in memory by request id rather than on a single "current thread"
  // field, so a finished trip's messages cannot bleed into the next ride.

  final Map<String, RideChatThread> _rideChats = {};

  /// Whether the active ride's chat is open right now, and if not, why.
  ChatAvailability get chatAvailability =>
      chatAvailabilityFor(myRideRequest?.status);

  /// The active ride's thread, or null when the trip is not chat-ready yet.
  ///
  /// Returning null rather than an empty thread is deliberate: an empty thread
  /// and a closed one look identical on screen but mean different things.
  ///
  /// Creates the thread on demand when the trip is ready. Doing it lazily here
  /// rather than behind a separate "open" call means a screen cannot render one
  /// frame of empty state before the first message list exists.
  RideChatThread? get rideChat {
    final request = myRideRequest;
    if (request == null) return null;
    if (chatAvailabilityFor(request.status) != ChatAvailability.available) {
      return null;
    }
    return _rideChats[request.id] ?? _createRideChat(request);
  }

  /// Opens the thread for the active ride, creating it on first use.
  ///
  /// Returns null when the trip is not chat-ready, so a caller cannot create a
  /// thread for a trip that has not started.
  RideChatThread? openRideChat() => rideChat;

  /// Builds and stores the thread for [request]. Private because the status
  /// gate has already been checked by the callers above.
  RideChatThread? _createRideChat(RideRequestItem request) {
    final existing = _rideChats[request.id];
    if (existing != null) return existing;

    // The rider is whoever the request was matched to. Falling back to the
    // nearest available rider keeps the thread usable if the request lost its
    // rider id somehow, instead of showing a nameless chat.
    MapRider? rider;
    if (request.riderId != null) {
      for (final r in db.mapRiders) {
        if (r.id == request.riderId) {
          rider = r;
          break;
        }
      }
    }
    rider ??= _firstWhereOrNull(db.mapRiders, (r) => r.available);
    if (rider == null) return null;

    final now = DateTime.now();
    final thread = RideChatThread(
      requestId: request.id,
      rider: rider,
      messages: seedRideMessages(
        requestId: request.id,
        rider: rider,
        pickup: request.pickup,
        etaMinutes: request.etaMinutes,
        now: now,
      ),
    );
    _rideChats[request.id] = thread;
    return thread;
  }

  /// Appends a message to the active ride's thread.
  ///
  /// Returns why it was refused instead of dropping it silently: a passenger
  /// who types into a closed thread needs to be told, not left wondering where
  /// their message went.
  ChatSendRefusal? sendRideMessage(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return ChatSendRefusal.empty;
    if (trimmed.length > kMaxChatMessageLength) {
      return ChatSendRefusal.tooLong;
    }

    final thread = rideChat;
    if (thread == null) {
      final availability = chatAvailability;
      return availability == ChatAvailability.ended
          ? ChatSendRefusal.tripEnded
          : ChatSendRefusal.tripNotAccepted;
    }

    thread.add(
      RideChatMessage(
        id: '${thread.requestId}-m${thread.length}-${DateTime.now().microsecondsSinceEpoch}',
        requestId: thread.requestId,
        author: ChatAuthor.passenger,
        body: trimmed,
        sentAt: DateTime.now(),
      ),
    );
    notifyListeners();
    return null;
  }

  /// Drops the thread for a ride once it is over.
  ///
  /// Called when the trip reaches a terminal state so a completed ride cannot
  /// keep accepting messages, and so the memory does not grow with every trip
  /// taken in one session.
  void _closeRideChat() {
    final request = myRideRequest;
    if (request == null) return;
    _rideChats.remove(request.id);
  }

  /// Cancels the passenger's request from anywhere before completion.
  void cancelRideRequest() {
    final request = myRideRequest;
    if (request == null) return;
    if (!request.cancel()) return;
    _closeRideChat();
    db.rideRequests.remove(request);
    myRideRequest = null;
    rideProposal = null;
    activeRide = null;
    activeRideBreakdown = null;
    notifyListeners();
  }

  /// Builds a request id that cannot collide with an existing one.
  ///
  /// A plain `microsecondsSinceEpoch` is not enough: two requests created in
  /// the same microsecond produce the same id, and two records sharing an id
  /// would make one of the trips impossible to find or complete.
  int _requestSequence = 0;

  String _nextRequestId() {
    var id = 'rq${DateTime.now().microsecondsSinceEpoch}_${_requestSequence++}';
    while (db.rideRequests.any((r) => r.id == id)) {
      id = 'rq${DateTime.now().microsecondsSinceEpoch}_${_requestSequence++}';
    }
    return id;
  }

  /// Resolves a free-text place label to a point, or null when it is not one of
  /// the city's seeded places.
  ///
  /// Matching is exact against the place's label or address first, then a
  /// case-insensitive substring either way, so "SM Terminal, Downtown" still
  /// finds "SM Terminal". Returning null rather than a guess is deliberate: a
  /// fabricated coordinate would make rider ranking and ETAs look real while
  /// being wrong, which is worse than admitting the distance is unknown.
  MapPoint? _coordinatesFor(String label) {
    final needle = label.trim().toLowerCase();
    if (needle.isEmpty) return null;

    final places = db.places;
    for (final place in places) {
      if (place.label.toLowerCase() == needle ||
          place.address.toLowerCase() == needle) {
        return MapPoint(place.latitude, place.longitude);
      }
    }
    for (final place in places) {
      final candidate = place.label.toLowerCase();
      if (candidate.isNotEmpty &&
          (needle.contains(candidate) || candidate.contains(needle))) {
        return MapPoint(place.latitude, place.longitude);
      }
    }
    // A saved address often names only its barangay ("Purok 3, Barangay
    // Poblacion"). The seed has no purok coordinates but every barangay has a
    // known place, so the first place there stands in for the area. That is
    // enough to draw the pickup and rank riders, and it is still a real seed
    // coordinate rather than one invented at the city centre.
    final barangay = _barangayFrom(label);
    if (barangay != null) {
      for (final place in places) {
        if (place.barangay.toLowerCase().contains(barangay)) {
          return MapPoint(place.latitude, place.longitude);
        }
      }
    }
    return null;
  }

  String? _barangayFrom(String label) {
    final match =
        RegExp(r'barangay\s+([^,]+)', caseSensitive: false).firstMatch(label);
    final name = match?.group(1)?.trim().toLowerCase();
    return (name == null || name.isEmpty) ? null : name;
  }

  /// Straight-line distance from [riderAt] to the pickup, or null when either
  /// point has no coordinates.
  double? _distanceKmBetween(MapPoint riderAt, RideRequestItem request) {
    final lat = request.pickupLatitude;
    final lon = request.pickupLongitude;
    if (lat == null || lon == null) return null;
    return haversineKm(riderAt, MapPoint(lat, lon));
  }

  /// Waiting time shown for a proposal.
  ///
  /// Derived from the straight-line distance at a fixed city speed, so a
  /// closer rider always reads as a shorter wait. When the pickup has no
  /// coordinates the rider's own seeded estimate is used instead of inventing
  /// one.
  int _etaMinutesFor(double? distanceKm, MapRider rider) {
    // 18 km/h is a plausible average for tricycle and motorcycle traffic in a
    // city, including the stops at junctions.
    if (distanceKm == null) {
      // Unknown distance: fall back to the request's own ETA rather than
      // inventing one from nothing.
      return myRideRequest?.etaMinutes ?? 3;
    }
    final minutes = (distanceKm / 18.0 * 60).round();
    return minutes < 1 ? 1 : minutes;
  }

  /// The distance the booking will be priced on, and where it came from.
  ///
  /// Straight line between the two entries in the mock place table. The app
  /// has no routing engine, so it does not borrow the fare to invent a route
  /// the way the earlier estimate did — an unpriced booking and a mispriced
  /// one are both better answered by saying which number is which.
  TripDistance get bookingDistance => bookingRouting.route == null
      ? TripDistance.between(bookingPickup, bookingDestination)
      : TripDistance(
          kilometres: bookingRouting.route!.distanceMeters / 1000,
          source: DistanceSource.roadRoute,
        );

  /// What the passenger would pay for the selected vehicle, itemised.
  RidePrice get bookingPrice => RidePricing.price(
    providerFare: rideQuote.fare,
    distance: bookingDistance,
  );

  /// The price a trip settles at, from the fields the request itself carries.
  ///
  /// A request made in this session has coordinates and is priced on them; a
  /// request that came from the seed is priced on the distance it was seeded
  /// with. Both are mock distances, and [TripDistance.source] says which.
  RidePrice priceFor(RideRequestItem request) {
    final storedFee = request.platformFeeCentavos;
    if (storedFee != null) {
      return RidePrice(
        providerFare: request.fare,
        platformFee: storedFee,
        distance: request.distanceKm > 0
            ? TripDistance.seeded(request.distanceKm)
            : TripDistance.unknown,
      );
    }
    return RidePricing.forRequest(
      providerFare: request.fare,
      seededKilometres: request.distanceKm,
      pickup: _pointOf(request.pickupLatitude, request.pickupLongitude),
      dropoff: _pointOf(request.dropoffLatitude, request.dropoffLongitude),
    );
  }

  MapPoint? _pointOf(double? latitude, double? longitude) =>
      latitude == null || longitude == null
      ? null
      : MapPoint(latitude, longitude);

  /// The distance estimate shown on the booking screen before a request exists.
  double get estimatedDistanceKm => bookingDistance.kilometres;

  /// "Purok 3, San Isidro" -> "Purok 3". Returns an empty string when the label
  /// has no purok segment, rather than showing the whole place as a purok.
  String _purokFrom(String label) {
    final parts = label.split(',');
    if (parts.length < 2) return '';
    final first = parts.first.trim();
    return first.toLowerCase().startsWith('purok') ? first : '';
  }

  // ---- rider / driver mode ----
  bool riderOnline = true;

  /// Requests this rider can answer: everything still open, plus the ones the
  /// passenger addressed to them by selecting them. A request that went to a
  /// different rider stays out of this inbox, and so does one this account
  /// placed as a passenger — a rider cannot accept their own trip.
  List<RideRequestItem> get pendingRequests {
    final myRiderId = db.earner.id;
    final myPassengerId = db.passenger.id;
    return db.rideRequests.where((r) {
      if (r.passengerId != null && r.passengerId == myPassengerId) return false;
      final assigned = r.riderId;
      return assigned == null || assigned == myRiderId;
    }).toList();
  }

  /// The request the rider currently has accepted, shown as a banner above
  /// the incoming-requests list until the trip is completed or cancelled.
  RideRequestItem? activeRide;

  /// The fee split for the trip the rider currently has accepted, used by the
  /// live trip screen's earnings preview. Null until a request is accepted.
  FeeBreakdown? activeRideBreakdown;

  void toggleRiderOnline() {
    riderOnline = !riderOnline;
    notifyListeners();
  }

  /// Advances an accepted trip along [RideStatus], using the enum's own next
  /// state. Every guard lives in the model, so this cannot skip a step.
  void advanceRide() {
    final request = activeRide;
    if (request == null) return;
    final next = request.nextStatus;
    if (next == null) return;
    if (!request.advanceTo(next)) return;
    // Keep the passenger's copy pointed at the same object so both sides read
    // one status rather than two that can disagree.
    if (identical(myRideRequest, request) || myRideRequest?.id == request.id) {
      myRideRequest = request;
    }
    notifyListeners();
  }

  void respondToRequest(RideRequestItem request, {required bool accepted}) {
    // The incoming list already filters to this rider, but the decision itself
    // must hold too: a request sent to someone else must not be answerable
    // from here. The demo account acts as both passenger and rider, which is
    // why the passenger side is not refused here but filtered out of the list.
    final assigned = request.riderId;
    if (assigned != null && assigned != db.earner.id) return;
    if (request.status != RideStatus.searching &&
        request.status != RideStatus.awaitingAcceptance) {
      return;
    }
    db.rideRequests.remove(request);
    if (accepted) {
      // Route through the same path the simulated acceptance uses, so a request
      // accepted from the rider's incoming list lands in [RideStatus.accepted]
      // like any other accepted trip. Assigning activeRide here alone would
      // leave the request in `searching` and make the trip's state unreadable.
      request.status = RideStatus.awaitingAcceptance;
      request.riderId ??= db.earner.id;
      riderAccepts(request);
    } else {
      request.cancel();
    }
    _notifyRiderResponse(request, accepted: accepted);
    notifyListeners();
  }

  /// Tells the passenger how the rider answered, so a request that ends after
  /// the passenger went home is not a dead end. Mock builds only, for the same
  /// reason as [_notifyRideRequestSent].
  void _notifyRiderResponse(RideRequestItem request, {required bool accepted}) {
    if (usesHostedIdentity) return;
    final rider = _firstWhereOrNull(
      db.mapRiders,
      (r) => r.id == request.riderId,
    );
    final name = rider?.name ?? 'Your rider';
    final now = DateTime.now();
    final route = '${request.pickup} → ${request.dropoff}';
    _notificationFeed(db.passenger.id).insert(
      0,
      NotificationItem(
        id: 'n${now.microsecondsSinceEpoch}_a',
        type: 'ride',
        title: accepted
            ? '$name accepted your ride'
            : '$name declined your ride',
        body: accepted
            ? '$route is confirmed. Follow the trip from your activity.'
            : '$route was declined. Book again to find another rider.',
        time: 'Just now',
        read: false,
        createdAt: now,
      ),
    );
  }

  /// The fee split for the trip just completed. Set by [completeActiveRide] so
  /// the receipt screen can show "Customer pays / You get / SurGo keeps"
  /// without recomputing. Null when there is no receipt to show.
  FeeBreakdown? lastRideBreakdown;

  /// The passenger's history row for the trip just settled, and the driver it
  /// was settled against. Both are set by [completeActiveRide] so the rating
  /// screen reads the completed trip instead of rebuilding it from MockData.
  RideHistoryItem? lastCompletedRide;
  Driver? lastCompletedRideDriver;

  /// True from the moment a hosted trip completes until the receipt is
  /// acknowledged, so Home can show a way back to it after the live card is
  /// gone.
  bool rideReceiptPending = false;

  void acknowledgeRideReceipt() {
    if (!rideReceiptPending) return;
    rideReceiptPending = false;
    notifyListeners();
  }

  /// Settles the accepted trip: one path for both the rider's banner and the
  /// passenger's Live Trip screen.
  ///
  /// The trip's own state machine is the guard, so a request still searching,
  /// or one already finished, pays nothing. Completing writes both sides of the
  /// history exactly once and releases the money in the same call. Returns
  /// whether the trip was settled.
  bool completeActiveRide() {
    final trip = activeRide;
    if (trip == null) return false;
    // Completing from anywhere but the last live state would mean the trip
    // ended without happening. This guard is what gates the money.
    if (!trip.advanceTo(RideStatus.completed)) return false;

    final price = priceFor(trip);
    final breakdown = RidePricing.breakdown(price);
    final driver = _driverForCompletedRide(trip);

    db.riderTrips.insert(
      0,
      RiderTripItem(
        id: 'rt${DateTime.now().microsecondsSinceEpoch}',
        passengerName: trip.passengerName,
        route: '${trip.pickup} → ${trip.dropoff}',
        date: 'Just now',
        fare: trip.fare,
        distanceKm: trip.distanceKm,
        status: 'Completed',
        rating: 5,
      ),
    );

    // The passenger's own history is written here, not by the rating screen.
    // If both completion paths inserted it, a trip completed from the rider's
    // banner would either be missing from the passenger's history or appear
    // twice. Rating later updates this row.
    final historyItem = RideHistoryItem(
      id: 'rh${DateTime.now().microsecondsSinceEpoch}',
      route: '${trip.pickup} → ${trip.dropoff}',
      date: 'Just now',
      fare: trip.fare,
      status: 'Completed',
      vehicleType: driver.vehicleType,
      driverName: driver.name,
      rating: 0,
      completedAt: DateTime.now(),
    );
    db.rideHistory.insert(0, historyItem);
    lastCompletedRide = historyItem;
    lastCompletedRideDriver = driver;

    // The rider keeps the whole agreed fare. The platform fee is the
    // customer's separate charge: it is recorded on the ledger and never
    // credited into the rider's wallet.
    db.earnerWalletBalance += price.providerFare;
    // ...and the home tile reads the roll-ups, so they have to move with it.
    _creditRiderEarnings(price.providerFare);
    // Cash-based prototype: the customer hands the driver the fare, so the
    // fee is earned here but is not yet money SurGo holds.
    PlatformLedger.instance.recordRide(
      providerFare: price.providerFare,
      platformFee: price.platformFee,
    );

    lastRideBreakdown = breakdown;
    activeRide = null;
    activeRideBreakdown = null;
    // The trip is over, so the thread closes with it.
    _closeRideChat();
    notifyListeners();
    return true;
  }

  /// The driver to show on the completed trip's receipt and rating screen.
  ///
  /// The request carries the assigned rider's id; the seeded rider profile is
  /// the fallback for a hand-built or unassigned trip, mirroring the Live Trip
  /// screen's own fallback so the two cannot name different drivers.
  Driver _driverForCompletedRide(RideRequestItem trip) {
    final assigned = trip.riderId == null
        ? null
        : _firstWhereOrNull(db.mapRiders, (r) => r.id == trip.riderId);
    if (assigned != null) {
      return Driver(
        name: assigned.name,
        initials: assigned.initials,
        rating: assigned.rating,
        trips: assigned.totalTrips,
        plate: assigned.vehiclePlate,
        vehicleType: trip.vehicleId ?? assigned.vehicleType,
      );
    }
    return Driver(
      name: db.earner.name,
      initials: db.earner.initials,
      rating: db.earner.rating,
      trips: db.earner.totalTrips,
      plate: db.earner.vehiclePlate,
      vehicleType: trip.vehicleId ?? db.earner.vehicleType,
    );
  }

  /// Applies the passenger's rating to the row [completeActiveRide] wrote.
  ///
  /// A hosted trip has no local seed row to update, so the completed receipt is
  /// still updated in place; acknowledging it also clears the Home reminder.
  void rateCompletedRide(int stars) {
    rideReceiptPending = false;
    final ride = lastCompletedRide;
    if (ride == null) return;
    final rated = ride.withRating(stars);
    final index = db.rideHistory.indexWhere((r) => r.id == ride.id);
    if (index >= 0) db.rideHistory[index] = rated;
    lastCompletedRide = rated;
    notifyListeners();
  }

  void cancelActiveRide() {
    // Mark the trip cancelled and keep the pointer, so [chatAvailability] reads
    // "ended" rather than "not accepted yet": a rider who was already driving
    // over needs to be told the trip was called off, not that nothing happened.
    activeRide?.cancel();
    _closeRideChat();
    activeRide = null;
    activeRideBreakdown = null;
    notifyListeners();
  }

  // ---- trip rating ----
  int tripRating = 4;
  final Set<String> tripCompliments = {'Safe driving'};

  void setTripRating(int stars) {
    tripRating = stars;
    notifyListeners();
  }

  void toggleCompliment(String compliment) {
    if (tripCompliments.contains(compliment)) {
      tripCompliments.remove(compliment);
    } else {
      tripCompliments.add(compliment);
    }
    notifyListeners();
  }

  // ---- notifications ----
  /// Marks the seeded notification with [id] read.
  ///
  /// The feed screen renders repository records now, and this stage never
  /// writes back, so a Supabase build keeps the last read on screen; the mock
  /// seed mutates in place and the cache re-reads the slot.
  void markNotificationReadById(String id) {
    for (final n in db.passengerNotifications) {
      if (n.id == id) n.read = true;
    }
    for (final n in db.earnerNotifications) {
      if (n.id == id) n.read = true;
    }
    notifyListeners();
  }

  void clearNotifications() {
    for (final n in db.passengerNotifications) {
      n.read = true;
    }
    notifyListeners();
  }

  void clearRiderNotifications() {
    for (final n in db.earnerNotifications) {
      n.read = true;
    }
    notifyListeners();
  }

  // ---- wallet ----
  void topUpPassengerWallet(int amount, String method) {
    db.passengerWalletBalance += amount;
    db.passengerTransactions.insert(
      0,
      WalletTransaction(
        id: 'wt${DateTime.now().microsecondsSinceEpoch}',
        type: 'topup',
        title: 'Wallet Top-up via $method',
        amount: amount,
        date: 'Just now',
        status: 'Completed',
      ),
    );
    notifyListeners();
  }

  /// The smallest payout `config.json` allows, in centavos.
  int get minimumWithdrawal => db.payoutMinWithdrawal;

  /// Requests a payout from the rider's earnings wallet.
  ///
  /// The wallet screen and the earnings screen both call this, so the guards
  /// live in one place: a zero/negative amount, an amount above the balance, or
  /// one below the configured minimum is refused before any money moves.
  /// Returns whether the payout was created.
  bool requestPayout(int amount, String method) {
    if (amount <= 0) return false;
    if (amount < db.payoutMinWithdrawal) return false;
    if (amount > db.earnerWalletBalance) return false;
    db.earnerWalletBalance -= amount;
    db.payoutHistory.insert(
      0,
      PayoutItem(
        id: 'po${DateTime.now().microsecondsSinceEpoch}',
        date: 'Just now',
        amount: amount,
        method: method,
        status: 'Processing',
      ),
    );
    db.earnerTransactions.insert(
      0,
      WalletTransaction(
        id: 'rwt${DateTime.now().microsecondsSinceEpoch}',
        type: 'payout',
        title: 'Payout to $method',
        amount: amount,
        date: 'Just now',
        status: 'Processing',
      ),
    );
    notifyListeners();
    return true;
  }

  // ---- payment methods ----
  List<PaymentMethodItem> get paymentMethods => db.paymentMethods;

  void setDefaultPaymentMethod(PaymentMethodItem method) {
    for (final m in db.paymentMethods) {
      m.isDefault = m.id == method.id;
    }
    notifyListeners();
  }

  void addPaymentMethod(PaymentMethodItem method) {
    db.paymentMethods.add(method);
    notifyListeners();
  }

  void removePaymentMethod(PaymentMethodItem method) {
    db.paymentMethods.remove(method);
    notifyListeners();
  }

  // ---- saved places ----
  List<SavedPlace> get savedPlaces => db.savedPlaces;

  void addSavedPlace(SavedPlace place) {
    db.savedPlaces.add(place);
    notifyListeners();
  }

  void removeSavedPlace(SavedPlace place) {
    db.savedPlaces.remove(place);
    notifyListeners();
  }

  // ---- favorites ----
  List<FavoriteRider> get favoriteRiders => db.favoriteRiders;
  List<FavoriteVehicle> get favoriteVehicles => db.favoriteVehicles;

  void removeFavoriteRider(FavoriteRider r) {
    db.favoriteRiders.remove(r);
    notifyListeners();
  }

  void removeFavoriteVehicle(FavoriteVehicle v) {
    db.favoriteVehicles.remove(v);
    notifyListeners();
  }

  // ---- emergency contacts ----
  List<EmergencyContactItem> get emergencyContacts => db.emergencyContacts;

  void addEmergencyContact(EmergencyContactItem c) {
    db.emergencyContacts.add(c);
    notifyListeners();
  }

  void removeEmergencyContact(EmergencyContactItem c) {
    db.emergencyContacts.remove(c);
    notifyListeners();
  }

  // ---- history ----
  List<RideHistoryItem> get rideHistory => db.rideHistory;
  List<RentalHistoryItem> get rentalHistory => db.rentalHistory;
  List<RiderTripItem> get riderTrips => db.riderTrips;

  void addRideToHistory(RideHistoryItem item) {
    db.rideHistory.insert(0, item);
    notifyListeners();
  }

  void addRentalToHistory(RentalHistoryItem item) {
    db.rentalHistory.insert(0, item);
    notifyListeners();
  }

  // ---- live session activity ----

  /// The passenger's own ride request while it is still live: searching, being
  /// matched, or on the road. Null once it completes or is cancelled, so a
  /// dashboard can show only what is actually in progress rather than a stale
  /// request the account already finished.
  RideRequestItem? get liveRideRequest {
    final request = myRideRequest;
    if (request == null || request.status.isTerminal) return null;
    return request;
  }

  /// Errands this account posted that have not finished, newest first. An
  /// errand still at `available` counts: the customer is waiting for a helper,
  /// so it belongs on their dashboard and activity list.
  List<PasuyoTask> get livePasuyoOrders =>
      myPasuyoOrders.where((t) => !t.status.isTerminal).toList();

  // ---- rental booking simulation (passenger) ----
  // A passenger can only have one open rental request/active rental at a
  // time in this simulation. It starts as "Pending" the moment they tap
  // Request Rental, shows up as a card on the Home tab, and — after a
  // simulated 10s owner-approval delay — flips to "Active" in place.
  RentalBooking? activeRentalBooking;
  Timer? _rentalApprovalTimer;

  /// Every booking created this session, so availability checks can see the
  /// days this account already holds. Not seeded: these only exist because
  /// somebody asked for them.
  final List<RentalBooking> _rentalBookings = [];

  /// A listing's bookability for the browse list, where no dates are chosen yet.
  ///
  /// Reads the same seeded record and bookings the detail screen does, so the
  /// two screens cannot show different answers for the same vehicle.
  RentalListingState rentalListingState(String vehicleId) {
    final vehicle = _firstWhereOrNull(
      db.ownerVehicles,
      (v) => v.id == vehicleId,
    );
    if (vehicle == null) return RentalListingState.unknown;

    if (vehicle.status == 'Maintenance') return RentalListingState.maintenance;

    // An accepted booking means it is out with a renter now, even if the seed
    // still says `Listed`: the live trip is the truer source.
    final outNow = _rentalBookings.any(
      (b) => b.vehicleId == vehicleId && b.blocksAvailability,
    );
    if (vehicle.status == 'Rented' || outNow) return RentalListingState.rented;

    return RentalListingState.available;
  }

  /// Whether [vehicleId] is free for [pickupDate]..[returnDate], and if not,
  /// why.
  ///
  /// Checked before a request is created rather than after: accepting a
  /// request that collides with an existing booking would leave two renters
  /// believing they have the same vehicle.
  RentalAvailability rentalAvailability({
    required String vehicleId,
    required DateTime pickupDate,
    required DateTime returnDate,
  }) => checkRentalAvailability(
    vehicle: _firstWhereOrNull(db.ownerVehicles, (v) => v.id == vehicleId),
    pickupDate: pickupDate,
    returnDate: returnDate,
    bookings: _rentalBookings.where((b) => b.vehicleId == vehicleId).toList(),
    ownerRequests: db.ownerBookingRequests
        .where((r) => r.vehicleId == vehicleId)
        .toList(),
  );

  RentalBooking requestRental({
    required String? vehicleId,
    required String vehicleName,
    required String vehicleType,
    required IconData icon,
    required String ownerName,
    required String ownerInitials,
    required String pickupLabel,
    required String returnLabel,
    required DateTime pickupDate,
    required DateTime returnDate,
    required int days,
    required int totalFare,
  }) {
    _rentalApprovalTimer?.cancel();
    final booking = RentalBooking(
      id: 'rb${DateTime.now().microsecondsSinceEpoch}',
      vehicleId: vehicleId,
      vehicleName: vehicleName,
      vehicleType: vehicleType,
      icon: icon,
      ownerName: ownerName,
      ownerInitials: ownerInitials,
      pickupLabel: pickupLabel,
      returnLabel: returnLabel,
      days: days,
      totalFare: totalFare,
      pickupDate: pickupDate,
      returnDate: returnDate,
      status: RentalStatus.requested,
      requestedAt: DateTime.now(),
    );
    _rentalBookings.add(booking);
    activeRentalBooking = booking;
    db.rentalHistory.insert(
      0,
      RentalHistoryItem(
        id: booking.id,
        vehicleName: vehicleName,
        ownerName: ownerName,
        startDate: pickupLabel,
        endDate: returnLabel,
        totalFare: totalFare,
        status: 'Requested',
      ),
    );
    notifyListeners();

    /// The simulated owner decides after a pause, standing in for the owner's tap
    /// on Accept. The 10s is the simulation, not the business rule: the booking
    /// sits in an explicit [RentalStatus] the whole time, so no screen has to
    /// guess, and the timer walks the same guarded path a real accept would.
    final revision = _authSessionRevision;
    final registry = repositories;
    _rentalApprovalTimer = Timer(const Duration(seconds: 10), () {
      if (revision != _authSessionRevision ||
          !identical(registry, repositories) ||
          usesHostedRideDispatch ||
          activeRentalBooking?.id != booking.id) {
        return;
      }
      // Guarded, not assigned: if the booking was cancelled or already moved
      // on, the advance is refused and the timer does nothing.
      if (!booking.advanceTo(RentalStatus.awaitingOwner)) return;
      acceptRentalRequest();
    });
    return booking;
  }

  /// Mirrors a booking's state onto its history row so the two cannot drift.
  void _syncRentalHistoryStatus(RentalBooking booking, String status) {
    final i = db.rentalHistory.indexWhere((r) => r.id == booking.id);
    if (i < 0) return;
    final existing = db.rentalHistory[i];
    db.rentalHistory[i] = RentalHistoryItem(
      id: existing.id,
      vehicleName: existing.vehicleName,
      ownerName: existing.ownerName,
      startDate: existing.startDate,
      endDate: existing.endDate,
      totalFare: existing.totalFare,
      status: status,
    );
  }

  /// Advances the live booking one step: requested → awaiting owner →
  /// accepted → out with the customer → returned.
  ///
  /// [active] is the caller's explicit "I am moving on" signal, so a screen
  /// cannot advance a booking the user has not confirmed.
  /// The renter sends the request on: requested → awaiting owner.
  void sendRentalRequest() {
    final booking = activeRentalBooking;
    if (booking == null) return;
    if (!booking.advanceTo(RentalStatus.awaitingOwner)) return;
    notifyListeners();
  }

  /// The owner accepts: awaiting owner → accepted, and the listing comes off
  /// the market so nobody else can book it.
  void acceptRentalRequest() {
    final booking = activeRentalBooking;
    if (booking == null) return;
    if (!booking.advanceTo(RentalStatus.accepted)) return;
    final vehicle = _firstWhereOrNull(
      db.ownerVehicles,
      (v) => v.id == booking.vehicleId,
    );
    if (vehicle != null) vehicle.status = 'Rented';
    notifyListeners();
  }

  /// Advances the live booking one step as the renter: accepted → out with the
  /// customer, or out with the customer → returned.
  ///
  /// [pickup] is the caller's explicit "I am moving on" signal, so a screen
  /// cannot advance a booking the user has not confirmed.
  void advanceRentalBooking({required bool pickup}) {
    final booking = activeRentalBooking;
    if (booking == null) return;
    final target = pickup ? RentalStatus.active : RentalStatus.returned;
    if (!booking.advanceTo(target)) return;
    // The vehicle is back on the market the moment it is returned, not when the
    // booking is finally marked complete.
    if (target == RentalStatus.returned) {
      final vehicle = _firstWhereOrNull(
        db.ownerVehicles,
        (v) => v.id == booking.vehicleId,
      );
      if (vehicle != null && vehicle.status == 'Rented') {
        vehicle.status = 'Listed';
      }
    }
    _syncRentalHistoryStatus(
      booking,
      target == RentalStatus.active ? 'Active' : 'Returned',
    );
    notifyListeners();
  }

  void cancelRentalBooking() {
    _rentalApprovalTimer?.cancel();
    final booking = activeRentalBooking;
    if (booking != null && booking.cancel()) {
      _syncRentalHistoryStatus(booking, 'Cancelled');
    }
    activeRentalBooking = null;
    notifyListeners();
  }

  /// Fee split for the rental just completed, for the owner's receipt.
  FeeBreakdown? lastRentalBreakdown;

  void completeActiveRental() {
    final booking = activeRentalBooking;
    if (booking == null) return;
    // Only a returned vehicle settles. The renter's own "Return the vehicle"
    // step puts the booking in [RentalStatus.returned]; this settles it. Both
    // guards matter: without the first, completing straight from `accepted`
    // would pay the owner for a rental that never came back, and without the
    // second the history row could be rewritten for a booking that had already
    // been settled.
    if (!booking.advanceTo(RentalStatus.completed)) return;

    final breakdown = FeeCalculator.breakdownFor(
      ServiceType.rental,
      booking.totalFare,
    );
    _syncRentalHistoryStatus(booking, 'Completed');
    db.ownerWalletBalance += breakdown.providerGets;
    _creditOwnerEarnings(breakdown.providerGets);
    PlatformLedger.instance.record(ServiceType.rental, booking.totalFare);
    lastRentalBreakdown = breakdown;
    activeRentalBooking = null;
    notifyListeners();
  }

  // ---- hosted rental lifecycle ----
  //
  // The database owns booking state: these methods call the RPCs and then
  // re-read the slot, so the screen never advances a booking on its own word.

  /// Re-reads both sides of the rental book, so an owner's decision shows on
  /// the renter's screen and a new request shows on the owner's.
  Future<void> refreshHostedRentals() async {
    if (!usesHostedRideDispatch || !isSignedIn) return;
    final revision = _authSessionRevision;
    await cache.refresh(DomainSlot.passengerRentalBookings);
    if (revision != _authSessionRevision) return;
    await cache.refresh(DomainSlot.ownerRentalBookings);
  }

  void _requireHostedSession(RepositoryRegistry registry, int revision) {
    if (!isSignedIn ||
        !usesHostedRideDispatch ||
        !identical(registry, repositories) ||
        revision != _authSessionRevision) {
      throw RepositoryFailure.conflict(
        'Your session changed. Reopen the request after signing in.',
      );
    }
  }

  /// Submits a hosted rental request for [vehicle].
  ///
  /// The server prices the fare and the platform fee and refuses an overlap, so
  /// neither amount is computed here.
  Future<RentalBooking> createHostedRentalRequest({
    required RentalVehicle vehicle,
    required DateTime pickupDate,
    required DateTime returnDate,
    required String pickupBarangayId,
    required String pickupLocation,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
  }) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    final created = await registry.rentals.createRequest(
      vehicleId: vehicle.id,
      startAt: pickupDate,
      endAt: returnDate,
      pickupLocation: pickupLocation,
      pickupBarangayId: pickupBarangayId,
      pickupPurokId: pickupPurokId,
      pickupLatitude: pickupLatitude,
      pickupLongitude: pickupLongitude,
    );
    _requireHostedSession(registry, revision);
    final full = await registry.rentals.fetchRental(created.id) ?? created;
    _requireHostedSession(registry, revision);
    final booking = rentalBookingFromRecord(full);
    notifyListeners();
    await refreshHostedRentals();
    return booking;
  }

  /// Accepts or declines a hosted request as the vehicle owner.
  Future<void> respondToHostedRentalRequest(
    OwnerBookingRequest request, {
    required bool accepted,
  }) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    await registry.rentals.respond(rentalId: request.id, accept: accepted);
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedRentals();
  }

  /// Moves a hosted booking one legal step. Returns the refreshed booking, or
  /// null when the booking has nowhere left to go.
  Future<RentalBooking?> advanceHostedRental(RentalBooking booking) async {
    final next = booking.status.next;
    if (next == null) return null;
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    final updated = await registry.rentals.advance(
      rentalId: booking.id,
      status: next,
    );
    _requireHostedSession(registry, revision);
    final full = await registry.rentals.fetchRental(updated.id) ?? updated;
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedRentals();
    // Completion settles the owner's payout into a service transaction, so the
    // owner earnings tab must read it again before it is shown.
    await cache.refresh(DomainSlot.earnerSettlements);
    return rentalBookingFromRecord(full);
  }

  Future<void> cancelHostedRental(
    RentalBooking booking, {
    String? reason,
  }) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    await registry.rentals.cancel(
      rentalId: booking.id,
      reason: reason ?? 'Cancelled from the app',
    );
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedRentals();
  }

  /// The receipt split for a hosted booking: the owner keeps the fare whole and
  /// the platform fee is the customer's add-on.
  FeeBreakdown hostedRentalBreakdown(RentalBooking booking) =>
      FeeBreakdown.fixedAddon(
        service: ServiceType.rental,
        providerFare: booking.totalFare,
        platformFee: booking.platformFee,
      );

  // ---- hosted errand lifecycle ----

  /// Re-reads the customer's errands, the helper's jobs and the open feed.
  Future<void> refreshHostedErrands() async {
    if (!usesHostedRideDispatch || !isSignedIn) return;
    final revision = _authSessionRevision;
    await cache.refresh(DomainSlot.customerErrands);
    if (revision != _authSessionRevision) return;
    await cache.refresh(DomainSlot.providerErrands);
    if (revision != _authSessionRevision) return;
    await cache.refresh(DomainSlot.openErrands);
  }

  /// Posts an errand as the signed-in customer. The server sets the platform
  /// fee and refuses a missing recipient when the errand is for someone else.
  Future<PasuyoTask> createHostedErrand({
    required PasuyoCategory category,
    required String title,
    required String pickupAddress,
    required String pickupBarangayId,
    required int quotedFeeCentavos,
    List<Map<String, dynamic>> items = const [],
    String? description,
    String? pickupPurokId,
    double? pickupLatitude,
    double? pickupLongitude,
    String? dropoffAddress,
    String? dropoffBarangayId,
    String? dropoffPurokId,
    double? dropoffLatitude,
    double? dropoffLongitude,
    bool bookedForSomeone = false,
    String? recipientName,
    String? recipientPhone,
  }) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    final created = await registry.pasuyo.createRequest(
      category: category,
      title: title,
      pickupAddress: pickupAddress,
      pickupBarangayId: pickupBarangayId,
      quotedFeeCentavos: quotedFeeCentavos,
      items: items,
      description: description,
      pickupPurokId: pickupPurokId,
      pickupLatitude: pickupLatitude,
      pickupLongitude: pickupLongitude,
      dropoffAddress: dropoffAddress,
      dropoffBarangayId: dropoffBarangayId,
      dropoffPurokId: dropoffPurokId,
      dropoffLatitude: dropoffLatitude,
      dropoffLongitude: dropoffLongitude,
      bookedForSomeone: bookedForSomeone,
      recipientName: recipientName,
      recipientPhone: recipientPhone,
    );
    _requireHostedSession(registry, revision);
    final full = await registry.pasuyo.fetchRequest(created.id) ?? created;
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedErrands();
    return pasuyoTaskFromRecord(full);
  }

  /// Claims an open errand as the signed-in helper.
  Future<PasuyoTask> acceptHostedErrand(PasuyoTask task) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    final accepted = await registry.pasuyo.accept(task.id);
    _requireHostedSession(registry, revision);
    final full = await registry.pasuyo.fetchRequest(accepted.id) ?? accepted;
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedErrands();
    return pasuyoTaskFromRecord(full);
  }

  /// Moves an assigned errand one legal step. Delivery settles the transaction
  /// inside the database; no money is written here.
  Future<PasuyoTask?> advanceHostedErrand(PasuyoTask task) async {
    final next = task.nextStatus;
    if (next == null) return null;
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    final updated = await registry.pasuyo.advance(
      requestId: task.id,
      status: next,
    );
    _requireHostedSession(registry, revision);
    final full = await registry.pasuyo.fetchRequest(updated.id) ?? updated;
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedErrands();
    // Delivery settles the errand into a service transaction, so the earnings
    // tiles and settlement history must be read again before the helper
    // returns to the workspace.
    await cache.refresh(DomainSlot.earnerSettlements);
    return pasuyoTaskFromRecord(full);
  }

  /// Records what the helper actually paid for the items.
  Future<void> setHostedErrandActuals(
    PasuyoTask task,
    List<Map<String, dynamic>> items,
  ) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    await registry.pasuyo.setItemActuals(requestId: task.id, items: items);
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedErrands();
  }

  Future<void> cancelHostedErrand(PasuyoTask task, {String? reason}) async {
    final registry = repositories;
    final revision = _authSessionRevision;
    _requireHostedSession(registry, revision);
    await registry.pasuyo.cancel(
      requestId: task.id,
      reason: reason ?? 'Cancelled from the app',
    );
    _requireHostedSession(registry, revision);
    notifyListeners();
    await refreshHostedErrands();
  }

  /// The receipt split for a hosted errand: the helper keeps the fee whole and
  /// the platform fee is the customer's add-on. Item cost is a pass-through and
  /// is deliberately not part of SurGo's take.
  FeeBreakdown hostedErrandBreakdown(PasuyoTask task) =>
      FeeBreakdown.fixedAddon(
        service: ServiceType.pasuyo,
        providerFare: task.budget,
        platformFee: task.platformFee > 0
            ? task.platformFee
            : HostedFees.pasuyoPlatformFeeCentavos,
      );

  // ---- favorites (toggle helpers) ----
  bool isFavoriteRiderName(String name) =>
      db.favoriteRiders.any((r) => r.name == name);

  void toggleFavoriteRiderByDriver({
    required String name,
    required String initials,
    required double rating,
    required int trips,
    required String vehicleType,
    required String plate,
  }) {
    final existing = db.favoriteRiders.where((r) => r.name == name).toList();
    if (existing.isNotEmpty) {
      db.favoriteRiders.remove(existing.first);
    } else {
      db.favoriteRiders.add(
        FavoriteRider(
          id: 'fr${DateTime.now().microsecondsSinceEpoch}',
          name: name,
          initials: initials,
          rating: rating,
          trips: trips,
          vehicleType: vehicleType,
          plate: plate,
        ),
      );
    }
    notifyListeners();
  }

  bool isFavoriteVehicleName(String name) =>
      db.favoriteVehicles.any((v) => v.name == name);

  void toggleFavoriteVehicleByListing({
    required String name,
    required String type,
    required int pricePerDay,
    required String ownerName,
  }) {
    final existing = db.favoriteVehicles.where((v) => v.name == name).toList();
    if (existing.isNotEmpty) {
      db.favoriteVehicles.remove(existing.first);
    } else {
      db.favoriteVehicles.add(
        FavoriteVehicle(
          id: 'fv${DateTime.now().microsecondsSinceEpoch}',
          name: name,
          type: type,
          pricePerDay: pricePerDay,
          ownerName: ownerName,
        ),
      );
    }
    notifyListeners();
  }

  // ---- rider earnings ----
  int get earningsToday => db.earningsToday;
  int get earningsWeek => db.earningsWeek;
  int get earningsMonth => db.earningsMonth;
  List<DailyEarning> get dailyEarnings => db.dailyEarnings;
  List<PayoutItem> get payoutHistory => db.payoutHistory;

  // ---- Pasuyo errands ----
  //
  // A Helper is a mode on the existing Rider role rather than a separate
  // role, so these tasks are accepted and progressed by the rider account.

  List<PasuyoTask> get pasuyoTasks => db.pasuyoTasks;

  /// Open tasks a helper can pick up, newest first.
  ///
  /// Gated on the errands/deliveries capabilities, because the whole point of
  /// `EarnerCapability` is that a rides-only driver is never offered errand
  /// work. Returning an empty feed here is the honest answer - the alternative
  /// is a task the earner would have to reject.
  List<PasuyoTask> get nearbyPasuyoTasks {
    if (!acceptsCapability(EarnerCapability.errands) &&
        !acceptsCapability(EarnerCapability.deliveries)) {
      return const [];
    }
    final list = db.pasuyoTasks.where((t) => t.isOpen).toList();
    list.sort((a, b) => b.id.compareTo(a.id));
    return list;
  }

  /// The task this helper is currently working, shown as a banner like the
  /// active ride is.
  PasuyoTask? activePasuyoTask;

  /// Tasks this helper has claimed but not yet delivered.
  List<PasuyoTask> get myPasuyoTasks => db.pasuyoTasks
      .where((t) => t.helperId == earner.id && t.isActive)
      .toList();

  List<PasuyoTask> get completedPasuyoTasks => db.pasuyoTasks
      .where(
        (t) => t.status == PasuyoStatus.delivered && t.helperId == earner.id,
      )
      .toList();

  /// Every task the signed-in customer posted, for the task tracker.
  List<PasuyoTask> get myPasuyoOrders {
    final list = db.pasuyoTasks
        .where((t) => t.customerId == passenger.id)
        .toList();
    list.sort((a, b) => b.id.compareTo(a.id));
    return list;
  }

  /// Fee split for the task currently being worked, null if none.
  FeeBreakdown? activePasuyoBreakdown;

  /// Fee split for the task just finished, for the receipt screen.
  FeeBreakdown? lastPasuyoBreakdown;

  EarnerProfile get earner => db.earner;

  /// Whether the signed-in earner will take [capability].
  ///
  /// This is the gate for Pasuyo work: an earner without `errands`/`deliveries`
  /// must never be offered a task, and a vehicle owner has no earner profile at
  /// all, so they cannot be offered one either.
  bool acceptsCapability(EarnerCapability capability) =>
      earner.accepts(capability);

  /// Turns one of the signed-in earner's capabilities on or off.
  ///
  /// Returns false when the change was refused - see
  /// `EarnerProfile.setCapability` - so the caller can explain why nothing
  /// moved instead of leaving a toggle that looks stuck.
  bool setEarnerCapability(EarnerCapability capability, bool enabled) {
    final changed = earner.setCapability(capability, enabled);
    if (changed) notifyListeners();
    return changed;
  }

  PassengerProfile get passenger => db.passenger;

  /// Posts a new errand as the signed-in customer.
  PasuyoTask postPasuyoTask({
    required PasuyoCategory category,
    required String title,
    required List<String> items,
    required String pickupBarangay,
    required String pickupPurok,
    required String pickup,
    required String dropoffBarangay,
    required String dropoffPurok,
    required String dropoff,
    required int budget,
    String note = '',
    bool bookedForSomeone = false,
    String recipientName = '',
    String recipientPhone = '',
  }) {
    final task = PasuyoTask(
      id: 'PT${DateTime.now().millisecondsSinceEpoch}',
      customerId: passenger.id,
      category: category,
      title: title,
      items: items,
      pickupBarangay: pickupBarangay,
      pickupPurok: pickupPurok,
      pickup: pickup,
      dropoffBarangay: dropoffBarangay,
      dropoffPurok: dropoffPurok,
      dropoff: dropoff,
      budget: budget,
      note: note,
      bookedForSomeone: bookedForSomeone,
      recipientName: bookedForSomeone ? recipientName : '',
      recipientPhone: bookedForSomeone ? recipientPhone : '',
    );
    db.pasuyoTasks.insert(0, task);
    notifyListeners();
    return task;
  }

  /// True while this helper still owes a delivery. [activePasuyoTask] is a
  /// single slot, so this also gates taking on more work.
  bool get hasActivePasuyoTask =>
      activePasuyoTask != null && activePasuyoTask!.isActive;

  /// True when the errand was posted by the account trying to accept it. One
  /// person being both customer and helper on the same errand is always a data
  /// mistake, so it is refused rather than rendered.
  bool isOwnCustomerTask(PasuyoTask task) => task.customerId == earner.id;

  /// Why [acceptPasuyoTask] turned an errand down, or null when it was claimed.
  PasuyoAcceptRefusal? acceptPasuyoTask(PasuyoTask task) {
    if (!task.isOpen) return PasuyoAcceptRefusal.notOpen;
    if (isOwnCustomerTask(task)) return PasuyoAcceptRefusal.ownCustomer;
    if (hasActivePasuyoTask) return PasuyoAcceptRefusal.alreadyHasTask;

    // Guarded, not assigned: only an available task may move to accepted, so a
    // stale card cannot claim an errand another helper already took. The
    // transition is attempted before helperId is set, so a refused accept
    // leaves no trace of this helper on the task.
    if (!task.advanceTo(PasuyoStatus.accepted)) {
      return PasuyoAcceptRefusal.notOpen;
    }
    task.helperId = earner.id;
    activePasuyoTask = task;
    activePasuyoBreakdown = FeeCalculator.breakdownFor(
      ServiceType.pasuyo,
      task.budget,
    );
    notifyListeners();
    return null;
  }

  /// Advances the active task one step along [PasuyoStatus]: available →
  /// accepted → going to pickup → at pickup → collected → delivering → arrived
  /// → delivered.
  ///
  /// The legal next status comes from the enum, so this cannot skip a step.
  /// Payment is released exactly once, on reaching [PasuyoStatus.delivered],
  /// which is the terminal state.
  void advancePasuyoTask(PasuyoTask task) {
    final next = task.nextStatus;
    if (next == null) return;
    if (!task.advanceTo(next)) return;
    if (next == PasuyoStatus.delivered) {
      final breakdown = FeeCalculator.breakdownFor(
        ServiceType.pasuyo,
        task.budget,
      );

      // The helper is paid the budget less SurGo's commission.
      db.earnerWalletBalance += breakdown.providerGets;
      _creditRiderEarnings(breakdown.providerGets);
      db.earnerTransactions.insert(
        0,
        WalletTransaction(
          id: 'rwt${DateTime.now().microsecondsSinceEpoch}',
          type: 'credit',
          title: 'Pasuyo · ${task.title}',
          amount: breakdown.providerGets,
          date: 'Just now',
          status: 'Completed',
        ),
      );
      PlatformLedger.instance.record(ServiceType.pasuyo, task.budget);

      lastPasuyoBreakdown = breakdown;
      activePasuyoTask = null;
      activePasuyoBreakdown = null;
    }
    notifyListeners();
  }

  /// Cancels the errand from wherever it is. A delivered errand is terminal and
  /// cannot be cancelled, so money already released cannot be clawed back by
  /// reopening the task.
  void cancelPasuyoTask(PasuyoTask task) {
    if (!task.cancelTask()) return;
    if (activePasuyoTask == task) {
      activePasuyoTask = null;
      activePasuyoBreakdown = null;
    }
    notifyListeners();
  }

  /// The customer rates a delivered task.
  void ratePasuyoTask(PasuyoTask task, int stars) {
    task.rating = stars;
    task.rated = true;
    notifyListeners();
  }

  /// Adds [amount] to the rider's seeded earnings roll-ups.
  ///
  /// The earnings screen derives its breakdown from trips and tasks, so those
  /// totals move on their own — but the "Earnings" tile on the rider home screen
  /// reads `earningsToday/Week/Month`, which are plain seed fields. Crediting a
  /// completed job has to update them too, or the tile stays frozen at the
  /// seeded figure after the rider has already been paid.
  void _creditRiderEarnings(int amount) {
    if (amount <= 0) return;
    db.earningsToday += amount;
    db.earningsWeek += amount;
    db.earningsMonth += amount;

    // Bump today's bucket in the 7-day chart, matched on the weekday label the
    // seed uses. If no bucket matches (the seed is older than a week), the chart
    // is simply left alone rather than inventing a day.
    final now = DateTime.now();
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final today = weekdays[now.weekday - 1];
    for (final bucket in db.dailyEarnings) {
      if (bucket.day == today) {
        bucket.amount += amount;
        return;
      }
    }
  }

  /// Owner counterpart to [_creditRiderEarnings]. The revenue screen rebuilds
  /// its rows from bookings, but the "Today" cards on the owner home and
  /// earnings screens read the seeded `ownerEarnings*` fields directly.
  void _creditOwnerEarnings(int amount) {
    if (amount <= 0) return;
    db.ownerEarningsToday += amount;
    db.ownerEarningsWeek += amount;
    db.ownerEarningsMonth += amount;
  }

  // ---- derived rider earnings ----
  //
  // RiderTripItem.fare is the fare the rider agreed to and keeps in full: a
  // ride's platform fee is charged to the customer on top of it and lives on
  // the ledger, so ride earnings need no share calculation at all. Pasuyo and
  // rental earnings are still derived from their gross through
  // [FeeCalculator], so a seeded history row and a live completion are taxed
  // at exactly the same rate.

  List<RiderTripItem> get completedTrips =>
      db.riderTrips.where((t) => t.status == 'Completed').toList();

  /// What the rider earns from rides: every completed fare, in full.
  int get netRideEarnings => completedTrips.fold(0, (sum, t) => sum + t.fare);

  /// What the rider actually earns from Pasuyo errands, after commission.
  int get netPasuyoEarnings => completedPasuyoTasks.fold(
    0,
    (sum, t) => sum + FeeCalculator.providerShare(ServiceType.pasuyo, t.budget),
  );

  /// Incentives and tips, from wallet entries explicitly tagged `kind: "bonus"`.
  /// Zero until a bonus is seeded — kept as its own line so the earnings
  /// breakdown has somewhere for promos to land later.
  int get bonusEarnings {
    var sum = 0;
    for (final entry in db.earnerTransactions) {
      if (entry.type == 'credit' && entry.kind == 'bonus') {
        sum += entry.amount;
      }
    }
    return sum;
  }

  /// Money the rider can withdraw right now: everything credited to the
  /// wallet and not yet paid out.
  String get availableEarningsLabel => Money.format(db.earnerWalletBalance);

  /// Earnings from the trip currently in progress, credited only on
  /// completion.
  int get pendingEarnings =>
      activeRide == null ? 0 : (activeRideBreakdown?.providerGets ?? 0);

  String get pendingEarningsLabel => Money.format(pendingEarnings);

  // ---- account settings ----
  AccountSettingsData get passengerSettings => db.passengerSettings;
  AccountSettingsData get earnerSettings => db.earnerSettings;

  void updatePassengerSettings(void Function(AccountSettingsData s) update) {
    update(db.passengerSettings);
    notifyListeners();
  }

  void updateRiderSettings(void Function(AccountSettingsData s) update) {
    update(db.earnerSettings);
    notifyListeners();
  }

  // ---- vehicle owner mode ----
  List<OwnerBookingRequest> get ownerBookingRequests => db.ownerBookingRequests;
  int get ownerEarningsToday => db.ownerEarningsToday;
  int get ownerEarningsWeek => db.ownerEarningsWeek;
  int get ownerEarningsMonth => db.ownerEarningsMonth;

  void respondToOwnerBooking(
    OwnerBookingRequest request, {
    required bool accepted,
  }) {
    request.status = accepted ? RentalStatus.accepted : RentalStatus.declined;
    if (accepted) {
      // Prefer the request's own vehicleId. Matching on name instead would mark
      // whichever same-named vehicle sorted first, which is how the wrong
      // listing gets taken off the market.
      final match = db.ownerVehicles.where(
        (v) =>
            v.id == request.vehicleId ||
            (request.vehicleId == null && v.name == request.vehicleName),
      );
      if (match.isNotEmpty) match.first.status = 'Rented';
    }
    notifyListeners();
  }

  // ---- vehicle owner fleet management ----
  void addOwnedVehicle(OwnedVehicle vehicle) {
    db.ownerVehicles.add(vehicle);
    notifyListeners();
  }

  /// Removes the seeded vehicle with [id].
  ///
  /// The fleet screen lists repository records now, and this stage never
  /// writes back, so a Supabase build sees no change; in mock mode the seed
  /// mutates in place and the cache re-reads the slot.
  void removeOwnedVehicleById(String id) {
    db.ownerVehicles.removeWhere((v) => v.id == id);
    notifyListeners();
  }

  void setOwnedVehicleStatusById(String id, String status) {
    for (final vehicle in db.ownerVehicles) {
      if (vehicle.id == id) vehicle.status = status;
    }
    notifyListeners();
  }

  // ---- vehicle owner wallet ----
  /// Requests a payout from the vehicle owner's wallet.
  ///
  /// The owner wallet is separate from the rider's, but the guards are the
  /// same: a zero or negative amount must never become a credit, and the
  /// configured minimum applies to every payout. Returns whether the payout
  /// was created.
  bool requestOwnerPayout(int amount, String method) {
    if (amount <= 0) return false;
    if (amount < db.payoutMinWithdrawal) return false;
    if (amount > db.ownerWalletBalance) return false;
    db.ownerWalletBalance -= amount;
    db.ownerTransactions.insert(
      0,
      WalletTransaction(
        id: 'owt${DateTime.now().microsecondsSinceEpoch}',
        type: 'payout',
        title: 'Payout to $method',
        amount: amount,
        date: 'Just now',
        status: 'Processing',
      ),
    );
    notifyListeners();
    return true;
  }
}
