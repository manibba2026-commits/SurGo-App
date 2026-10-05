# SurGo — Ride. Rent. Errand.

SurGo is a **Flutter prototype** of a multi-service mobility and delivery platform for
Tandag City, Surigao del Sur. It combines ride booking, vehicle rentals, and Pasuyo
errands behind **one account** that switches between three modes: **Passenger**,
**Rider/Helper**, and **Vehicle Owner**.

The app runs entirely offline on mock JSON seed data — there is no backend, no
network calls, and no authentication. Its purpose is to demonstrate the UI, navigation,
workflows, map experience, and the platform's revenue model end to end.

## Running it

```bash
flutter pub get
flutter run -d chrome      # web, easiest for a demo
flutter analyze            # verify it compiles before trusting any of it
```

Requires Flutter 3.24+ (Dart 3.5+). Android, iOS, and desktop targets are also configured.

## Modes and features

### Passenger — Home / Activity / Wallet / Profile

Ride booking (pickup + destination, vehicle choice, fare/distance/ETA), rider matching,
live trip tracking, trip completion and rating, vehicle rental browsing and booking,
assisted booking for someone else, **Pasuyo** errands (post, track, confirm, rate),
wallet with top-ups and transaction history, and a platform revenue dashboard.

### Rider / Helper — Home / Trips / Earnings / Profile

Online/offline status, incoming ride requests, accept/reject, active ride, live map,
ride history, vehicle documents, **Nearby Pasuyo** errands with accept and a progress
stepper (posted → accepted → purchasing → delivering → completed), and earnings broken
down by Rides / Pasuyo / Bonus with a Withdraw action.

### Vehicle Owner — Home / Bookings / Earnings / Profile

Owned vehicle list, rental pricing and availability, booking requests, accept/manage,
active rentals, rental earnings and history, and a map of listed vehicles.

## Pasuyo

Pasuyo is the errands-on-demand line: a customer posts what they need, a nearby helper
accepts it, buys and delivers it, and both sides see the same fee split. Five tasks are
seeded in `assets/db/mock_database.json` so the flow is demonstrable on first launch.

## The fee model

Every transaction is priced through `lib/services/fee_calculator.dart` — one place, so
receipts, rider earnings, and the revenue screen can never disagree:

| Service | SurGo commission |
|---------|------------------|
| Rides   | 10% |
| Pasuyo  | 15% |
| Rentals | 10% |

Each receipt shows **Customer pays / Provider gets / SurGo keeps**. `PlatformLedger`
accumulates every completed transaction and feeds the revenue screen (Profile →
Platform Revenue), which reports total commission, commission by service, a 7-day
chart, and the blended take rate.

Because the ledger only grows when a transaction actually completes, the platform
revenue on screen is the same money that moved the helper's balance a moment earlier.

## Data model

Two seed assets, one shared ID scheme:

- `assets/db/mock_database.json` — passengers, rider, vehicle owner, wallets, history,
  earnings, Pasuyo tasks, locations.
- `assets/data/surgo_map_v1_mock_data.json` — map entities (riders, passengers, rental
  vehicles, ride requests) for the `flutter_map` views.

Canonical IDs are shared across both: `P001`–`P005` passengers, `R001`–`R005` riders,
`RQ001`–`RQ005` ride requests, `RV001`–`RV004` rental vehicles, `PT001`–`PT005` Pasuyo
tasks. Every foreign key resolves on both sides, so a ride request's passenger is the
same person the map shows.

The signed-in user occupies the first slot in each namespace — passenger `P001`, rider
`R001`, vehicle owner `VOW-77213` — so seeded history belongs to them. `test/seed_ids_test.dart`
guards this: it asserts the profile ids appear in the seeded foreign keys and that every
Pasuyo customer/helper resolves to a real map entity. Changing a profile id without
repointing the seed data silently empties the Pasuyo tracker and rider earnings.

## Project layout

```text
lib/
  data/        seed models (db_models.dart), loader (db_service.dart)
  screens/     one file per screen
  services/    fee_calculator.dart (commission math + PlatformLedger),
               location_service.dart (GPS)
  state/       app_state.dart — in-memory ChangeNotifier singleton
  theme/       colors and dark theme
  widgets/     shared components, live map, stepper
```

`AppState` is the single source of truth at runtime and mutates in memory only. A page
refresh resets the app to seed data — there is no persistence layer yet.

## Known gaps

- No persistence: state resets on reload.
- No real authentication; login and OTP screens are UI only.
- `geolocator` / `permission_handler` have incomplete web support — location degrades
  on Chrome, and the maps fall back to Tandag City centering.
- Sugo AI (natural-language request parsing) is not implemented yet.