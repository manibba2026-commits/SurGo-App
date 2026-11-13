# SurGo — Ride. Rent. Errand.

SurGo is a **Flutter prototype** of a multi-service mobility and delivery platform for
Tandag City, Surigao del Sur. It combines ride booking, vehicle rentals, and Pasuyo
errands behind **one account** that switches between three modes: **Passenger**,
**Rider/Helper**, and **Vehicle Owner**.

The screens can run on the mock JSON seed data in `assets/db/`, and they also run
against the hosted Supabase project: `main()` initializes the client with the
publishable key before the UI starts (see `lib/services/supabase_bootstrap.dart`).
With a signed-in hosted account the ride, rental and Pasuyo flows call Postgres
RPCs and read their lists through the repository layer, so both sides of a
transaction see the same rows. Hosted surfaces that have no server-side function
yet (wallet top-up/cash-out, saved places, adding fleet vehicles) say so instead
of replaying the seed as if it were real.

## Running it

```bash
flutter pub get
flutter run -d chrome      # web, easiest for a demo
flutter analyze            # verify it compiles before trusting any of it
flutter test               # service, settlement, seed and widget tests
```

The project URL and publishable key can be overridden at build time with
`--dart-define=SUPABASE_URL=...` and `--dart-define=SUPABASE_PUBLISHABLE_KEY=...`.
Never put the `sb_secret_` key or the database password in the app.

Requires Flutter 3.24+ (Dart 3.5+). Android, iOS, and desktop targets are also configured.

### Phone sign-in (Semaphore)

Supabase Auth generates and verifies the OTP. The `send-sms` Edge Function only
delivers that code through Semaphore when Supabase fires the Send SMS hook.
Deployment, secrets, dashboard setup and the real-SMS acceptance checklist live in
[supabase/functions/send-sms/README.md](supabase/functions/send-sms/README.md).
Semaphore and hook secrets stay server-side; none are used in Flutter.

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

A provider keeps **100% of their fare**. SurGo's revenue is a separate fee the
customer pays on top, priced in `lib/services/fee_calculator.dart` and mirrored by
the settlement functions in Postgres:

| Service | Customer-side platform fee |
|---------|----------------------------|
| Rides   | ₱2.00/km, clamped to a ₱5–₱30 band |
| Pasuyo  | flat ₱10.00 per errand (item costs pass through at cost) |
| Rentals | `clamp(₱20 + ₱10 × started days, ₱20, ₱150)`; a started day is any part of 24h and the first day always counts |

Every amount is an **integer number of centavos** — `₱180.50` is `18050` — so fee
arithmetic never touches a floating-point value and a split always re-adds to the
exact gross. `lib/services/money.dart` owns that convention: `Money.format` is the
only way an amount should be rendered, and `Money.tryParsePesos` is the only way a
peso amount the user typed becomes centavos.

Each receipt shows **Customer pays / Provider gets / SurGo keeps**, and the provider
column is the fare whole. In the mock build `PlatformLedger` accumulates completed
transactions and feeds the Profile → Platform Revenue screen; a hosted account sees
a note there instead, because its fees are recorded in Postgres and reviewed in the
Admin dashboard, where demo activity is reported separately.

Because the mock ledger only grows when a transaction actually completes, the
revenue it shows is the same money that moved the helper's balance a moment earlier.

## Data model

One shared ID scheme across two seeds. The database is split by domain, and
`assets/db/manifest.json` declares the load order — adding a domain means adding one file
there and one line in `pubspec.yaml`:

| File | Holds |
|------|-------|
| `config.json` | commission rates, currency, fare and payout rules |
| `users.json` | passenger, rider, vehicle owner, payment methods, contacts, settings |
| `locations.json` | city identity and saved places; barangays and landmarks come from the hosted catalog and Geoapify/OpenStreetMap |
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

### Hosted data

The hosted schema lives in `supabase/migrations/` (applied in filename order) with RLS on
every table and SECURITY DEFINER RPCs for anything that moves money or changes a
counterparty's state. The app never writes those tables directly; it calls the RPCs through
`SurgoWriteBackend.rpc` and re-reads the affected slot, so a refused step leaves the screen
on the server's answer instead of a local guess.

| Flow | Tables / RPCs |
|------|---------------|
| Accounts | `profiles`, `user_roles`, `provider_profiles`; admin account management and verification review |
| Rides | `ride_requests`, `ride_status_events`, `ride_locations`, rider presence; create → assign → accept → start → complete, priced server-side |
| Rentals | `rental_bookings`; request → owner decision → active → returned → completed, with an overlap refusal and the fixed-addon fee |
| Pasuyo | `service_requests`, `service_request_items`, `service_status_events`; post → accept → pick up → deliver, with item actuals saved by the assigned helper |
| Money | `wallet_accounts`, `wallet_transactions`, `service_transactions`, `cash_fee_remittances` |
| Reviews | `verification_applications`, `verification_documents`, approval gate and document locking |

Rows created by the demo seeder carry an `is_simulated` marker (and simulated presence is
flagged on the presence row), so the Admin dashboard can report demo activity apart from
real transactions. The SQL suite at `supabase/tests/` builds a fresh database from the
migrations, loads the seed, and runs the RLS, constraint, pricing, settlement and lifecycle
tests — `node supabase/tests/run.mjs`.

## Project layout

```text
lib/
  admin/       the Admin dashboard screens
  auth/        session handling, demo PIN and phone sign-in
  data/        seed models (db_models.dart), loader (db_service.dart)
  repositories/ Supabase and mock implementations of every read and write
  screens/     one file per screen
  services/    fee_calculator.dart (fee math + PlatformLedger),
               money.dart (centavos formatting and parsing),
               location_service.dart (GPS)
  state/       app_state.dart (session + mock actions), domain_cache.dart
               (repository-backed reads the screens share)
  theme/       colors and dark theme
  widgets/     shared components, live map, stepper, repository states
```

`AppState` still holds the mock build's in-memory state, and a signed-out demo resets
to seed data on reload. A signed-in hosted account keeps its session across launches
and reads its own rows from Postgres. A screen that has both paths branches on
`AppState.usesHostedIdentity`; the seed path is never used as a stand-in for a
hosted write.

## Known gaps

- Hosted wallet top-up and cash-out are not enabled; the wallet shows settled
  transactions and says so when you tap the action.
- Saved places, favourites, payment methods, emergency contacts and adding fleet
  vehicles are still seed-only, and are hidden for signed-in hosted accounts.
- A hosted trip's rider GPS is not streamed to the passenger's live-trip map yet;
  demo riders use the simulated position stored in Postgres.
- `geolocator` has limited web support — live location is best-effort on Chrome,
  and the maps fall back to Tandag City centering when a fix isn't available.