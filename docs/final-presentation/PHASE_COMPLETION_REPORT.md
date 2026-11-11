# SurGo — Phase Completion Report (Roadmap Phases A–E)

**Report date:** 11 November 2026
**Source of truth:** the working tree at `C:\Users\NITRO\Desktop\SurGo-App-main` (all changes uncommitted) and the hosted Supabase project, read read-only.
**Execution rules in force:** no commit, push, deploy, credential rotation, or hosted change without explicit approval. Hosted Supabase is the source of truth for real transactions. Mock data is never presented as a completed real transaction. Builds and unit tests are evidence, not proof that a workflow works end to end.

---

## 1. Status summary

| Phase | Status | What is done | What is gated |
| --- | --- | --- | --- |
| A — Make the demo alive | Local complete; hosted tail pending | Demo PIN auth, presence/dispatch, seeded attribution (`20261111160000` applied hosted), hosted-aware screens, live-trip resolution, assisted booking RPC path | Apply `20261111170000` (live attribution) and run two-account hosted E2E — both need approval |
| B — Complete core transactions | Local complete; hosted tail pending | RENT and HELP lifecycles server-side, fee formulas, settlement rows with snapshots, Pasuyo for-someone, shared wallet/earnings/notifications, synchronized role views | Apply `20261111180000` and run two-account hosted E2E — both need approval |
| C — Admin acceptance | Code and automated checks verified; manual pass blocked | Finance separation UI, review integrity, account management; 22 Node tests, typecheck, lint, production build pass | A real admin session against hosted data (operator credentials) |
| D — Devices and deployed web | Blocked | Project-wide static analysis and tests pass; share/consent behavior audited in code | Real Android devices, background location/battery, push, deployed web — environment not available |
| E — Security and release | Local audit complete; operator actions pending | RLS/policy/definer/bundle/secret audits (section 7) | Legacy service-role rotation, backup policy, privacy/terms/consent copy, OAuth redirect fix |

**No workflow above is claimed complete on the strength of a build or a widget test alone.**

---

## 2. Evidence snapshot (11 November 2026)

| Check | Command | Result |
| --- | --- | --- |
| Flutter analysis | `flutter analyze` | No issues found |
| Flutter tests | `flutter test` | 509 passed |
| SQL migrations and tests | `node supabase/tests/run.mjs` | PASS — 28 migrations, 17 SQL test files, fresh + reset |
| Admin unit tests | `npm test` in `lib/admin` | 22 passed |
| Admin typecheck | `npm run typecheck` | Clean |
| Admin lint | `npm run lint` | No warnings or errors |
| Admin build | `npm run build` | Compiled successfully |
| Flutter web release build | `flutter build web --release` | Built `build/web` (local artifact, not deployed) |
| Hosted migrations | read-only `peek_hosted.mjs` | Applied through `20261111160000_demo_activity_attribution`; two migrations pending |
| Hosted RLS | read-only `peek_hosted.mjs` | RLS on every public table; 42 public policies; 16 storage policies; no `anon` policy |

New in this pass: `test/stage2_rider_trips_profile_test.dart` proves the hosted Trips tab lists only the rows assigned to the signed-in rider and the hosted Profile tab names the signed-in account with read-only capabilities. The test installs a non-mock auth provider because `usesHostedIdentity` follows the installed provider, not a bare identity object. The hosted earner profile also gained the `Scaffold` its non-embedded route needs (`lib/screens/rider_profile_screen.dart`).

---

## 3. Phase A — Make the demo alive

**Implemented and locally verified**

- Phone OTP, Google sign-in, session restore, and provisioned demo phone + PIN identities (`lib/auth/`).
- Demo identities come from trusted `app_metadata.surgo_demo`; the client cannot mark itself demo.
- Simulated rider presence and dispatch: `20261111150000_rider_presence_and_dispatch.sql`, with offlined/online demo riders and race-safe acceptance.
- Seeded activity attribution: `20261111160000_demo_activity_attribution.sql` applied hosted; `is_simulated` separates demo history from real activity.
- Hosted-aware surfaces replace stale seed data rather than showing it:
  - Rider Home identity, incoming requests, presence, errands, wallet, notifications.
  - Trips and Profile tabs (`rider_trips_screen.dart`, `rider_profile_screen.dart`).
  - Live Trip resolution and counterparty naming (`live_trip_screen.dart`).
  - Wallet top-up/cash-out, vehicle listing edits, saved places, payment methods, favorites, emergency contacts, maps, notification read actions, and ride chat all show an explicit "not enabled for live accounts yet" notice instead of mock writes.
  - Assisted booking calls the hosted ride RPC with the passenger name.
- Demo UUIDs preserved; Junel Ramos's suspended state preserved; no replacement accounts created.

**Gated**

- `20261111170000_live_demo_activity_attribution.sql` is validated locally but not applied hosted. It adds BEFORE INSERT/UPDATE triggers so rows created after seeding inherit `is_simulated` from either party's trusted demo marker. Approval required.
- A hosted two-account ride E2E (passenger requests, rider accepts, status advances, history and earnings land) still needs approval to run against hosted data.
- The SMS hook remains gated on secrets approval; Google sign-in still fails `redirect_uri_mismatch` until the redirect allow-list is updated in the Google console.

---

## 4. Phase B — Complete core transactions

**Implemented and locally verified**

- `20261111180000_rental_pasuyo_lifecycle.sql` (1,108 lines, validated by `17_rental_pasuyo_lifecycle_test.sql`):
  - Rental lifecycle: requested → awaiting_owner → accepted → active → returned → completed, with decline/cancel; overlap refused with `tstzrange`; fare and fee terms snapshotted at request time.
  - Pasuyo lifecycle: available → accepted → going_to_pickup → at_pickup → picked_up → delivering → at_customer → delivered, plus cancel; item actuals; recipient details for errands booked for someone else.
  - Settlement writes one `service_transactions` row per booking with `pricing_snapshot`, provider payout equal to the fare, platform fee as a receivable.
  - Ride completion settles through a trigger, so status and money cannot diverge.
- Approved fee formulas implemented in both SQL and `lib/services/fee_calculator.dart` (`HostedFees`):
  - Provider keeps 100% of the fare; the platform fee is a customer add-on.
  - Rides: ₱2/km, clamped ₱5–₱30.
  - Pasuyo: ₱10 flat; item cost is pass-through.
  - Rentals: `clamp(₱20 + ₱10 × started days, ₱20, ₱150)`, started days = ceil(hours/24), minimum 1.
- Flutter repositories and screens call RPCs and re-read slots; no local computation of hosted amounts; no duplicate or out-of-order transitions in the client.
- Shared wallet/earnings/notifications update after hosted actions through cache refresh.

**Gated**

- `20261111180000` is not applied hosted (hosted schema stops at `20261111160000`). Impact and approval request in section 8.
- Two-account hosted E2E for RENT and HELP (owner/renter, customer/helper) still requires approval and separate authenticated accounts.

---

## 5. Phase C — Admin acceptance pass

**Verified**

- Simulated finance is separated from real finance in `lib/admin/src/lib/financeSeparation.ts` and the finance page; the old `simulatedFinance.ts` is removed.
- Verification review integrity: approval blocked while any required document is unreviewed; documents lock on decision; submission is race-safe.
- Account management: create/edit accounts, roles, suspension; server route uses the service-role key only on the server.
- Automated evidence: 22 Node tests, typecheck, lint, production build all pass.

**Not yet done (needs operator input)**

- A manual browser pass of every admin page against hosted data with a real admin session: dashboard, verification, users, vehicles, rides, rentals, Pasuyo, providers, finance, reports, settings.
- Confirming the audit-log panel shows the designed "unavailable" state under `authenticated` (SQLSTATE 42501).

---

## 6. Phase D — Real devices and deployed web

**Not started; environment unavailable**

- No Android hardware or deployed environment was used in this pass, so none of the following is claimed: GPS permission prompts, background location and battery behavior, real map tiles on device, push delivery, network-loss recovery, multi-device consistency, responsiveness, or performance. A release web bundle compiles locally (`flutter build web --release`), but it has not been served or exercised in a browser against hosted data.
- Known code-level limits to test first on a device: `geolocator` web support is best-effort, hosted riders do not stream GPS, and map surfaces fall back to Tandag City centering without a fix.

---

## 7. Phase E — Security and release readiness

**Local audit completed (read-only; no changes made)**

| Check | Result |
| --- | --- |
| Tables without RLS in `public` | 0 |
| Policies granted to `anon` (public or storage) | 0 |
| Storage buckets / object policies | 4 / 16 |
| `SECURITY DEFINER` functions | 60, all with `search_path = ''` |
| `SECURITY DEFINER` functions executable by `anon` | 0 |
| `SUPABASE_SERVICE_ROLE_KEY` in Flutter code or client bundles | None; server route and server-only module only |
| Tracked files containing JWTs, `sb_secret_`, `sbp_`, or credential-bearing connection strings | None (only documentation and a test asserting the publishable key is not secret) |

**Pending operator actions**

- Rotate the exposed legacy service-role credential, update Edge Functions, Admin env, and operator tools, then verify the old key is rejected and the new key works. This needs dashboard access and explicit approval; the credential must never appear in the repository or in chat.
- Confirm hosted backup retention and restore procedure; document the RPO/RTO the plan actually provides.
- Privacy policy, terms of service, and location-consent copy need operator/legal input; the repository cannot supply binding legal text.
- Google OAuth redirect allow-list update; SMS provider and hook secrets remain gated (already recorded).

---

## 8. Approval requests (nothing below has been applied)

### 8.1 Apply `20261111170000_live_demo_activity_attribution.sql`

- **What it changes:** creates `private.is_demo_identity(uuid)` (service-role metadata only), one trigger helper, and eight BEFORE INSERT/UPDATE triggers on `ride_requests`, `rental_bookings`, `service_requests`, `service_transactions`, `ride_status_events`, `service_status_events`, `ride_ratings`, `notifications`, plus a wallet trigger through `wallet_accounts`.
- **Effect:** any row created after seeding that involves a demo identity is flagged `is_simulated = true`; the flag only turns on, never off. Existing rows are not rewritten.
- **Impact on real data:** a real passenger matched to a demo rider is flagged simulated, which is intended. No pricing, role, or account change.
- **Local proof:** `16_live_demo_activity_attribution_test.sql` passes in the 28-migration harness.

### 8.2 Apply `20261111180000_rental_pasuyo_lifecycle.sql`

- **What it changes:** adds three nullable/defaulted columns to `service_requests` (`booked_for_someone`, `recipient_name`, `recipient_phone`) with a recipient check; replaces the rental and Pasuyo RPCs and adds ride-completion settlement triggers; fee helpers; notification helper; grants.
- **Effect:** hosted RENT and HELP become server-owned with settlement rows. No pricing policy rows are activated and no existing transaction is rewritten; settlement occurs only when a booking completes.
- **Impact on real data:** completed rentals and errands start producing `service_transactions` rows with snapshots. Ride completion starts settling through a trigger; repeated settlement is guarded by the existing unique constraints.
- **Local proof:** `17_rental_pasuyo_lifecycle_test.sql` passes in the same harness.

### 8.3 Run hosted end-to-end verification

- Use the provisioned demo accounts plus one separate real test account; exercise ride request → accept → complete, rental request → accept → return → complete, and Pasuyo post → accept → deliver, then verify wallet, earnings, history, notifications, and admin views. This writes real hosted rows and therefore needs approval.

### 8.4 Rotate the legacy service-role credential

- Requires dashboard access; after rotation, update Edge Function secrets, Admin environment, and operator tooling, then verify rejection/acceptance. Credentials stay out of the repository and chat.

---

## 9. What this report does not claim

- No two-account hosted workflow has been verified end to end in this pass.
- No simulated rider movement, GPS trail, payment, payout, or remittance is presented as real activity.
- Passing builds and tests are recorded as code evidence only.
- Phase D has no evidence because no device or deployed environment was used.
