import 'dart:async';

import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../services/fee_calculator.dart';
import '../services/money.dart';
import 'pasuyo_status.dart';
import 'rental_availability.dart';
import 'rental_status.dart';

enum UserMode { passenger, rider, vehicleOwner }

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
  ownCustomer,
}

/// Everything here lives only in memory for the lifetime of the app run.
/// There is no backend, no local storage, no network â€” purely a UI
/// simulation of what SurGo would look and feel like. Seed data is loaded
/// once from the manifest-driven files under `assets/db/` via [DbService], and
/// every "write" (accepting a ride, adding a saved place, topping up a
/// wallet, etc.) just mutates these in-memory lists and calls
/// notifyListeners().
class AppState extends ChangeNotifier {
  AppState._internal();
  static final AppState instance = AppState._internal();

  final DbService db = DbService.instance;
  bool ready = false;

  Future<void> init() async {
    if (ready) return;
    await db.load();
    PlatformLedger.instance.seedFromHistory(
      completedRideFares: db.riderTrips
          .where((t) => t.status == 'Completed')
          .map((t) => t.fare)
          .toList(),
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
    ready = true;
    notifyListeners();
  }

  // ---- account mode ----
  UserMode mode = UserMode.passenger;

  void switchToRider() {
    mode = UserMode.rider;
    notifyListeners();
  }

  void switchToPassenger() {
    mode = UserMode.passenger;
    notifyListeners();
  }

  void switchToVehicleOwner() {
    mode = UserMode.vehicleOwner;
    notifyListeners();
  }

  /// Central switcher used by the 3-mode dropdown menu.
  void switchToMode(UserMode m) {
    mode = m;
    notifyListeners();
  }

  // ---- booking draft ----
  String pickupLabel = 'Purok 3, Barangay Poblacion';
  String destinationLabel = 'SM Terminal, Downtown';
  List<RideOption> rideOptions = MockData.rideOptions;
  RideOption selectedRide = MockData.rideOptions.first;

  void selectRide(RideOption option) {
    selectedRide = option;
    notifyListeners();
  }

  void setPickup(String label) {
    pickupLabel = label;
    notifyListeners();
  }

  void setDestination(String label) {
    destinationLabel = label;
    notifyListeners();
  }

  // ---- rider / driver mode ----
  bool riderOnline = true;
  List<RideRequestItem> get pendingRequests => db.rideRequests;

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

  void respondToRequest(RideRequestItem request, {required bool accepted}) {
    db.rideRequests.remove(request);
    if (accepted) {
      activeRide = request;
      activeRideBreakdown = FeeCalculator.breakdownFor(
        ServiceType.ride,
        request.fare,
      );
    }
    notifyListeners();
  }

  /// The fee split for the trip just completed. Set by [completeActiveRide] so
  /// the receipt screen can show "Customer pays / You get / SurGo keeps"
  /// without recomputing. Null when there is no receipt to show.
  FeeBreakdown? lastRideBreakdown;

  void completeActiveRide() {
    if (activeRide == null) return;
    final trip = activeRide!;
    final breakdown = FeeCalculator.breakdownFor(ServiceType.ride, trip.fare);

    db.riderTrips.insert(
      0,
      RiderTripItem(
        id: 'rt${DateTime.now().microsecondsSinceEpoch}',
        passengerName: trip.passengerName,
        route: '${trip.pickup} â†’ ${trip.dropoff}',
        date: 'Just now',
        fare: trip.fare,
        distanceKm: trip.distanceKm,
        status: 'Completed',
        rating: 5,
      ),
    );

    // The rider is credited their net share only; SurGo's commission is
    // recorded on the ledger, never credited to the rider's wallet.
    db.riderWalletBalance += breakdown.providerGets;
    // ...and the home tile reads the roll-ups, so they have to move with it.
    _creditRiderEarnings(breakdown.providerGets);
    PlatformLedger.instance.record(ServiceType.ride, trip.fare);

    lastRideBreakdown = breakdown;
    activeRide = null;
    activeRideBreakdown = null;
    notifyListeners();
  }

  void cancelActiveRide() {
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
  List<NotificationItem> get passengerNotifications => db.passengerNotifications;
  List<NotificationItem> get riderNotifications => db.riderNotifications;

  int get unreadNotifications =>
      db.passengerNotifications.where((n) => !n.read).length;
  int get unreadRiderNotifications =>
      db.riderNotifications.where((n) => !n.read).length;

  void markNotificationRead(NotificationItem n) {
    n.read = true;
    notifyListeners();
  }

  void clearNotifications() {
    for (final n in db.passengerNotifications) {
      n.read = true;
    }
    notifyListeners();
  }

  void clearRiderNotifications() {
    for (final n in db.riderNotifications) {
      n.read = true;
    }
    notifyListeners();
  }

  // ---- wallet ----
  int get passengerWalletBalance => db.passengerWalletBalance;
  List<WalletTransaction> get passengerTransactions => db.passengerTransactions;
  int get riderWalletBalance => db.riderWalletBalance;
  List<WalletTransaction> get riderTransactions => db.riderTransactions;

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

  /// Moves money from the rider's available earnings into their wallet, or the
  /// other way round depending on which side is short. Kept as a distinct step
  /// so the earnings screen's Withdraw button has real behavior behind it.
  void withdrawEarnings(int amount, String method) {
    if (amount <= 0 || amount > db.riderWalletBalance) return;
    db.riderWalletBalance -= amount;
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
    db.riderTransactions.insert(
      0,
      WalletTransaction(
        id: 'rwt${DateTime.now().microsecondsSinceEpoch}',
        type: 'payout',
        title: 'Withdrawal to $method',
        amount: amount,
        date: 'Just now',
        status: 'Processing',
      ),
    );
    notifyListeners();
  }

  void requestRiderPayout(int amount, String method) {
    if (amount > db.riderWalletBalance) return;
    db.riderWalletBalance -= amount;
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
    db.riderTransactions.insert(
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

  // ---- rental booking simulation (passenger) ----
  // A passenger can only have one open rental request/active rental at a
  // time in this simulation. It starts as "Pending" the moment they tap
  // Request Rental, shows up as a card on the Home tab, and â€” after a
  // simulated 10s owner-approval delay â€” flips to "Active" in place.
  RentalBooking? activeRentalBooking;
  Timer? _rentalApprovalTimer;

  /// Every booking created this session, so availability checks can see the
  /// days this account already holds. Not seeded: these only exist because
  /// somebody asked for them.
  final List<RentalBooking> _rentalBookings = [];

  /// Every live booking this account holds, oldest first.
  List<RentalBooking> get myRentalBookings =>
      _rentalBookings.where((b) => !b.status.isTerminal).toList();

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
        bookings: _rentalBookings
            .where((b) => b.vehicleId == vehicleId)
            .toList(),
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
    _rentalApprovalTimer = Timer(const Duration(seconds: 10), () {
      if (activeRentalBooking?.id != booking.id) return; // cancelled/replaced
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

  /// Advances the live booking one step: requested â†’ awaiting owner â†’
  /// accepted â†’ out with the customer â†’ returned.
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

    final breakdown =
        FeeCalculator.breakdownFor(ServiceType.rental, booking.totalFare);
    _syncRentalHistoryStatus(booking, 'Completed');
    db.ownerWalletBalance += breakdown.providerGets;
    _creditOwnerEarnings(breakdown.providerGets);
    PlatformLedger.instance.record(ServiceType.rental, booking.totalFare);
    lastRentalBreakdown = breakdown;
    activeRentalBooking = null;
    notifyListeners();
  }

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
      db.favoriteRiders.add(FavoriteRider(
        id: 'fr${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        initials: initials,
        rating: rating,
        trips: trips,
        vehicleType: vehicleType,
        plate: plate,
      ));
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
      db.favoriteVehicles.add(FavoriteVehicle(
        id: 'fv${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        type: type,
        pricePerDay: pricePerDay,
        ownerName: ownerName,
      ));
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
  List<PasuyoTask> get nearbyPasuyoTasks {
    final list = db.pasuyoTasks.where((t) => t.isOpen).toList();
    list.sort((a, b) => b.id.compareTo(a.id));
    return list;
  }

  /// The task this helper is currently working, shown as a banner like the
  /// active ride is.
  PasuyoTask? activePasuyoTask;

  /// Tasks this helper has claimed but not yet delivered.
  List<PasuyoTask> get myPasuyoTasks =>
      db.pasuyoTasks.where((t) => t.helperId == rider.id && t.isActive).toList();

  List<PasuyoTask> get completedPasuyoTasks => db.pasuyoTasks
      .where((t) => t.status == PasuyoStatus.delivered && t.helperId == rider.id)
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

  RiderProfile get rider => db.rider;

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
  bool isOwnCustomerTask(PasuyoTask task) => task.customerId == rider.id;

  /// Why [acceptPasuyoTask] turned an errand down, or null when it was claimed.
  PasuyoAcceptRefusal? acceptPasuyoTask(PasuyoTask task) {
    if (!task.isOpen) return PasuyoAcceptRefusal.notOpen;
    if (isOwnCustomerTask(task)) return PasuyoAcceptRefusal.ownCustomer;
    if (hasActivePasuyoTask) return PasuyoAcceptRefusal.alreadyHasTask;

    // Guarded, not assigned: only an available task may move to accepted, so a
    // stale card cannot claim an errand another helper already took. The
    // transition is attempted before helperId is set, so a refused accept
    // leaves no trace of this helper on the task.
    if (!task.advanceTo(PasuyoStatus.accepted)) return PasuyoAcceptRefusal.notOpen;
    task.helperId = rider.id;
    activePasuyoTask = task;
    activePasuyoBreakdown =
        FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);
    notifyListeners();
    return null;
  }

  /// Advances the active task one step along [PasuyoStatus]: available â†’
  /// accepted â†’ going to pickup â†’ at pickup â†’ collected â†’ delivering â†’ arrived
  /// â†’ delivered.
  ///
  /// The legal next status comes from the enum, so this cannot skip a step.
  /// Payment is released exactly once, on reaching [PasuyoStatus.delivered],
  /// which is the terminal state.
  void advancePasuyoTask(PasuyoTask task) {
    final next = task.nextStatus;
    if (next == null) return;
    if (!task.advanceTo(next)) return;
    if (next == PasuyoStatus.delivered) {
      final breakdown =
          FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);

      // The helper is paid the budget less SurGo's commission.
      db.riderWalletBalance += breakdown.providerGets;
      _creditRiderEarnings(breakdown.providerGets);
      db.riderTransactions.insert(
        0,
        WalletTransaction(
          id: 'rwt${DateTime.now().microsecondsSinceEpoch}',
          type: 'credit',
          title: 'Pasuyo Â· ${task.title}',
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
  /// totals move on their own â€” but the "Earnings" tile on the rider home screen
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
  // RiderTripItem.fare is always the GROSS amount the customer paid. Provider
  // earnings are derived from it through FeeCalculator rather than stored, so
  // seeded history and live trips are taxed at exactly the same rate and a
  // change to the commission rate applies to both at once.

  List<RiderTripItem> get completedTrips =>
      db.riderTrips.where((t) => t.status == 'Completed').toList();

  /// What the rider actually earns from rides, after SurGo's commission.
  int get netRideEarnings => completedTrips.fold(
        0,
        (sum, t) => sum + FeeCalculator.providerShare(ServiceType.ride, t.fare),
      );

  /// What the rider actually earns from Pasuyo errands, after commission.
  int get netPasuyoEarnings => completedPasuyoTasks.fold(
        0,
        (sum, t) =>
            sum + FeeCalculator.providerShare(ServiceType.pasuyo, t.budget),
      );

  /// Incentives and tips, from wallet entries explicitly tagged `kind: "bonus"`.
  /// Zero until a bonus is seeded â€” kept as its own line so the earnings
  /// breakdown has somewhere for promos to land later.
  int get bonusEarnings {
    var sum = 0;
    for (final entry in db.riderTransactions) {
      if (entry.type == 'credit' && entry.kind == 'bonus') {
        sum += entry.amount;
      }
    }
    return sum;
  }

  /// Money the rider can withdraw right now: everything credited to the
  /// wallet and not yet paid out.
  String get availableEarningsLabel => Money.format(db.riderWalletBalance);

  /// Earnings from the trip currently in progress, credited only on
  /// completion.
  int get pendingEarnings =>
      activeRide == null ? 0 : (activeRideBreakdown?.providerGets ?? 0);

  String get pendingEarningsLabel => Money.format(pendingEarnings);

  // ---- account settings ----
  AccountSettingsData get passengerSettings => db.passengerSettings;
  AccountSettingsData get riderSettings => db.riderSettings;

  void updatePassengerSettings(void Function(AccountSettingsData s) update) {
    update(db.passengerSettings);
    notifyListeners();
  }

  void updateRiderSettings(void Function(AccountSettingsData s) update) {
    update(db.riderSettings);
    notifyListeners();
  }

  // ---- Tandag City locations (barangay + purok) ----
  List<Barangay> get barangays => db.barangays;

  // ---- vehicle documents ----
  List<VehicleDocumentItem> get vehicleDocuments => db.vehicleDocuments;

  // ---- vehicle owner mode ----
  List<OwnedVehicle> get ownerVehicles => db.ownerVehicles;
  List<OwnerBookingRequest> get ownerBookingRequests => db.ownerBookingRequests;
  int get ownerEarningsToday => db.ownerEarningsToday;
  int get ownerEarningsWeek => db.ownerEarningsWeek;
  int get ownerEarningsMonth => db.ownerEarningsMonth;

  void respondToOwnerBooking(OwnerBookingRequest request, {required bool accepted}) {
    request.status =
        accepted ? RentalStatus.accepted : RentalStatus.declined;
    if (accepted) {
      // Prefer the request's own vehicleId. Matching on name instead would mark
      // whichever same-named vehicle sorted first, which is how the wrong
      // listing gets taken off the market.
      final match = db.ownerVehicles.where((v) =>
          v.id == request.vehicleId ||
          (request.vehicleId == null && v.name == request.vehicleName));
      if (match.isNotEmpty) match.first.status = 'Rented';
    }
    notifyListeners();
  }

  // ---- vehicle owner fleet management ----
  void addOwnedVehicle(OwnedVehicle vehicle) {
    db.ownerVehicles.add(vehicle);
    notifyListeners();
  }

  void removeOwnedVehicle(OwnedVehicle vehicle) {
    db.ownerVehicles.remove(vehicle);
    notifyListeners();
  }

  void setOwnedVehicleStatus(OwnedVehicle vehicle, String status) {
    vehicle.status = status;
    notifyListeners();
  }

  // ---- vehicle owner wallet ----
  int get ownerWalletBalance => db.ownerWalletBalance;
  List<WalletTransaction> get ownerTransactions => db.ownerTransactions;

  void requestOwnerPayout(int amount, String method) {
    if (amount > db.ownerWalletBalance) return;
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
  }
}
