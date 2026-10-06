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
flutter test               # 67 tests: fee math, seed integrity, payout wiring
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
accepts it, buys and delivers it, and both sides see the same fee split. Twenty errands —
posted, accepted, in progress and completed — are seeded in `assets/db/pasuyo.json`, so the
whole flow is demonstrable on first launch without typing anything.

## The fee model

Every transaction is priced through `lib/services/fee_calculator.dart` — one place, so
receipts, rider earnings, and the revenue screen can never disagree:

| Service | SurGo commission |
|---------|------------------|
| Rides   | 10% |
| Pasuyo  | 15% |
| Rentals | 10% |

Rates are seeded from `assets/db/config.json` rather than hardcoded, and every amount is an
**integer number of centavos** — `₱180.50` is `18050` — so commission arithmetic never
touches a floating-point value and a split always re-adds to the exact gross.
`lib/services/money.dart` owns that convention: `Money.format` is the only way an amount
should be rendered, and `Money.tryParsePesos` is the only way a peso amount the user typed
becomes centavos.

Each receipt shows **Customer pays / Provider gets / SurGo keeps**. `PlatformLedger`
accumulates every completed transaction and feeds the revenue screen (Profile →
Platform Revenue), which reports total commission, commission by service, a 7-day
chart, and the blended take rate.

Because the ledger only grows when a transaction actually completes, the platform
revenue on screen is the same money that moved the helper's balance a moment earlier.

## Data model

One shared ID scheme across two seeds. The database is split by domain, and
`assets/db/manifest.json` declares the load order — adding a domain means adding one file
there and one line in `pubspec.yaml`:

| File | Holds |
|------|-------|
| `config.json` | commission rates, currency, fare and payout rules |
| `users.json` | passenger, rider, vehicle owner, payment methods, contacts, settings |
| `locations.json` | barangays, map landmarks, saved places |
| `vehicles.json` | owned fleet, vehicle documents, owner booking requests |
| `rides.json` | live ride requests and completed ride history |
| `rentals.json` | rental history |
| `pasuyo.json` | errands in every lifecycle state |
| `wallets.json` | one wallet per role, with its transaction history |
| `earnings.json` | rider and owner roll-ups, daily chart, payout history |

`assets/data/surgo_map_v1_mock_data.json` sits outside that manifest: it holds the map
entities (riders, passengers, rental vehicles, ride requests) the `flutter_map` views draw.

Canonical IDs are shared across both: `P001`–`P005` passengers, `R001`–`R005` riders,
`RQ001`–`RQ005` ride requests, `RV001`–`RV014` rental vehicles, `PT001`–`PT020` Pasuyo
tasks. Every foreign key resolves on both sides, so a ride request's passenger is the
same person the map shows.

The signed-in user occupies the first slot in each namespace — passenger `P001`, rider
`R001`, vehicle owner `VOW-77213` — so seeded history belongs to them. Changing a profile
id without repointing the seed data silently empties the Pasuyo tracker and rider earnings,
which is why the seed is covered by its own tests: `test/seed_ids_test.dart` guards the
profile ids against the seeded foreign keys, and `test/seed_integrity_test.dart` checks
that every manifest file loads, that IDs are unique within a collection, that money is in
centavos, that timestamps are real ISO times, and that both seeds describe the same fleet.
`test/payout_rollup_test.dart` and `test/pasuyo_flow_test.dart` then pin the behaviour that
is easiest to break quietly: the fee split, and the rule that completing a job moves the
provider's wallet, the earnings roll-ups and the platform ledger together.

## Project layout

```text
lib/
  data/        seed models (db_models.dart), loader (db_service.dart)
  screens/     one file per screen
  services/    fee_calculator.dart (commission math + PlatformLedger),
               money.dart (centavos formatting and parsing),
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