# SurGo — Detailed README & System Audit

> **Flutter prototype · 3 roles · offline seed data · in-app commission ledger**  
> Audited: 6 Nov 2026 · `lib/`: **72 Dart files / ~17,006 lines** · `test/`: **14 files / ~183 test cases**

---

## 1. What SurGo is

SurGo is an offline, front-end-only Flutter prototype for a multi-service mobility platform in Tandag City, Surigao del Sur:

| Mode | What the user can do |
|---|---|
| **Passenger** | Book rides, post/track Pasuyo errands, rent vehicles, manage wallet, favourites, saved places, emergency contacts |
| **Earner** | Act as rider and/or Pasuyo helper; manage capabilities, earnings, payouts, trips |
| **Vehicle Owner** | List and manage a fleet, receive/accept rental requests, track rental earnings |

There is **no backend, no database, no authentication server, and no persistence**. Everything is loaded once from JSON assets into singletons and mutated in memory. Restarting the app resets all state.

The app is deliberately built around two “real” pieces of logic:

1. **A commission ledger** — every completed ride, Pasuyo errand, and rental is split into “customer pays / provider gets / SurGo keeps”.
2. **State machines** — ride, errand, and rental lifecycles are enums with exactly one legal successor, so screens cannot skip steps.

---

## 2. Quick start

### Requirements

- Flutter **3.24+** stable (Dart `>=3.5.0 <4.0.0`)
- Chrome for web, or an Android/iOS emulator with location permissions enabled

### Commands

```bash
flutter pub get
flutter run -d chrome
```

```bash
# Quality gates
flutter analyze
flutter test
```

The app boots at `/` (splash), then `/login`. Seed credentials are in `assets/db/accounts.json`:

```
Phone:    +63 917 512 4809
Password: surgo123
```

You can also log in with the matching email. All seeded passwords are plaintext demo values.

---

## 3. Tech stack

| Dependency | Version | Use |
|---|---|---|
| `flutter_map` | `^7.0.2` | OpenStreetMap tiles |
| `latlong2` | `^0.9.1` | Lat/Lng maths |
| `geolocator` | `^13.0.1` | Live device GPS on map screens |
| `flutter_lints` | `^5.0.0` | Lint rules |
| `cupertino_icons` | `^1.0.8` | Icons |

No state-management package, no HTTP client, no local database. `AppState` is a `ChangeNotifier` singleton; `DbService` is a plain singleton; `PlatformLedger` is a separate `ChangeNotifier` singleton.

---

## 4. Repository map

```
SurGo-App-main/
├── lib/
│   ├── main.dart                 # MaterialApp + 22 named routes
│   ├── data/
│   │   ├── db_models.dart        # All typed seed models + enums (1,672 lines)
│   │   ├── db_service.dart       # Manifest loader, account activation, registration
│   │   ├── models.dart           # MockData: legacy hardcoded demo data
│   │   └── verification_policy.dart
│   ├── services/
│   │   ├── fee_calculator.dart   # FeeRates, FeeCalculator, FeeBreakdown, PlatformLedger
│   │   ├── money.dart            # Centavo formatting/parsing
│   │   └── location_service.dart # Geolocator wrapper
│   ├── state/
│   │   ├── app_state.dart        # All business logic (1,902 lines)
│   │   ├── ride_status.dart      # Ride lifecycle enum
│   │   ├── pasuyo_status.dart    # Errand lifecycle enum
│   │   ├── rental_status.dart    # Rental lifecycle enum
│   │   ├── rental_availability.dart
│   │   ├── ride_match.dart
│   │   ├── ride_chat.dart
│   │   └── geo.dart              # Haversine distance
│   ├── screens/                  # 45 screens
│   ├── widgets/                  # 9 shared widget files
│   └── theme/                    # Colors + dark theme
├── assets/
│   ├── db/                       # manifest.json + 12 domain JSON files
│   └── data/surgo_map_v1_mock_data.json
└── test/                         # 14 test files
```

### Seed files

| File | Contents |
|---|---|
| `assets/db/manifest.json` | Declares load order and file list |
| `config.json` | Commission basis points, currency, fare rules, payout rules |
| `users.json` | Passenger/earner/owner profiles, settings, notifications, favourites, contacts |
| `accounts.json` | Login accounts, capabilities, status |
| `applications.json` | Verification applications and documents |
| `locations.json` | City identity and saved places; barangays/puroks come from the hosted catalog, search from Geoapify/OpenStreetMap |
| `vehicles.json` | Owner fleet, vehicle documents, owner booking requests |
| `rides.json` | Ride requests + passenger ride history |
| `rentals.json` | Rental history |
| `pasuyo.json` | Errand tasks |
| `wallets.json` | Wallet balance + transaction log per profile |
| `earnings.json` | Rider roll-ups, daily earnings, payout history |
| `assets/data/surgo_map_v1_mock_data.json` | Map riders, rentals, passengers, ride requests |

---

## 5. Architecture

```
main.dart
  └─ MaterialApp / routes
       └─ Screens (StatelessWidget / StatefulWidget)
            ├─ ListenableBuilder(listenable: AppState.instance)
            ├─ ListenableBuilder(listenable: PlatformLedger.instance)
            └─ read/write via AppState
                 ├─ DbService.instance  (seed data, in-memory lists)
                 ├─ state/* enums       (lifecycle rules)
                 └─ FeeCalculator / PlatformLedger (money)
```

### Boot sequence

1. `DbService.load()` reads `manifest.json`.
2. Each declared JSON file is decoded into a `Map<String, dynamic>`.
3. Typed models are parsed into `DbService` lists/maps.
4. `FeeRates.configure()` applies `config.json` commission rates.
5. `AppState.init()` seeds `PlatformLedger` from completed history.
6. `activatePrimary()` points the signed-in slices at the primary seed profile.
7. `ready = true`; screens notify and render.

`DbService.load()` is idempotent (`_loaded` guard). `AppState.init()` is also idempotent (`ready` guard).

---

## 6. Data layer

### 6.1 Model catalogue (`lib/data/db_models.dart`)

**Shared / transactional**

- `NotificationItem`
- `WalletTransaction`
- `PaymentMethodItem`
- `SavedPlace`
- `FavoriteRider`
- `FavoriteVehicle`
- `EmergencyContactItem`
- `RideHistoryItem`
- `RentalHistoryItem`
- `RiderTripItem`
- `DailyEarning`
- `PayoutItem`

**Profiles / accounts**

- `PassengerProfile`
- `EarnerProfile`
- `VehicleOwnerProfile`
- `Account`
- `AccountStatus`
- `CapabilityType`
- `EarnerCapability`
- `EarnerAvailability`

**Verification**

- `VerificationDocumentItem`
- `VerificationApplication`
- `VerificationStatus`

**Locations / rides / vehicles**

- `Barangay`
- `PlaceItem`
- `RideRequestItem`
- `VehicleDocumentItem`
- `OwnedVehicle`
- `OwnerBookingRequest`

**Map**

- `MapPoint`
- `MapConfigData`
- `MapRider`
- `MapRentalVehicle`
- `MapPassenger`
- `MapRideRequest`

**Pasuyo**

- `PasuyoCategory`
- `PasuyoTask`

### 6.2 Legacy `MockData` (`lib/data/models.dart`)

Still used by some screens and constants:

- `RideOption` — `Tricycle ₱45`, `Motorcycle ₱30`
- `Driver matchedDriver`
- `RecentBooking`
- `RentalVehicle` — only 3 hardcoded rentals (`RV001`, `RV006`, `RV014`)
- `RentalBooking`
- `MockData` — passenger/rider/owner names, phone, wallet figures, ratings, recent bookings, rental list

> **This is a second source of truth.** The JSON seed has 14 rental vehicles; `MockData` exposes only 3. See bug **B5**.

---

## 7. `AppState` API reference

`lib/state/app_state.dart` is the single write surface for the app. All methods call `notifyListeners()`.

### 7.1 Session, account & modes

| Member | Purpose |
|---|---|
| `Future<void> init()` | Load DB and seed the ledger once |
| `bool ready` | True after init |
| `Account? currentAccount` | Signed-in account, in memory only |
| `bool get isSignedIn` | `currentAccount != null` |
| `UserMode mode` | Current active mode |
| `List<UserMode> get availableModes` | Modes unlocked by approved capabilities |
| `bool authorizedFor(CapabilityType)` | Capability check |
| `bool canApplyFor(CapabilityType)` | Eligibility check |
| `AuthResult login(identifier, password)` | Phone/email + password login |
| `RegisterResult register({...})` | Create local account |
| `void logout()` | Clear session and restore primary slices |
| `void switchToMode(UserMode)` | Guarded mode switch |
| `void switchToPassenger()` | Shorthand |
| `void switchToEarner()` | Shorthand |
| `void switchToVehicleOwner()` | Shorthand |
| `String get homeRoute` | `/home`, `/earner`, or `/owner` |

`AuthResult`: `ok`, `unknownAccount`, `wrongPassword`, `suspended`.  
`RegisterResult`: `ok`, `identifierTaken`.

### 7.2 Verification

| Member | Purpose |
|---|---|
| `verificationApplications` | All seeded + live applications |
| `myVerifications` | Applications for the current account |
| `verificationFor(CapabilityType)` | Current account’s application |
| `verificationStatusFor(CapabilityType)` | Approved / under review / etc. |
| `verificationSummaryLabel` | Human-readable aggregate |
| `startVerification(CapabilityType)` | Create a draft application |
| `markDocumentUploaded(appId, docId, {fileName})` | Tick a document |
| `submitVerification(appId)` | Refuse if docs missing, else submit |
| `processDueVerifications({DateTime? at})` | Advance review → approved |

`VerificationSubmitResult`: `ok`, `notFound`, `incomplete`, `notEligible`, `alreadyInReview`.

### 7.3 Rides

| Member | Purpose |
|---|---|
| `String pickupLabel` | Current pickup label |
| `String destinationLabel` | Current destination label |
| `RideOption selectedRide` | Selected ride product |
| `String get rideOptionName` | Product name |
| `void selectRide(RideOption)` | Choose product |
| `void setPickup(String)` / `setDestination(String)` | Update labels |
| `RideRequestItem createRideRequest({forPassenger})` | Create request, history row, chat thread |
| `MatchOutcome proposeRider(RideRequestItem)` | Simulate a rider proposal |
| `bool confirmRideMatch()` | Passenger confirms proposal |
| `void declineRideMatch()` | Passenger declines |
| `void riderAccepts(RideRequestItem)` | Rider accepts |
| `void respondToRequest(request, {accepted})` | Rider accept/decline from list |
| `void advanceRide()` | Rider advances one legal state |
| `void completeActiveRide()` | Settle trip, credit rider, record ledger |
| `void cancelActiveRide()` | Cancel and close chat |
| `void toggleRiderOnline()` | Online/offline |
| `List<RideRequestItem> get pendingRequests` | Rider incoming feed |
| `RideRequestItem? activeRide` | Current live trip |
| `FeeBreakdown? activeRideBreakdown` | Live receipt |
| `FeeBreakdown? lastRideBreakdown` | Last settled receipt |
| `double get estimatedDistanceKm` | Haversine-based estimate |
| `RideRequestItem? get liveRideRequest` | Non-terminal request for current account |

### 7.4 Ride chat

| Member | Purpose |
|---|---|
| `bool get canChatOnRide` | Chat gate |
| `ChatAvailability get chatAvailability` | Why chat is open/closed |
| `RideChatThread? get rideChat` | Current thread |
| `RideChatThread? openRideChat()` | Get thread, or null if closed |
| `ChatSendRefusal? sendRideMessage(String)` | Refuse empty/long/closed |

`ChatAvailability`: `open`, `notAcceptedYet`, `ended`.  
`ChatSendRefusal`: `empty`, `tooLong`, `tripNotAccepted`, `tripEnded`.

### 7.5 Wallet, payments & payouts

| Member | Purpose |
|---|---|
| `passengerWalletBalance` / `passengerTransactions` | Passenger wallet |
| `earnerWalletBalance` / `earnerTransactions` | Rider wallet |
| `ownerWalletBalance` / `ownerTransactions` | Owner wallet |
| `topUpPassengerWallet(amount, method)` | Simulated top-up |
| `withdrawEarnings(amount, method)` | Deduct earner balance, add payout |
| `requestRiderPayout(amount, method)` | Same as above, slightly different guard |
| `requestOwnerPayout(amount, method)` | Deduct owner balance |
| `paymentMethods` | Saved payment methods |
| `setDefaultPaymentMethod(PaymentMethodItem)` | Change default |
| `addPaymentMethod(PaymentMethodItem)` | Add |
| `removePaymentMethod(PaymentMethodItem)` | Remove |

### 7.6 Saved places, favourites, contacts, history

| Member | Purpose |
|---|---|
| `savedPlaces` / `addSavedPlace` / `removeSavedPlace` | Saved places |
| `favoriteRiders` / `removeFavoriteRider` | Favourite riders |
| `favoriteVehicles` / `removeFavoriteVehicle` | Favourite vehicles |
| `isFavoriteRiderName(String)` | Name check |
| `toggleFavoriteRiderByDriver({...})` | Add/remove rider |
| `isFavoriteVehicleName(String)` | Name check |
| `toggleFavoriteVehicleByListing({...})` | Add/remove rental |
| `emergencyContacts` / `addEmergencyContact` / `removeEmergencyContact` | SOS contacts |
| `rideHistory` / `addRideToHistory` | Passenger trip history |
| `rentalHistory` / `addRentalToHistory` | Rental history |
| `riderTrips` | Rider completed trips |

### 7.7 Rentals

| Member | Purpose |
|---|---|
| `RentalBooking? activeRentalBooking` | Current renter booking |
| `RentalListingState rentalListingState(String vehicleId)` | Listing pill state |
| `RentalAvailability rentalAvailability({vehicleId, pickupDate, returnDate})` | Date check |
| `RentalBooking requestRental({...})` | Create booking + 10s auto-approve |
| `void sendRentalRequest()` | requested → awaitingOwner |
| `void acceptRentalRequest()` | awaitingOwner → accepted |
| `void advanceRentalBooking({required bool pickup})` | accepted → active → returned |
| `void cancelRentalBooking()` | Cancel and release |
| `void completeActiveRental()` | returned → completed, pay owner |
| `FeeBreakdown? lastRentalBreakdown` | Owner receipt |

### 7.8 Pasuyo (errands)

| Member | Purpose |
|---|---|
| `pasuyoTasks` | All tasks |
| `nearbyPasuyoTasks` | Open tasks matching capabilities |
| `myPasuyoTasks` | Tasks assigned to current helper |
| `completedPasuyoTasks` | Delivered tasks |
| `myPasuyoOrders` | Tasks posted by current passenger |
| `livePasuyoOrders` | Non-terminal posted orders |
| `bool get hasActivePasuyoTask` | One-errand rule |
| `PasuyoTask postPasuyoTask({...})` | Publish errand |
| `bool isOwnCustomerTask(PasuyoTask)` | Self-accept guard |
| `PasuyoAcceptRefusal? acceptPasuyoTask(task)` | Claim with guards |
| `void advancePasuyoTask(task)` | One legal step |
| `void cancelPasuyoTask(task)` | Cancel |
| `void ratePasuyoTask(task, stars)` | Rate delivered errand |
| `FeeBreakdown? activePasuyoBreakdown` | Live receipt |
| `FeeBreakdown? lastPasuyoBreakdown` | Last receipt |

`PasuyoAcceptRefusal`: `notOpen`, `alreadyHasTask`, `ownCustomer`.

### 7.9 Earner & earnings

| Member | Purpose |
|---|---|
| `EarnerProfile get earner` | Current earner |
| `bool acceptsCapability(EarnerCapability)` | Work toggle |
| `bool setEarnerCapability(capability, enabled)` | Refuse turning all off |
| `earningsToday` / `earningsWeek` / `earningsMonth` | Seed + live roll-ups |
| `dailyEarnings` | 7-day chart data |
| `payoutHistory` | Payout log |
| `completedTrips` | Completed rider trips |
| `netRideEarnings` | Sum of ride fares minus commission |
| `netPasuyoEarnings` | Sum of errand budgets minus commission |
| `bonusEarnings` | Seed bonus |
| `availableEarningsLabel` | Formatted wallet |
| `pendingEarnings` / `pendingEarningsLabel` | Pending payouts |

### 7.10 Vehicle owner

| Member | Purpose |
|---|---|
| `ownerVehicles` | Fleet |
| `ownerBookingRequests` | Incoming rental requests |
| `ownerEarningsToday/Week/Month` | Rental roll-ups |
| `respondToOwnerBooking(request, {accepted})` | Accept/decline |
| `addOwnedVehicle(OwnedVehicle)` | Add to fleet |
| `removeOwnedVehicle(OwnedVehicle)` | Remove |
| `setOwnedVehicleStatus(vehicle, status)` | `Listed` / `Rented` / `Maintenance` |

### 7.11 Settings & locations

| Member | Purpose |
|---|---|
| `passengerSettings` / `earnerSettings` | Toggles |
| `updatePassengerSettings(update)` | Mutate + notify |
| `updateRiderSettings(update)` | Mutate + notify |
| `barangays` | Barangay/purok seed |
| `vehicleDocuments` | Compliance documents |
| `PassengerProfile get passenger` | Current passenger |

### 7.12 Ride rating state

| Member | Purpose |
|---|---|
| `int tripRating` | Default `4` |
| `Set<String> tripCompliments` | Selected chips |
| `setTripRating(int)` | Clamp 1–5 |
| `toggleCompliment(String)` | Toggle chip |

---

## 8. Services

### 8.1 `Money` (`lib/services/money.dart`)

All money in the app is **integer centavos**.

| Method | Example |
|---|---|
| `Money.format(18050)` | `₱180.50` |
| `Money.format(18050, symbol: false)` | `180.50` |
| `Money.signed(500)` | `+₱5.00` |
| `Money.pesos(180)` | `18000` |
| `Money.toPesos(18050)` | `180.5` |
| `Money.tryParsePesos('500')` | `50000` |

### 8.2 `FeeCalculator` / `FeeRates` / `FeeBreakdown`

- Rates in **basis points** (`1000 bps = 10%`).
- Defaults: ride `1000`, Pasuyo `1500`, rental `1000`.
- `config.json` overrides them at boot via `FeeRates.configure`.
- `FeeCalculator.providerShare(service, gross)` → provider cut.
- `FeeCalculator.surgoShare(service, gross)` → platform cut.
- `FeeCalculator.breakdownFor(service, gross)` → `FeeBreakdown`.
- `FeeBreakdown` guarantees `providerGets + surgoKeeps == customerPays`.
- Rounding is integer half-up on the whole peso.

### 8.3 `PlatformLedger`

Singleton `ChangeNotifier` seeded from completed history.

| Member | Purpose |
|---|---|
| `entries` | All ledger entries |
| `totalRevenue` | Sum of SurGo commission |
| `totalVolume` | Sum of gross |
| `totalPayouts` | Sum of provider shares |
| `transactionCount` | Entry count |
| `revenueFor(service)` / `volumeFor(service)` / `countFor(service)` | Per-service |
| `revenueByService` / `volumeByService` | Maps for UI |
| `revenueToday` | Today’s commission |
| `revenueLastDays(n)` | Chart data, oldest first |
| `record(service, gross, {id, timestamp})` | Record a completed transaction |
| `seedFromHistory({...})` | Seed once from completed trips/rentals/errands |
| `reset()` | Test/demo reset |

### 8.4 `LocationService`

`getCurrentLocation()` returns `MapPoint?`:

- Skips Geolocator on web (`kIsWeb`).
- Checks service enabled and permission.
- Requests permission if denied.
- 8-second time limit.
- Falls back to `null` on failure, letting maps use a default centre.

### 8.5 `VerificationPolicy`

- `submittedUnderReview = 2s`
- `underReviewApproval = 5s`
- Required docs per capability:
  - `rider`: driver’s licence, OR/CR
  - `vehicleOwner`: OR/CR, insurance, rental permit
  - `earner`: government ID, barangay clearance
  - `passenger`: none

---

## 9. State machines

### 9.1 Ride

```
searching
  → awaitingAcceptance
  → accepted
  → headingToPickup
  → arrived
  → inProgress
  → completed
```

`cancelled` is terminal. `next` is the only legal successor.  
Chat opens at `accepted` and closes at `completed`/`cancelled`.

### 9.2 Pasuyo

```
available
  → accepted
  → goingToPickup
  → atPickup
  → pickedUp
  → delivering
  → atCustomer
  → delivered
```

`cancelled` is terminal and has `stepIndex == -1`.

### 9.3 Rental

```
requested
  → awaitingOwner
  → accepted
  → active
  → returned
  → completed
```

`declined` / `cancelled` terminal.  
`returned` is when the vehicle goes back on the market; `completed` is when the owner is paid.

### 9.4 Rental availability

`checkRentalAvailability` refuses when:

- return date is before pickup,
- vehicle is `Maintenance`,
- a blocking booking overlaps,
- a pending owner request overlaps,
- vehicle is `Rented` and pickup is in the past.

Otherwise `canBook: true`.

---

## 10. Screens & features

### Authentication

| File | Features |
|---|---|
| `splash_screen.dart` | Brand wordmark, tagline, bootstrap timer → `/login` |
| `login_screen.dart` | Phone/email + password, error states, remember-me, forgot link, social shortcuts |
| `register_screen.dart` | Name/phone/email/password, client validation, social sign-up simulation |
| `forgot_password_screen.dart` | Identifier existence check, “link sent” state |
| `otp_screen.dart` | 6 boxes, auto-advance, 42s resend timer, verify |

### Passenger

| File | Features |
|---|---|
| `passenger_shell.dart` | 4-tab `PageView`: Home, Activity, Wallet, Profile |
| `home_screen.dart` | Greeting, search, quick actions, live ride/rental cards, recent bookings, map/notifications |
| `booking_screen.dart` | Pickup/destination, map preview, distance, ride products, fare, “Find Ride” |
| `matching_screen.dart` | Searching → proposed rider → confirm/decline |
| `live_trip_screen.dart` | Status progress, driver card, call/chat, share trip, SOS, complete |
| `rate_trip_screen.dart` | Stars, compliments, favourite rider, submit |
| `activity_screen.dart` | Ride/rental history, Pasuyo orders |
| `wallet_screen.dart` | Balance, top-up, cash-out, transaction history |
| `profile_screen.dart` | Profile, mode switcher, links to settings/wallet/verifications |
| `pasuyo_screen.dart` | Errand hub, category tiles, live orders |
| `pasuyo_post_screen.dart` | Create errand form |
| `pasuyo_task_screen.dart` | Task detail, stepper, accept/advance/rate |
| `rental_list_screen.dart` | Rental feed + category chips (see B5) |
| `rental_detail_screen.dart` | Vehicle detail, date range, availability, total, request |
| `active_rental_screen.dart` | Live rental status, cancel/return/complete |
| `passenger_map_screen.dart` | OSM map, riders/rentals filters, read-only pins |

### Earner

| File | Features |
|---|---|
| `rider_shell.dart` | 4-tab shell: Home, Trips, Earnings, Profile |
| `rider_home_screen.dart` | Online toggle, earnings tiles, incoming requests, active banner |
| `rider_trips_screen.dart` | Completed trips list with gross fares |
| `rider_earnings_screen.dart` | Today/week/month, 7-day chart, net earnings, payout history |
| `rider_profile_screen.dart` | Profile, mode switcher, capability toggles, documents, settings |
| `rider_map_screen.dart` | OSM map of nearby passenger requests, read-only |

### Vehicle Owner

| File | Features |
|---|---|
| `vehicle_owner_shell.dart` | 4-tab shell: Home, Vehicles, Bookings, Earnings, Profile (5 pages) |
| `vehicle_owner_home_screen.dart` | Fleet summary, pending requests, active rentals, earnings |
| `vehicle_owner_vehicles_screen.dart` | Fleet grouped by category, add vehicle, status management |
| `vehicle_owner_bookings_screen.dart` | Every owner booking request |
| `vehicle_owner_earnings_screen.dart` | Today/week/month rental income, accepted bookings |
| `vehicle_owner_profile_screen.dart` | Profile, mode switcher, wallet, documents, settings |
| `vehicle_owner_map_screen.dart` | OSM map of owner listings, read-only |

### Shared

| File | Features |
|---|---|
| `notifications_screen.dart` | Passenger/rider feeds, mark all read |
| `account_settings_screen.dart` | Push/email/SMS toggles |
| `payment_methods_screen.dart` | List/add/remove/default payment methods |
| `saved_places_screen.dart` | Saved places list |
| `favorites_screen.dart` | Favourite riders/vehicles |
| `emergency_contacts_screen.dart` | SOS contacts |
| `assisted_booking_screen.dart` | Book on behalf of someone else |
| `vehicle_documents_screen.dart` | Read-only compliance docs |
| `verification_screen.dart` | Capability applications, document upload, auto review |
| `revenue_screen.dart` | Platform revenue dashboard |
| `ride_chat_screen.dart` | Gated chat with closed-state explanations |

### Widgets

| File | Contents |
|---|---|
| `common.dart` | `SbCard`, `SbAvatar`, `SbTag`, `SbChip`, `SbField`, `SbIconButton`, `SbMapPlaceholder`, `SbPrimaryButton`, `SbOutlineButton`, `SbGoogleMark`, `SbEditableField`, `SbNavItem`, `SbBottomNav`, `SbEyebrow` |
| `app_shell.dart` | `SbTabHeader`, shared shell layout |
| `auth_widgets.dart` | `SbAuthScaffold`, `SbBrandLockup`, `SbAuthHeader`, `SbAuthError`, `SbAuthLink` |
| `mode_switcher.dart` | 3-mode dropdown, capability-gated |
| `surgo_map.dart` | `SurgoMap`, `SurgoMapMarker`, `surgoMarkerIcon`, live OSM tiles |
| `location_picker.dart` | Barangay → purok bottom sheet |
| `ride_request_card.dart` | Rider request card + active ride banner |
| `pasuyo_stepper.dart` | Errand progress stepper |
| `verification_tile.dart` | Verification status tile |

---

## 11. End-to-end flows

### 11.1 Passenger ride

1. `/login` → `login()` → `homeRoute`.
2. Home → `/booking`.
3. Pick pickup/destination, choose `RideOption`.
4. `createRideRequest()` → `searching`; inserts history row, creates chat thread.
5. `/matching` → `proposeRider()` → proposal → `confirmRideMatch()` → `awaitingAcceptance`.
6. `riderAccepts()` → `accepted`.
7. `/livetrip`; rider advances `accepted → headingToPickup → arrived → inProgress`.
8. Rider taps **Complete trip** → `completeActiveRide()`:
   - inserts `RiderTripItem`,
   - credits rider wallet + roll-ups,
   - records ledger,
   - closes chat,
   - clears `activeRide`.
9. Passenger rates → `/rate` → `addRideToHistory()`.

> The passenger-side “Complete Trip” currently breaks step 8 — see **B1**.

### 11.2 Pasuyo

1. Passenger posts errand → `available`.
2. Helper accepts → `accepted` (guards: not open, already has task, own customer).
3. Helper advances 6 steps to `delivered`.
4. Settlement: provider share credited, ledger recorded, task rated.
5. Passenger sees live/completed orders in Activity.

### 11.3 Rental

1. Passenger opens rental list → detail → picks dates.
2. `requestRental()` creates `requested`, inserts history, starts 10s timer.
3. Timer → `awaitingOwner` → `acceptRentalRequest()` → `accepted`.
4. Renter **Pick up** → `active`.
5. Renter **Return** → `returned`; vehicle status back to `Listed`.
6. Renter **Complete** → `completed`; owner wallet + roll-ups + ledger credited.
7. Owner sees requests in Bookings and responds via `respondToOwnerBooking`.

### 11.4 Verification

1. Profile → Verification.
2. `startVerification()` creates draft.
3. Upload required docs → `markDocumentUploaded()`.
4. Submit → `Submitted` → after 2s `Under review` → after 5s approved.
5. Approval grants capability and unlocks the mode.

### 11.5 Profile / settings

- Mode switcher only shows `availableModes`.
- Switching is gated by `authorizedFor`/approved capabilities.
- Settings mutate the account settings object and notify.

---

## 12. Money & commission model

### Rates (`config.json`)

| Service | Rate | BPS |
|---|---|---|
| Ride | 10% | 1000 |
| Pasuyo | 15% | 1500 |
| Rental | 10% | 1000 |

### Worked example

Ride fare `₱180.00` = `18000` centavos:

```
SurGo keeps = 18000 × 1000 / 10000 = 1800  → ₱18.00
Rider gets  = 18000 − 1800          = 16200 → ₱162.00
```

### Rules enforced

- `FeeBreakdown` asserts `providerGets ∈ [0, customerPays]`.
- `providerGets + surgoKeeps == customerPays`.
- Commission is only recorded on completed transactions.
- Rider/owner wallets receive **net** share only.
- `PlatformLedger` receives **commission** only.

### Roll-ups

Completing a ride or rental credits:

1. provider wallet balance,
2. `earningsToday/Week/Month` (or owner equivalents),
3. `PlatformLedger`.

This triple-write invariant is covered by `payout_rollup_test.dart`.

---

## 13. Routing (`lib/main.dart`)

| Route | Screen |
|---|---|
| `/` | `SplashScreen` |
| `/login` | `LoginScreen` |
| `/register` | `RegisterScreen` |
| `/forgot-password` | `ForgotPasswordScreen` |
| `/otp` | `OtpScreen` |
| `/home` | `PassengerShell` |
| `/earner` | `EarnerShell` |
| `/owner` | `VehicleOwnerShell` |
| `/booking` | `BookingScreen` |
| `/pasuyo` | `PasuyoScreen` |
| `/pasuyo_post` | `PasuyoPostScreen` |
| `/matching` | `MatchingScreen` |
| `/livetrip` | `LiveTripScreen` |
| `/ride_chat` | `RideChatScreen` |
| `/rental` | `RentalListScreen` |
| `/profile` | `ProfileScreen(embedded: false)` |
| `/rate` | `RateTripScreen` |
| `/map/passenger` | `PassengerMapScreen` |
| `/map/earner` | `EarnerMapScreen` |
| `/map/owner` | `VehicleOwnerMapScreen` |
| `/active_rental` | `ActiveRentalScreen` |

Screens **not** in the route table (pushed directly): `pasuyo_task`, `rental_detail`, `verification`, `revenue`, `account_settings`, `payment_methods`, `saved_places`, `favorites`, `emergency_contacts`, `notifications`, `assisted_booking`, `vehicle_documents`.

---

## 14. Testing

```bash
flutter test
flutter analyze
```

### Test files and coverage

| File | Cases | Covers |
|---|---:|---|
| `ride_match_test.dart` | 40 | Full ride lifecycle + illegal transitions |
| `ride_chat_test.dart` | 32 | Chat gate, refusals, closed thread |
| `seed_integrity_test.dart` | 21 | Manifest files, centavos, FKs, timestamps |
| `pasuyo_flow_test.dart` | 17 | Claim → advance → paid, refusals, rating |
| `fee_calculator_test.dart` | 14 | Money formatting, parsing, rate math, ledger |
| `payout_rollup_test.dart` | 11 | Wallet + roll-ups + ledger invariant |
| `auth_test.dart` | 10 | Login, role gating, registration, logout |
| `auth_ui_test.dart` | 8 | Login/register/reset UI navigation |
| `verification_test.dart` | 7 | Seeded apps, doc gating, auto-approval |
| `live_activity_test.dart` | 6 | Live request/order filtering |
| `seed_ids_test.dart` | 6 | Seed identity joins |
| `earner_capability_test.dart` | 5 | Capability gating, “can’t disable all” |
| `flow_wiring_widget_test.dart` | 5 | Button → state method wiring, money lands once |
| `widget_test.dart` | 1 | Splash branding + handoff |

**Total: ~183 test cases.** The existing `README.md` claim of “67 tests” is stale.

### Test conventions

- Singletons are shared across tests; each test snapshots and restores fields it touches.
- `TestWidgetsFlutterBinding.ensureInitialized()` is required before `db.load()`.
- Widget tests use stand-in routes so map tiles/GPS are not built.
- Tests pin behaviour, not security (plaintext seed passwords).

---

## 15. Missing functions / not implemented

### Authentication & account

- ❌ Real OTP verification — `OtpScreen._verify()` accepts **any** 6 non-empty digits.
- ❌ Password reset — `ForgotPasswordScreen` only checks the identifier exists and shows “link sent”; no token, no new password.
- ❌ Real social login/sign-up — buttons sign in `db.accounts.first` after a fake delay.
- ❌ Session persistence — refresh/restart signs out.
- ❌ Password hashing, rate limiting, lockout, email/SMS delivery.
- ❌ Account deletion, suspension UI, profile editing.
- ❌ Phone/email verification status.

### Payments

- ❌ Real top-up/cash-out — all simulated; no gateway, no payment intent.
- ❌ Payment method tokenisation — methods are display-only.
- ❌ Minimum withdrawal enforcement — `config.json.payouts.minWithdrawal` is never read.
- ❌ Payout status transitions — always `Processing`.
- ❌ Refunds, cancellation fees, receipts export.

### Rides

- ❌ Distance-based fare — `config.json.fare.baseFare/perKm/minimumFare` unused; fares are fixed per `RideOption`.
- ❌ Passenger-side trip completion settlement (see B1).
- ❌ Real driver matching/ETA — heuristic on mock riders.
- ❌ Live GPS tracking of the rider during a trip.
- ❌ SOS actually notifying contacts — snackbar only.
- ❌ Trip sharing — snackbar only.
- ❌ Cancellation policy/fees.
- ❌ Rider-side passenger history write on completion.

### Pasuyo

- ❌ Customer confirmation of delivery — helper’s “Delivered” is final.
- ❌ Photo/proof of purchase.
- ❌ Itemised receipt / reimbursement flow beyond `budget`.
- ❌ Multiple concurrent errands per helper (deliberately blocked).
- ❌ Scheduling.

### Rentals

- ❌ Owner-side return/completion action from `ActiveRentalScreen` (see B6).
- ❌ Live owner request list connected to `requestRental` (renter booking does not create an `OwnerBookingRequest`).
- ❌ Rental search — the search bar is a static `Container` (see B5).
- ❌ Availability calendar, blackout dates, deposits, damage reports.
- ❌ Dynamic fleet appearing in the rental feed.

### Maps

- ❌ Map markers do not trigger accept/decline, rental detail, or navigation.
- ❌ No route polyline, turn-by-turn, or fare-by-distance.
- ❌ Map data is fixed mock data; no live rider movement.
- ❌ Web GPS is skipped by design; no fallback location picker on the map.

### Notifications / chat

- ❌ Push/email/SMS delivery — toggles mutate local settings only.
- ❌ Rider chat replies — thread is seeded rider-only; rider has no compose UI.
- ❌ Realtime chat, read receipts, attachments, typing indicators.
- ❌ Chat persistence/history after trip end.

### Owner / admin

- ❌ Admin console, user management, dispute handling, refunds.
- ❌ Document expiry reminders.
- ❌ Payout reconciliation.
- ❌ Revenue export.

### Platform

- ❌ Persistence (SQLite/Drift/Isar/SharedPreferences).
- ❌ Backend API, auth, real-time, push.
- ❌ Localisation (fixed English/₱).
- ❌ Accessibility pass (semantics, contrast, large text).
- ❌ Error/loading states for asset load failures.
- ❌ Analytics/crash reporting.
- ❌ Feature flags/environment config.

---

## 16. Bugs & inconsistencies

### B1 — Passenger “Complete Trip” never settles the ride 🔴 Critical

`lib/screens/live_trip_screen.dart:311-315`

```dart
SbPrimaryButton(
  label: 'Complete Trip',
  onPressed: () =>
      Navigator.pushReplacementNamed(context, '/rate'),
)
```

It navigates to `/rate` **without** calling `AppState.completeActiveRide()`.

Consequences:

- no `RiderTripItem` created,
- rider wallet not credited,
- earnings roll-ups not updated,
- no `PlatformLedger` entry,
- chat not closed,
- `activeRide` remains `inProgress` after “completion”,
- home can still show a live trip.

Rider-side completion (`ride_request_card.dart:364`) does call `completeActiveRide()`, so the two paths disagree.

**Fix:** call `state.completeActiveRide()` before navigating, and make `RateTripScreen` read the resulting `lastRideBreakdown`/rider data.

### B2 — Rating screen uses legacy mock driver and duplicate history 🔴 High

`lib/screens/rate_trip_screen.dart:16,109-118`

- Reads `MockData.matchedDriver`, not the actual `activeRide` rider.
- Inserts a `RideHistoryItem` using `state.selectedRide.fare` (the selected product price), not the fare actually paid.
- Inserts another passenger history row even if `completeActiveRide()` later adds one.
- Resets rating to `4` after submit.

**Fix:** source driver/fare from the completed ride; insert one history row in one place (state layer).

### B3 — Wallet preset amounts are centavos, not pesos 🔴 High

`lib/screens/wallet_screen.dart:135,170`

```dart
final amounts = [100, 300, 500, 1000];   // displays ₱1.00, ₱3.00, ₱5.00, ₱10.00
final amounts = {500, 1000, 2000, balance}; // ₱5.00, ₱10.00, ₱20.00
```

Presets are passed straight to `topUpPassengerWallet` / `request*Payout` as centavos.

**Fix:** use `Money.pesos(100)`, `Money.pesos(300)`, etc., or define presets in centavos explicitly (`10000`, `30000`, ...).

### B4 — Duplicate payout APIs with different guards 🟠 Medium

- `withdrawEarnings` (`app_state.dart:1114`) guards `amount <= 0`.
- `requestRiderPayout` (`app_state.dart:1141`) only guards `amount > balance`.
- Wallet uses `requestRiderPayout`; rider earnings uses `withdrawEarnings`.
- Both insert a payout + transaction and deduct the same wallet.

**Fix:** keep one method, share the guard, and have both screens call it.

### B5 — Rental list uses legacy `MockData`, not the database 🟠 Medium

`lib/screens/rental_list_screen.dart:23-25`

```dart
final vehicles = activeFilter == 'All'
    ? MockData.rentalVehicles
    : MockData.rentalVehicles.where((v) => v.type == activeFilter).toList();
```

- Only **3** hardcoded rentals are shown, while the seed has **14** owner vehicles.
- Newly added owner vehicles never appear in the rental feed.
- The search bar is a static `Container` with no `TextField`/handler.
- Listing state is computed with `rentalListingState(v.id)`; IDs happen to match for the 3 mocks, but the source of truth is still split.

**Fix:** read `AppState.instance.ownerVehicles` (or a dedicated rental-listing collection) and filter bookable/available listings; wire the search field.

### B6 — Owner cannot settle a rental from the active-rental screen 🟠 Medium

`lib/screens/active_rental_screen.dart:254-256`

```dart
if (isOwnerMode)
  const SizedBox.shrink() // Owners don't complete rentals here...
```

Owner mode shows no action. `completeActiveRental()` only operates on `activeRentalBooking` (renter side) and owner completion is unreachable from that screen.

**Fix:** add owner actions (`mark returned`, `settle`) driven by the owner booking, or route owner bookings through a shared settlement method.

### B7 — Hardcoded commission labels 🟡 Low

`lib/screens/rider_earnings_screen.dart`

- “Net of 10% SurGo fee”
- “Net of 15% SurGo fee”

These do not read `FeeCalculator`. If `config.json` changes, the labels lie.

**Fix:** interpolate `FeeCalculator.rideCommissionPercent` / `pasuyoCommissionPercent`.

### B8 — Raw centavos in chart labels 🟡 Low

- `rider_earnings_screen.dart:53` → `Text('${d.amount}')`
- `revenue_screen.dart:109` → `Text('$amount')`

Charts show `18000` instead of `₱180.00`.

**Fix:** `Money.format(...)`.

### B9 — `config.json` fare/payout rules are dead data 🟡 Low

`baseFare`, `perKm`, `minimumFare`, `payouts.minWithdrawal`, `payouts.arrivalDays`, and `currency` are parsed only insofar as `commissionBps` is read; the rest are unused. Fares are fixed per product, and withdrawals have no minimum.

**Fix:** implement distance-based pricing and payout minimums, or remove the unused config to avoid misleading future maintainers.

### B10 — `respondToOwnerBooking` does not create a live renter booking 🟡 Low

Owner requests are seeded/independent. A renter’s `requestRental` creates `activeRentalBooking` + rental history, but does **not** append an `OwnerBookingRequest`. So the owner’s Bookings screen may not show a real renter-initiated booking.

**Fix:** create/update an `OwnerBookingRequest` in `requestRental`, and link both sides by booking id.

### B11 — Verification and auto-approval are timer simulations 🟡 Low

- `VerificationScreen` owns a 1s `Timer`.
- `VerificationPolicy` approves after 5s.
- `requestRental` auto-accepts after 10s.

These are demo behaviours, but they can fire while a user is mid-flow and are not durable. Consider a single simulation clock/service with explicit “demo mode” labeling.

### B12 — Legacy dual source of truth 🟡 Low

`MockData` still supplies identity, wallet figures, recent bookings, rental list, and the rating driver. Screens reading `MockData` can disagree with `DbService`/`AppState`.

**Fix:** delete `MockData` usage screen-by-screen; keep it only as a test fixture or remove it entirely.

### B13 — Vehicle status is stringly typed 🟡 Low

`OwnedVehicle.status` uses `'Listed'`, `'Rented'`, `'Maintenance'` as raw strings in `app_state.dart` and `rental_availability.dart`. A typo silently changes behaviour.

**Fix:** introduce a `VehicleStatus` enum with `fromJson`.

### B14 — Owner live rental income is not reflected in the owner bookings list 🟡 Low

`completeActiveRental()` credits `db.ownerWalletBalance` and `ownerEarnings*`, but does not update any `OwnerBookingRequest` row. The owner Earnings screen lists accepted `ownerBookingRequests`, so a live renter-completed rental may credit the balance without a corresponding booking card.

**Fix:** unify owner bookings and renter bookings into one model.

### B15 — Minor: `active_rental_screen.dart:50` odd indentation / unused-looking local

`const iconData = Icons.electric_rickshaw;` is declared inside `build` with unusual indentation. It is used later (`Icon(iconData)`), but the placement suggests a merge leftover. Not a runtime bug; worth cleaning.

---

## 17. Recommended improvements, prioritized

### P0 — Correctness / demo integrity

1. **Fix passenger ride completion** (B1): call `completeActiveRide()` and make `RateTripScreen` use the real ride.
2. **Fix wallet preset units** (B3): use `Money.pesos`.
3. **Remove duplicate history writes** (B2): one settlement path in `AppState`.
4. **Make rental feed read the DB** (B5): `ownerVehicles` + search handler.
5. **Add owner rental settlement** (B6).
6. **Unify payout APIs** (B4).

### P1 — Consistency / maintainability

7. Delete `MockData` usage from screens; move remaining constants into seed/tests.
8. Replace hardcoded fee labels and raw centavos (B7, B8).
9. Introduce `VehicleStatus` enum (B13).
10. Create a single `Booking` model for renter + owner sides (B10, B14).
11. Wire or remove the dead `config.json` rules (B9).
12. Add `flutter analyze` to CI and fix warnings.

### P2 — Missing product features

13. Real OTP + password reset (or clearly label them “demo”).
14. Persist state with SQLite/Drift/Isar; restore session on launch.
15. Distance-based fares + payout minimums.
16. Owner request → renter booking linkage.
17. Rider chat reply UI and message persistence.
18. Map marker actions (accept, view rental, navigate).
19. Proof-of-delivery photos for Pasuyo.
20. Rental calendar, deposits, damage reports.

### P3 — Production hardening

21. Backend API + auth (JWT/OAuth), password hashing, rate limits.
22. Payment gateway integration and webhook reconciliation.
23. Push notifications (FCM/APNs).
24. Observability: analytics, crash reporting, structured logs.
25. Accessibility and localisation (English/Filipino, `₱` formatting).
26. Security review for PII, location data, and document uploads.
27. Admin console for verification, disputes, payouts.
28. End-to-end/integration tests on a real device.

---

## 18. Production readiness checklist

| Area | Status |
|---|---|
| UI flows | ✅ Broad prototype coverage |
| Money math | ✅ Strong, tested |
| State machines | ✅ Guarded and tested |
| Seed integrity | ✅ Tested |
| Persistence | ❌ None |
| Backend | ❌ None |
| Auth security | ❌ Plaintext demo only |
| Payments | ❌ Simulated |
| Maps | ⚠️ Live tiles, mock markers |
| Chat | ⚠️ One-sided, seeded |
| Notifications | ❌ Local toggles only |
| Accessibility | ❌ Not audited |
| Localisation | ❌ English/₱ only |
| CI | ❌ No pipeline shown |
| Observability | ❌ None |

**Verdict:** excellent **demo/prototype** of a multi-service mobility platform with unusually careful money and lifecycle modelling. It is **not production-ready** until persistence, real auth, real payments, and backend integration are added.

---

## 19. Glossary

| Term | Meaning |
|---|---|
| **Pasuyo** | Errand/delivery task (buy, pick up, deliver) |
| **Earner** | Rider + Pasuyo helper role |
| **Capability** | Approved permission (`passenger`, `rider`, `earner`, `vehicleOwner`) |
| **BPS** | Basis points; `1000 bps = 10%` |
| **Centavo** | 1/100 peso; all money is integer centavos |
| **Ledger** | Platform commission records |
| **Roll-up** | `earningsToday/Week/Month` aggregates |
| **Listing state** | `available`, `rented`, `maintenance`, `unknown` |
| **Breakdown** | `customerPays` / `providerGets` / `surgoKeeps` |
