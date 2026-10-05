import 'dart:async';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../services/fee_calculator.dart';

enum UserMode { passenger, rider, vehicleOwner }

/// Everything here lives only in memory for the lifetime of the app run.
/// There is no backend, no local storage, no network — purely a UI
/// simulation of what SurGo would look and feel like. Seed data is loaded
/// once from assets/db/mock_database.json via DbService, and every "write"
/// (accepting a ride, adding a saved place, topping up a wallet, etc.) just
/// mutates these in-memory lists and calls notifyListeners().
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
        route: '${trip.pickup} → ${trip.dropoff}',
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
  // Request Rental, shows up as a card on the Home tab, and — after a
  // simulated 10s owner-approval delay — flips to "Active" in place.
  RentalBooking? activeRentalBooking;
  Timer? _rentalApprovalTimer;

  RentalBooking requestRental({
    required String vehicleName,
    required String vehicleType,
    required IconData icon,
    required String ownerName,
    required String ownerInitials,
    required String pickupLabel,
    required String returnLabel,
    required int days,
    required int totalFare,
  }) {
    _rentalApprovalTimer?.cancel();
    final booking = RentalBooking(
      id: 'rb${DateTime.now().microsecondsSinceEpoch}',
      vehicleName: vehicleName,
      vehicleType: vehicleType,
      icon: icon,
      ownerName: ownerName,
      ownerInitials: ownerInitials,
      pickupLabel: pickupLabel,
      returnLabel: returnLabel,
      days: days,
      totalFare: totalFare,
      status: 'Pending',
      requestedAt: DateTime.now(),
    );
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

    _rentalApprovalTimer = Timer(const Duration(seconds: 10), () {
      if (activeRentalBooking?.id != booking.id) return; // cancelled/replaced
      booking.status = 'Active';
      final match = db.rentalHistory.where((r) => r.id == booking.id);
      if (match.isNotEmpty) {
        final i = db.rentalHistory.indexOf(match.first);
        db.rentalHistory[i] = RentalHistoryItem(
          id: booking.id,
          vehicleName: vehicleName,
          ownerName: ownerName,
          startDate: pickupLabel,
          endDate: returnLabel,
          totalFare: totalFare,
          status: 'Active',
        );
      }
      notifyListeners();
    });
    return booking;
  }

  void cancelRentalBooking() {
    _rentalApprovalTimer?.cancel();
    activeRentalBooking = null;
    notifyListeners();
  }

  /// Fee split for the rental just completed, for the owner's receipt.
  FeeBreakdown? lastRentalBreakdown;

  void completeActiveRental() {
    final booking = activeRentalBooking;
    if (booking == null) return;
    final breakdown =
        FeeCalculator.breakdownFor(ServiceType.rental, booking.totalFare);
    final match = db.rentalHistory.where((r) => r.id == booking.id);
    if (match.isNotEmpty) {
      final i = db.rentalHistory.indexOf(match.first);
      db.rentalHistory[i] = RentalHistoryItem(
        id: booking.id,
        vehicleName: booking.vehicleName,
        ownerName: booking.ownerName,
        startDate: booking.pickupLabel,
        endDate: booking.returnLabel,
        totalFare: booking.totalFare,
        status: 'Completed',
      );
    }
    db.ownerWalletBalance += breakdown.providerGets;
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
      .where((t) => t.status == 'completed' && t.helperId == rider.id)
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

  /// A helper claims an open task.
  void acceptPasuyoTask(PasuyoTask task) {
    if (!task.isOpen) return;
    task.helperId = rider.id;
    task.status = 'accepted';
    activePasuyoTask = task;
    activePasuyoBreakdown =
        FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);
    notifyListeners();
  }

  /// Advances the active task to its next status: posted → accepted →
  /// purchasing → delivering → completed.
  void advancePasuyoTask(PasuyoTask task) {
    final next = task.nextStatus;
    if (next == null) return;
    task.status = next;
    if (next == 'completed') {
      final breakdown =
          FeeCalculator.breakdownFor(ServiceType.pasuyo, task.budget);

      // The helper is paid the budget less SurGo's commission.
      db.riderWalletBalance += breakdown.providerGets;
      db.riderTransactions.insert(
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

  void cancelPasuyoTask(PasuyoTask task) {
    task.status = 'cancelled';
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

  /// Incentives and tips. Zero until seeded — kept as its own line so the
  /// earnings breakdown has somewhere for promos to land later.
  int get bonusEarnings {
    var sum = 0;
    for (final entry in db.riderTransactions) {
      if (entry.type == 'credit' && entry.title.toLowerCase().contains('bonus')) {
        sum += entry.amount;
      }
    }
    return sum;
  }

  /// Money the rider can withdraw right now: everything credited to the
  /// wallet and not yet paid out.
  String get availableEarningsLabel => '₱${db.riderWalletBalance}';

  /// Earnings from the trip currently in progress, credited only on
  /// completion.
  int get pendingEarnings =>
      activeRide == null ? 0 : (activeRideBreakdown?.providerGets ?? 0);

  String get pendingEarningsLabel => '₱$pendingEarnings';

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
    request.status = accepted ? 'Accepted' : 'Declined';
    if (accepted) {
      final vehicle = db.ownerVehicles.where((v) => v.name == request.vehicleName);
      if (vehicle.isNotEmpty) vehicle.first.status = 'Rented';
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
