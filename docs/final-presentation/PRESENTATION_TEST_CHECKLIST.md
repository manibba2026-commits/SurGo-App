# SurGo — Presentation Test Checklist

Use this checklist at least **48 hours** before the defense and again **30 minutes** before going live. Tick every item; do not rely on memory.

## 1. Environment prerequisites

- [ ] Flutter 3.24+ / Dart 3.5+ installed (`flutter --version`).
- [ ] `flutter pub get` completes without errors.
- [ ] Chrome (or the target device/emulator) is available.
- [ ] Stable internet connection.
- [ ] Supabase project `lrhgktxmavnhjatqzbzr` is reachable.
- [ ] The machine's clock and timezone are correct.
- [ ] Screen mirroring / presentation mode is configured.
- [ ] Notifications, OS updates, and auto-sleep are disabled during the demo.
- [ ] A backup browser profile or incognito window is available for the admin dashboard.

## 2. Build and static checks

Run from the repository root:

```bash
flutter pub get
flutter analyze
flutter test
```

- [ ] `flutter analyze` has no errors (warnings are acceptable if known).
- [ ] `flutter test` passes, or any failures are understood and documented.
- [ ] A release/debug web build starts: `flutter run -d chrome`.

Admin dashboard:

```bash
cd lib/admin
npm install
npm run typecheck
npm run lint
npm test
npm run build
```

- [ ] Typecheck passes.
- [ ] Lint passes.
- [ ] Unit tests pass.
- [ ] Production build succeeds.
- [ ] `npm run dev` starts on port 3100.

> If a command is slow on the defense machine, run it the day before and keep the build output.

## 3. Data-mode decision

Choose one and write it down:

- [ ] **Recommended:** default mode (live Supabase Auth + local mock business data). No `SURGO_DATA_SOURCE` define.
- [ ] Read-only Supabase mode: `flutter run -d chrome --dart-define=SURGO_DATA_SOURCE=supabase`.

Do not mix modes during the demo.

- [ ] Confirm the mode by checking the app's diagnostics/description if available.
- [ ] If using Supabase mode, confirm the screens you plan to show read live data and that no write is expected.
- [ ] If using default mode, confirm the seed loads (Home shows data).

## 4. Account readiness (critical)

### 4.1 Verify the hosted auth roster

The only unbanned hosted account is expected to be:

| Field | Value |
| --- | --- |
| Email | Supplied out-of-band; the tools read it from `SURGO_REAL_USER_EMAIL` |
| User id | Supplied out-of-band; the tools read it from `SURGO_REAL_USER_ID` |
| Approved roles | `passenger`, `admin` |
| Password | Set (confirm the actual password out-of-band) |
| Phone | Null |

- [ ] The account is not banned.
- [ ] The password is known and tested in the admin dashboard.
- [ ] Phone OTP is not expected to work for this account unless a phone is linked.
- [ ] Email/password is used for the admin dashboard, not the Flutter app.

### 4.2 Decide how to demo rider/owner/helper modes

The real account (operator's admin account) has only `passenger` and `admin` roles **and an email identity only**, so it cannot sign into the Flutter app (which uses phone OTP). It is the admin-dashboard account. Use a separate, dedicated Flutter demo account that was registered by phone OTP and has a prepared session.

- [ ] **Option A (preferred, no hosted change):** unlock the modes in-session from the dedicated phone-registered Flutter demo account: **Profile → Verification**, start verification for Rider and Vehicle Owner, tap each demo document, submit, and wait ~5 seconds for the simulated auto-approval. The mode switcher then offers both modes. For Pasuyo, switch to Rider and enable **Errands**. The grant is session-scoped; a restart returns the account to passenger-only.
- [ ] **Option B (persisted roles):** an authorized person grants approved `earner` and `vehicle_owner` roles to the **dedicated phone-registered Flutter demo account** before the defense. This is a privileged data change and must be approved and recorded. Do not grant roles to the real account for this purpose; it cannot sign into Flutter anyway.
- [ ] **Option C:** demo passenger (Flutter demo account) + admin (real account) live, and use screenshots or a recorded clip for rider/owner/Pasuyo helper.
- [ ] **Option D:** create a new disposable **phone-registered** account and grant it roles through the admin/role process, if one exists.

Do not attempt to sign in with a seeded demo account; those auth rows are banned.

### 4.3 If modes were unlocked, verify

- [ ] Option A: the Verification screen shows Rider and Vehicle Owner as **Approved**.
- [ ] Option B: `user_roles` has approved `earner` and `vehicle_owner` for the **dedicated Flutter demo account** (not the real admin account).
- [ ] Flutter shows Rider and Owner mode entries after signing in to that account.
- [ ] The rider/owner screens render seeded data (the local seed is shared).
- [ ] A test ride/Pasuyo/rental can be completed without errors.

### 4.4 If Option C is chosen, prepare

- [ ] Screenshots or a 60–90 second screen recording of rider accept, active trip, owner booking, and Pasuyo helper.
- [ ] The recording is stored locally and does not depend on network.
- [ ] The narration explicitly says "recorded because the live account is passenger-only".

## 5. Flutter smoke test

Sign in and walk the app in the order you will present.

### 5.1 Launch and auth

- [ ] Splash screen appears.
- [ ] Login screen renders without overflow.
- [ ] Phone field accepts a valid PH number.
- [ ] Requesting a code shows a clear success or failure message.
- [ ] OTP screen accepts six digits.
- [ ] Resend cooldown counts down.
- [ ] Successful verification lands on the correct home.
- [ ] Sign-out returns to the login flow.

### 5.2 Passenger home and booking

- [ ] Home tiles are tappable: Ride, Rental, Pasuyo, Map, Assisted Booking.
- [ ] Booking screen loads seeded places.
- [ ] Pickup and destination can be changed.
- [ ] Vehicle options render.
- [ ] Fare breakdown shows provider fare, platform fee, and total.
- [ ] Requesting a ride opens Matching.
- [ ] Matching shows a proposal or a clear no-riders state.
- [ ] Confirming shows the waiting state, names the proposed rider, then opens the live trip automatically.
- [ ] Live trip renders map, driver card, and stepper.
- [ ] The action label follows the status: Start heading to pickup → I've arrived at pickup → Start the trip → Complete trip.
- [ ] Only Complete trip settles the ride; the earlier actions advance the status without paying out.
- [ ] Opening Live Trip with no active trip shows "No active trip".
- [ ] SOS dialog explains that contacts are required and that the alert is simulated.
- [ ] Completing the trip reaches the rating screen.
- [ ] The rating screen shows the same ride and driver that were just completed.
- [ ] Completing the trip adds exactly one history row (no duplicate from the rating screen).
- [ ] Recent Bookings shows only completed/cancelled rides, newest first, at most three.
- [ ] The unread notification badge appears only when the unread read returns a positive count.
- [ ] The completed ride appears in Activity.

### 5.3 Pasuyo

- [ ] Pasuyo hub loads in-progress and history tabs.
- [ ] "Post a Pasuyo" opens the form.
- [ ] A new task can be posted.
- [ ] The task appears in the hub.
- [ ] Helper mode shows nearby tasks.
- [ ] Accepting a task moves it to active.
- [ ] The stepper advances.
- [ ] Completion shows the rating prompt.
- [ ] The fee split is visible.

### 5.4 Rentals

- [ ] Rental list loads seeded vehicles.
- [ ] Vehicle detail shows price per day.
- [ ] Date pickers work.
- [ ] Total updates with the number of days.
- [ ] Invalid date ranges are blocked.
- [ ] A second live booking is blocked.
- [ ] Requesting a rental shows the pending state.
- [ ] After the simulated owner delay, the rental becomes active.
- [ ] Active rental screen renders.
- [ ] Owner bookings screen renders.

### 5.5 Wallet, notifications, profile

- [ ] Wallet balance renders (or a clear loading/error state).
- [ ] Transaction history renders from the role-specific wallet entries (or an honest empty state).
- [ ] Top-up opens and completes in-memory.
- [ ] Cash-out enforces the minimum.
- [ ] Notifications feed renders repository rows.
- [ ] Notification ages come from real timestamps (e.g. "2h ago"), not a hand-written seed label.
- [ ] Mark-one and mark-all-read update the UI in the default mock mode.
- [ ] If using Supabase data mode, confirm read state is not expected to persist after refresh.
- [ ] Profile name, rating, and roles render.
- [ ] The rider Home header shows the earner's name, rating, and member year (no auth UUID).
- [ ] The owner Home header shows the owner's name and member year, not an internal id.
- [ ] Saved places, payment methods, emergency contacts, and settings open.

### 5.6 Verification

- [ ] Verification screen lists capabilities.
- [ ] An eligible capability shows its document checklist.
- [ ] Submitting shows Submitted.
- [ ] After ~2 s it shows Under review.
- [ ] After ~5 s it shows Approved.
- [ ] The capability unlocks the mode.
- [ ] The screen states that the review is simulated.

## 6. Admin dashboard smoke test

- [ ] `/login` loads.
- [ ] Wrong password shows an error.
- [ ] Correct password lands on `/dashboard`.
- [ ] A non-admin account is rejected (if available to test).
- [ ] Dashboard stats render without a server error.
- [ ] `/verification` loads applications or a clear empty state.
- [ ] A document preview either opens a signed URL or reports "missing/unknown" honestly.
- [ ] `/users` loads.
- [ ] `/users/[id]` loads and shows the person's verification bundle.
- [ ] `/vehicles` loads.
- [ ] `/rides` loads.
- [ ] `/rides/[id]` loads.
- [ ] `/rentals` loads.
- [ ] `/pasuyo` loads.
- [ ] `/providers` loads.
- [ ] `/finance` loads; zero remittances is an acceptable empty state.
- [ ] `/reports` loads for 7/14/30/90 days.
- [ ] `/settings` loads; the audit-log panel says it is not readable by this session (42501) instead of returning a 500.
- [ ] Charts render (not blank).
- [ ] No unhandled server exception appears in the terminal.

### Admin action test (only with disposable data)

Do **not** approve a real application just to test. If a disposable application exists:

- [ ] Approve it with a reason.
- [ ] Confirm the status changes.
- [ ] Confirm the role is granted (if applicable).
- [ ] Confirm an audit row is written (service-role query).
- [ ] Reject a second disposable application with a reason.
- [ ] Confirm the reason is stored.

## 7. Hosted-data checks (read-only)

If you have SQL access, verify:

```sql
select count(*) from public.profiles;                 -- expected 20
select count(*) from public.ride_requests;            -- expected 19
select count(*) from public.rental_bookings;          -- expected 16
select count(*) from public.service_requests;         -- expected 20
select count(*) from public.service_transactions;     -- expected 29
select count(*) from public.notifications;            -- expected 25
select count(*) from public.wallet_transactions;      -- expected 79
select count(*) from public.verification_applications;-- expected 3
select count(*) from public.cash_fee_remittances;     -- expected 0
select count(*) from supabase_migrations.schema_migrations; -- expected 15
select count(*) from information_schema.tables
  where table_schema = 'public' and table_type = 'BASE TABLE'; -- expected 26
select has_table_privilege('authenticated','public.admin_audit_logs','SELECT'); -- expected false
```

- [ ] Counts match expectations or differences are explained.
- [ ] The real account exists and is unbanned.
- [ ] The real account's roles are known.
- [ ] Demo accounts are banned.
- [ ] The hosted ledger has 15 migrations; the local set has 19.
- [ ] `admin_audit_logs` is not readable by `authenticated` (42501 by design).
- [ ] `node supabase/tools/audit_hosted.mjs` reports 132 read-only checks passing.
- [ ] `node supabase/tools/verify_admin_reads.mjs` reports 52 admin-read checks passing.

## 8. Failure and recovery drills

| Failure | Recovery |
| --- | --- |
| SMS not delivered | Switch to a prepared session or a backup account; explain that OTP is rate-limited. |
| Supabase unreachable | Use the recorded clip/screenshots; explain the offline fallback. |
| App hot-reload breaks state | Restart the app; the seed reloads. |
| Matching shows no riders | Restart or choose a different seeded request; explain the no-riders state is intentional. |
| Admin login fails | Check password and network; use a prepared admin session in a second browser. |
| Admin page 500s | Capture the terminal error; fall back to the architecture/schema explanation. |
| Admin audit panel says unavailable | Expected: the `authenticated` role has no SELECT grant on `admin_audit_logs` (42501). Do not debug live. |
| Notification badge returns after refresh in Supabase mode | Expected: read state is not written back. Use the default mock mode for the demo. |
| Projector resolution causes overflow | Use a phone-sized window or device; test at 1280×720 and 1920×1080. |
| Mic/audio fails | Have the speaker notes printed or on a second screen. |

- [ ] Each recovery has been rehearsed at least once.
- [ ] A recorded backup exists for the riskiest flows.
- [ ] The backup does not depend on the venue network.

## 9. Thirty-minute pre-flight

- [ ] Laptop charged and plugged in.
- [ ] Internet tested.
- [ ] Flutter app launched and signed in.
- [ ] Admin dashboard launched and signed in (second window/profile).
- [ ] Seed data visible.
- [ ] Demo script open on a second screen or printed.
- [ ] Backup recording ready.
- [ ] Phone silenced; notifications off.
- [ ] Browser tabs cleaned; no secrets visible.
- [ ] Terminal font size increased for the audience.
- [ ] Timer for 8–12 minutes ready.

## 10. Sign-off

| Check | Owner | Time | Result |
| --- | --- | --- | --- |
| Build and tests | | | |
| Auth and roles | | | |
| Flutter flows | | | |
| Admin flows | | | |
| Backup recording | | | |
| Rehearsal | | | |

If any critical item fails, use the reduced live path in [LIVE_DEMO_SCRIPT.md](LIVE_DEMO_SCRIPT.md) rather than improvising.
