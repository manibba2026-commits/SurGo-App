# SurGo — Final Readiness Report

**Report date:** 9 November 2026
**Scope:** Documentation-only review of the repository working tree and hosted Supabase project. No application code, schema, data, roles, accounts, or configuration were changed.
**Evidence:** current repository code and tests, the Qoder working tree (latest observed edits on 2026-11-09 to `live_trip_screen.dart`, `matching_screen.dart`, `pasuyo_task_screen.dart`, `vehicle_owner_home_screen.dart`, and the new `test/live_trip_widget_test.dart`), read-only hosted SQL, and the maintenance notes in `supabase/README.md`. Qoder was still editing during the review, so this report describes the latest observed tree, not a commit that has been merged. Re-run the checks after Qoder stops.

---

## 1. Bottom line

SurGo is **ready to present as a prototype**, with conditions.

- The **user experience, authentication, schema, RLS, pricing logic, and audited admin design** are strong enough for a thesis defense.
- The **Stage 2 repository reads, the single ride-settlement/rating path, the `DomainCache` session-change fix, and the admin read/audit handling** are verified in code and tests.
- The **live demo is constrained by account readiness**, not by missing screens.
- The **business transaction layer is simulated**, and the presentation must say so.
- The **notification feed is a real read, but notification read state is mock-only**.
- The **admin dashboard is implemented and its suites pass, but it has not had a full manual browser pass** against the hosted project.
- The **hosted schema is behind the local migration set**; the financial ledger is not deployed.

**Recommended posture:** present the architecture and the honest prototype boundary with confidence, use a prepared Flutter session and a prepared admin session, and have a recorded backup for the role-specific flows.

---

## 2. Readiness scorecard

| Area | Readiness | Notes |
| --- | --- | --- |
| Documentation package | ✅ Ready | Ten documents plus index, synchronized to the reviewed working tree. |
| Flutter UI breadth | ✅ Ready | All three role shells and service flows exist. |
| Flutter static analysis | ✅ Verified | `flutter analyze`: no issues. |
| Flutter tests | ✅ Verified | `flutter test`: 428 passed on the latest observed tree; re-run if Qoder continues. |
| Live authentication (code) | ✅ Ready | Phone OTP, Google, session restore. |
| Live authentication (demo setup) | 🔶 Conditional | Phone account and session must be prepared before the defense. |
| Repository-backed reads | 🔶 Partial | Profiles, notifications, Recent Bookings, wallets, fleet, documents; many screens still read `AppState`. |
| Ride completion and rating | ✅ Verified | Live Trip advances status; one settlement path; rating reads the settled ride. |
| Matching handoff | ✅ Verified | Waiting state names the proposed rider; Live Trip opens automatically on acceptance. |
| `DomainCache` session change | ✅ Verified | Generation-based retirement and re-read; tests cover stale, repeated, and failed re-reads. |
| Business persistence | 🟠 Simulated | In-memory writes; reload resets. |
| Ride pricing | ✅ Ready | Platform fee implemented; integer centavos. |
| Pasuyo/rental pricing | 🔶 Unresolved | Legacy 15% / 10%; hosted policies empty. |
| Supabase schema | ✅ Ready (hosted subset) | 26 hosted tables; 30 local. |
| RLS and admin RPCs | ✅ Ready | Read-only baseline, audited RPCs. |
| Admin read model | ✅ Verified | Authenticated SELECT-only policies; no service-role browser key. |
| Admin audit-log boundary | ✅ Verified | `authenticated` has no SELECT grant (42501); settings renders unavailable. |
| Financial ledger | 🔶 Local only | Not applied to hosted. |
| Admin dashboard code | ✅ Verified | 10 Node tests, typecheck, lint, and production build pass. |
| Admin browser verification | 🟡 Needs verification | No full manual pass recorded. |
| Seed/demo data | ✅ Ready with caveats | Hosted counts verified; local inconsistencies remain. |
| Live demo | 🔶 Conditional | Depends on account roles and session. |
| Thesis content | 🔶 Researcher input needed | Literature, methodology, evaluation. |

---

## 3. Findings by classification

### 3.1 Verified complete

These are supported by code and a current check, not by a README claim.

**Stage 2 repository reads**

- Passenger and earner profile headers read through `DomainSlot.passengerProfile` / `DomainSlot.earnerProfile`.
- Notification feed and unread counts read through `passengerNotificationFeed`, `earnerNotificationFeed`, `unreadPassengerNotifications`, and `unreadEarnerNotifications`; ages use each record's real `createdAt` via `displayAge`.
- Recent Bookings reads `passengerRecentRides` via `fetchRideHistory`, lists only terminal rides (`completed`, `cancelled`), newest first, limit 3.
- Wallet balance and history read through separate balance and `passengerWalletEntries` / `earnerWalletEntries` / `ownerWalletEntries` slots.
- Owner fleet reads `ownerFleet`; vehicle documents read `ownerVehicleDocuments` through the owner's vehicles because `vehicle_documents` has no owner column.
- Evidence: `lib/state/domain_cache.dart`, `lib/screens/home_screen.dart`, `lib/screens/notifications_screen.dart`, `lib/screens/rider_home_screen.dart`, `lib/screens/wallet_screen.dart`, `lib/screens/vehicle_owner_home_screen.dart`, `lib/screens/vehicle_owner_vehicles_screen.dart`, `lib/screens/vehicle_documents_screen.dart`, and the `test/stage2_*_test.dart` files.

**B1/B2 ride settlement and rating**

- `live_trip_screen.dart` listens to `AppState`, shows an explicit no-active-trip state, and advances the ride through `RideStatus.next`; only the in-progress state calls `AppState.completeActiveRide()` before navigating to `/rate`.
- `rate_trip_screen.dart` reads `lastCompletedRide` and `lastCompletedRideDriver`, and updates the existing history row instead of adding a duplicate.
- Evidence: `lib/screens/live_trip_screen.dart`, `lib/screens/rate_trip_screen.dart`, `lib/state/app_state.dart`, `test/flow_wiring_widget_test.dart`, `test/live_trip_widget_test.dart`.

**Matching handoff**

- `matching_screen.dart` captures the proposed rider's name before `confirmRideMatch()` clears the proposal, shows that name in the waiting state, and calls `_goToTrip()` after the simulated rider accepts.
- Evidence: `lib/screens/matching_screen.dart`, `test/live_trip_widget_test.dart` (matching names the rider and auto-opens Live Trip); the full Flutter suite passes on the latest observed tree.

**`DomainCache` session-change fix**

- A per-slot generation counter retires an in-flight read when the identity changes.
- The parked request re-runs once for the new profile key.
- Tests cover: stale data never lands, several restarts collapse to one re-read, and a failed re-read stays retryable.
- `AppState` calls `cache.restart()` after session restore and sign-out.
- Evidence: `lib/state/domain_cache.dart`, `lib/state/app_state.dart`, `test/domain_cache_test.dart` (group "session changes").

**Admin read and audit handling**

- The dashboard reads as the signed-in `authenticated` role through migration-14's ten SELECT-only `admin_read_*` policies; it does not use a service-role key in the browser.
- `okOrDenied` treats `admin_audit_logs` SQLSTATE 42501 as "unavailable", not as zero rows or a page failure.
- The verification bundle creates signed URLs, reports missing storage objects honestly, and keeps every application and only that person's vehicle files.
- The user detail page shows the verification bundle; actions revalidate the layout.
- Evidence: `lib/admin/src/lib/query.ts`, `lib/admin/src/lib/verification.ts`, `lib/admin/src/app/(admin)/settings/page.tsx`, `lib/admin/src/app/(admin)/users/[id]/page.tsx`, `lib/admin/src/lib/query.test.mts`, `lib/admin/src/lib/verification.test.mts`.

**Hosted project state (read-only re-check, 9 November 2026)**

- 15 applied migrations, 26 public tables, 18 enums, RLS on all 26 tables, 35 SELECT policies.
- Counts: `profiles` 20, `ride_requests` 19, `rental_bookings` 16, `service_requests` 20, `service_transactions` 29, `notifications` 25, `wallet_transactions` 79, `cash_fee_remittances` 0.
- Auth: 20 users, 19 banned. The operator's real account (identified locally by `SURGO_REAL_USER_ID` / `SURGO_REAL_USER_EMAIL`) has one email identity, `phone` null, is unbanned, and has approved roles `passenger` and `admin` only.
- `authenticated` cannot SELECT `admin_audit_logs` (`has_table_privilege` is false).
- The hosted ledger records the admin migration as `20261106062246`; the repository keeps the same SQL under the retimed name `20261106091300`.
- The four `2026110614xxxx` financial migrations are local-only; hosted has no financial ledger tables or RPCs.

**Current test/build evidence**

- `flutter analyze`: no issues on the latest observed tree.
- `flutter test`: 428 passed on the latest observed tree, after the Live Trip, matching, Pasuyo task, and owner-home edits.
- Admin `npm test`: 10 passed.
- Admin `npm run typecheck`: clean.
- Admin `npm run lint`: no warnings or errors.
- Admin `npm run build`: compiled successfully, 16 static/dynamic routes generated.

**Existing product breadth**

- Passenger Home, Activity, Wallet, Profile.
- Rider/Helper Home, Trips, Earnings, Profile.
- Vehicle Owner Home, Bookings, Earnings, Profile.
- Ride booking, matching, live trip, chat, rating.
- Rental browse, detail, request, active rental.
- Pasuyo post, helper accept, lifecycle, rating.
- Verification center, maps, saved places, payment methods, emergency contacts, settings.
- Admin dashboard pages for dashboard, verification, users, vehicles, rides, rentals, Pasuyo, providers, finance, reports, and settings.

### 3.2 Needs Qoder confirmation

- **Working-tree stability.** The reviewed code is uncommitted Qoder work. During this review, Qoder changed `live_trip_screen.dart`, `matching_screen.dart`, `pasuyo_task_screen.dart`, and `vehicle_owner_home_screen.dart`; the Flutter suite was re-run after those edits and passes, but Qoder may continue. If Qoder changes or reverts anything, re-run the feature audit and this report against the new tree.
- **Seed inconsistencies.** The duplicate plate `NGD 6612`, sub-1.0 vehicle ratings, and capability/history mismatches are documented but not fixed. Confirm whether Qoder intends to correct them or leave them as known demo-data caveats. The hosted import clamps only sub-1.0 ratings to 1.00; `RV005` stays at 1.10 and its service area is nulled.
- **Stale root documentation.** `README.md` and `surgo_special_readme.md` contain outdated claims (for example, the old 10% ride commission, password login, or no database reads). The B1/B2 issues they describe are fixed in code, but the labels need reconciliation. This package follows the code, not those files.
- **Demo data re-application.** If Qoder changes the seed or import script again, the hosted counts must be re-verified and `audit_hosted.mjs` re-run. The counts above were re-checked directly; the maintained audit covers 127 checks, and `verify_admin_reads.mjs` covers 52. They are not a guarantee after a future import.
- **Financial migration deployment.** The four local financial migrations are not approved for the host. Confirm with the researcher/operator whether deployment is in scope; do not run `db push --include-all`.

### 3.3 Requires researcher input

These cannot be produced from the repository:

- Formal problem statement and local context for Tandag City.
- Literature review, related systems, and complete references.
- Methodology (for example Agile, Design Science, or RAD) and timeline.
- Requirements-gathering participants and instruments.
- Evaluation design, metrics, and results.
- Usability or field pilot data, if any.
- Ethical considerations and data-privacy statement.
- Institution-specific title slide and formatting.
- Adviser-required sections (abstract, acknowledgment, appendices).
- Any claims about local demand, adoption, or impact.

Do not fabricate statistics, evaluation results, or citations.

### 3.4 Intentionally simulated

- Rider matching, the 900 ms search, and the 2-second rider acceptance.
- Live-trip movement, route drawing, trip sharing, and SOS notices.
- Rental owner approval on a 10-second timer.
- Wallet top-up, cash-out, and payout behavior.
- Pasuyo lifecycle persistence and its legacy 15% commission.
- Flutter verification auto-approval on 2-second and 5-second timers.
- Notification read state: mark-one/all read mutates the seeded feed; a Supabase build does not persist it.
- Most business writes in `AppState` / `DbService` memory, which reset on reload.
- Seeded or straight-line distances; no live GPS or routing result is claimed.
- Admin demo finance: every imported `service_transactions` row stores `platform_fee_centavos = 0` because `pricing_policies` is empty. The ₱1,923.50 figure is a hypothetical recomputation of what the shipped logic would have earned, not money in the database.

### 3.5 Not required for this presentation prototype

- Push notification delivery and realtime subscriptions.
- Live GPS, routing, and multi-device dispatch.
- Payment gateway, payout provider, escrow, or refunds.
- Account linking and a Flutter email/password login.
- A service-role browser key or an audit-log feed in the admin UI. The 42501 panel is the correct boundary.
- Deploying the financial ledger and activating pricing policies for the defense.
- Google OAuth as a live demo path (the code exists; it is not required and is not verified on the demo device).
- Load, performance, and accessibility testing.
- A production-grade notification read-state write path.

---

## 4. Critical demo conditions

### 4.1 Flutter account strategy

**Finding:** the only unbanned hosted account (the operator's admin account) has an **email identity only**, no phone, and no linked Google identity. The Flutter app supports only phone OTP and Google. Therefore:

- The real account can sign into the **admin dashboard** (email/password).
- It cannot currently sign into **Flutter** through the app's auth flows.
- Seeded demo accounts are banned.
- A phone-registered Flutter account is the practical live path.

**Action:** create a dedicated Flutter account by phone OTP before the defense and keep the session active. Use the real account only for admin.

### 4.2 Role grants for rider/owner/helper

**Finding:** the real account has approved roles `passenger` and `admin` only. A new phone account starts as `passenger` only. Rider, owner, and Pasuyo helper modes require approved `earner` and `vehicle_owner` roles.

**Action:** if the full live path is required, an authorized person must grant those roles to the Flutter demo account and record the change. Otherwise use the reduced path and recorded clips.

### 4.3 Pasuyo self-acceptance

**Finding:** a fresh account's passenger and earner ids are the same, and the app refuses self-acceptance. A task posted by the account cannot be accepted by the same account as helper.

**Action:** demo helper acceptance on a **seeded** open task, not on a task just posted. Enable Errands in Rider Profile first.

### 4.4 Empty personal slices

**Finding:** a fresh account has an empty wallet, empty notifications, and may have an empty Pasuyo customer hub. Its Recent Bookings card is also empty until it completes or cancels a ride, because the card reads terminal history only.

**Action:** do not demo wallet, notifications, or Recent Bookings as populated. Focus on rides, rentals, seeded Pasuyo helper tasks, owner fleet, and admin. If notifications are populated, their ages are real; mark-read works only in the default mock mode.

### 4.5 Admin login and audit panel

**Finding:** the real account has a password set, but the actual password is not in the repository. The audit-log panel will report that the log is not readable by this session; that is SQLSTATE 42501 by design, not a broken page.

**Action:** confirm the password out-of-band and test the admin login before the defense. Prepare a second browser session. Do not try to "fix" the audit panel on stage.

### 4.6 Notification read state in Supabase mode

**Finding:** the feed and unread count are real reads, but marking a notification read does not write back in Supabase data mode. The badge can return after a refresh.

**Action:** use the default mock data mode for the demo. If you deliberately show Supabase data mode, label the read-only boundary.

---

## 5. Verification needed before the defense

### 5.1 Must verify

| Item | Why | How |
| --- | --- | --- |
| Flutter build on the defense machine | Ensure the demo machine compiles | `flutter pub get`, `flutter analyze`, `flutter test`, `flutter run -d chrome` |
| Session restore | Avoid OTP on stage | Relaunch the app; confirm the signed-in state |
| Flutter account roles | Determines the live path | Check the profile/role rows or the mode switcher |
| Admin password and login | Admin demo depends on it | Sign in at `/login` |
| Admin dashboard pages | No full browser pass recorded | Open every page you plan to show |
| Admin audit panel | Confirm the expected unavailable state | Open `/settings`; expect 42501 handling, not a 500 |
| Admin reports charts | Chart rendering can fail silently | Switch 7/14/30/90 days |
| Recent Bookings / notifications | Confirm whether they are populated | Complete a ride; open the feed; skip if empty |
| Hosted counts | Confirm demo data is present | Read-only SQL or admin dashboard |
| Backup recording | Fallback for role-specific flows | Record and play locally |

### 5.2 Should verify if time allows

- Google OAuth redirect allow-list.
- SMS delivery and rate limits.
- Signed document previews in the admin verification queue.
- Mobile/tablet layout and projector resolution.
- The exact demo sequence twice, including the reduced path.
- Pasuyo helper flow after enabling Errands.
- Rental owner-approval timer.
- Ride no-riders state.
- Notification mark-read in default mock mode.

### 5.3 Not verified by this review

- A full manual browser pass of every admin page against the hosted project.
- End-to-end live SMS in the venue network.
- Google OAuth on the demo device.
- Real-time behavior under multiple users.
- Load, performance, or accessibility testing.
- Formal usability or field evaluation.
- The behavior after any future Qoder change or seed re-import.

---

## 6. Qoder dependencies and recheck list

The working tree contains uncommitted Qoder work. This review did not modify or revert it. After Qoder stops editing, recheck:

### 6.1 Verified in the reviewed tree

- [x] `lib/state/domain_cache.dart` — new slots, generation fix, `restart()`.
- [x] `lib/state/app_state.dart` — `completeActiveRide`, `markNotificationReadById`, `cache.restart()` on session restore/sign-out.
- [x] `lib/repositories/ride_repository.dart` — `fetchRideHistory` terminal rides, newest first.
- [x] `lib/repositories/repository_mappers.dart` — `displayAge`, wallet/vehicle/notification labels.
- [x] `lib/screens/home_screen.dart` — Recent Bookings and unread badge.
- [x] `lib/screens/notifications_screen.dart` — repository feed and read action.
- [x] `lib/screens/rider_home_screen.dart` — earner profile header.
- [x] `lib/screens/wallet_screen.dart` — role-specific balance and entries.
- [x] `lib/screens/vehicle_owner_home_screen.dart`, `vehicle_owner_vehicles_screen.dart`, `vehicle_documents_screen.dart` — fleet/docs reads and the owner member-year header.
- [x] `lib/screens/live_trip_screen.dart`, `rate_trip_screen.dart` — B1/B2 single settlement and status advance.
- [x] `lib/screens/matching_screen.dart` — rider name in the waiting state and automatic Live Trip handoff.
- [x] `lib/screens/pasuyo_task_screen.dart` — report message no longer exposes the task id.
- [x] `lib/admin/src/lib/query.ts`, `verification.ts`, settings and user detail — 42501 and signed-file handling.
- [x] `test/domain_cache_test.dart`, `test/stage2_*_test.dart`, `test/flow_wiring_widget_test.dart`, `test/live_trip_widget_test.dart`.
- [x] `supabase/README.md`, `supabase/tests/run.mjs`, `supabase/tools/*` — migration sync, hosted audit, admin-read checks.

### 6.2 Pending Qoder confirmation

- [ ] Whether the latest observed working tree will be committed/merged without further changes.
- [ ] Whether the duplicate plate, sub-1.0 ratings, and capability/history mismatches will be fixed.
- [ ] Whether `README.md` and `surgo_special_readme.md` will be reconciled with the current code.
- [ ] Whether the four financial migrations will be deployed; do not push them without approval.
- [ ] Whether the hosted demo data will be re-applied; if so, re-run `audit_hosted.mjs` and `verify_admin_reads.mjs`.

### 6.3 Commands to re-run after any change

```bash
flutter analyze
flutter test
cd lib/admin
npm test
npm run typecheck
npm run lint
npm run build
node supabase/tools/audit_hosted.mjs
node supabase/tools/verify_admin_reads.mjs
```

> If Qoder changes code after this package is written, re-run the feature audit against the new code. Do not assume the statuses still hold.

---

## 7. Researcher input required

These cannot be produced from the repository:

- [ ] Formal problem statement and local context for Tandag City.
- [ ] Literature review, related systems, and complete references.
- [ ] Methodology (e.g., Agile, Design Science, RAD) and timeline.
- [ ] Requirements-gathering participants and instruments.
- [ ] Evaluation design, metrics, and results.
- [ ] Usability/field pilot data, if any.
- [ ] Ethical considerations and data-privacy statement.
- [ ] Institution-specific title slide and formatting.
- [ ] Adviser-required sections (abstract, acknowledgment, appendices).
- [ ] Any claims about local demand, adoption, or impact.

Do not fabricate statistics, evaluation results, or citations.

---

## 8. Features to avoid live

| Feature | Reason |
| --- | --- |
| Google OAuth | Redirect/identity linking unverified. |
| Account linking | Not a finished feature. |
| Wallet top-up/cash-out as real payment | In-memory only. |
| SOS as a real alert | Simulated notice. |
| Push notifications | Not implemented. |
| Notification read persistence in Supabase mode | Read state is not written back; badge can return. |
| Flutter verification auto-approval as a real review | Timer-driven simulation. |
| Admin approval of a real application | Changes real roles; use disposable data only. |
| Admin audit-log panel as a working feed | 42501 by design; the settings page shows unavailable. |
| Pasuyo customer post → same-account accept | App refuses self-acceptance. |
| Two-device dispatch / live GPS | Not implemented. |
| Admin finance as "real collected revenue" | Zero hosted remittances; demo fees are zero. |
| Claims of full persistence | Writes are in memory. |

---

## 9. Recommended preparation order

### Phase 1 — Account and environment (highest risk first)

1. Decide the Flutter account strategy (phone-registered account recommended).
2. Create the account, complete OTP, keep the session.
3. If approved, grant `earner` and `vehicle_owner` roles to the Flutter account.
4. Confirm the admin password and test admin login.
5. Confirm the hosted demo data counts.
6. Decide main path vs. reduced path.

### Phase 2 — Verification

7. Run Flutter `pub get`, `analyze`, `test`, and launch.
8. Run admin `typecheck`, `lint`, `test`, `build`, and launch.
9. Open every admin page you plan to show, including `/settings`.
10. Test the exact demo sequence twice.
11. Record the backup clip for rider/owner/Pasuyo helper.
12. Test at the venue resolution and on the venue network if possible.

### Phase 3 — Content

13. Fill the researcher-supplied slides (literature, methodology, evaluation).
14. Rehearse the 10–11 minute script with a timer.
15. Prepare the panel Q&A cheat sheet.
16. Print or mirror the speaker notes.

### Phase 4 — Final preflight

17. 30-minute checklist: network, sessions, seed, backup, timer, notifications off.
18. Confirm the reduced path is ready if the full path fails.
19. Confirm the closing statement is honest and concise.

---

## 10. Risk register

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Flutter account cannot sign in | Medium | High | Keep a prepared session; have a phone registration ready. |
| Rider/owner roles missing | High | Medium | Grant roles or use the reduced path + recording. |
| Admin password unknown | Medium | High | Confirm out-of-band; prepare a session. |
| Admin page errors | Medium | Medium | Browser-test early; fall back to slides. |
| Admin audit panel surprises the operator | Medium | Low | Explain 42501 as the designed grant boundary. |
| SMS rate limit | Medium | High | Do not rely on live OTP; keep a session. |
| Notification badge returns in Supabase mode | Medium | Low | Use default mock mode; label the read-only boundary. |
| Recent Bookings is empty on a fresh account | Medium | Low | Complete a ride first, or use Activity/seeded build. |
| Projector overflow | Medium | Low | Test resolutions; use a phone-sized window. |
| Panel asks for persistence | High | Low | State the boundary and the migration plan. |
| Panel asks for evaluation results | High | Medium | Supply real results or say they are not measured. |
| Seed inconsistency noticed | Low | Low | Acknowledge and explain the hosted clamp. |
| Running over time | Medium | Medium | Cut owner/Activity/Pasuyo; protect the close. |

---

## 11. Outstanding blockers

1. **Flutter demo account is not yet confirmed.** A dedicated phone-OTP account must exist and its session must be active. The real hosted account is email-only and cannot sign into Flutter.
2. **Rider/owner/helper roles are not granted.** The real account has `passenger` and `admin` only; a new phone account starts as `passenger`. The full live path needs approved `earner` and `vehicle_owner` roles; otherwise use the reduced path and recordings.
3. **Admin password and full browser pass are not confirmed.** The password is out-of-band, and no full manual pass of every admin page against the hosted project is recorded.
4. **Hosted financial ledger is not deployed.** Four financial migrations remain local-only, and `pricing_policies` is empty. Do not claim a live financial ledger or collected platform fees.
5. **Notification read state is not persisted in Supabase data mode.** Use the default mock mode for a coherent demo.
6. **Admin audit log is not readable by `authenticated`.** This is by design (42501); the settings page handles it. Reading the log requires the service-role channel.
7. **Seed inconsistencies remain.** Duplicate plate `NGD 6612`, sub-1.0 ratings, and capability/history mismatches are documented but not fixed.
8. **Local/hosted migration drift is unresolved.** The admin migration is `20261106091300` locally and `20261106062246` on the host; do not "repair" or rename it without a decision.
9. **Researcher inputs are missing.** Literature, methodology, evaluation, ethics, and institution-specific content cannot be generated from the repository.

---

## 12. Final recommendation

**Proceed with the defense**, provided the account, role, admin-login, and browser-pass blockers are addressed. The prototype is broad, the backend design is credible, and this package states the boundary clearly. The two conditions that matter most are:

1. **Fix the Flutter account/session and role situation before the defense.**
2. **Rehearse the honest framing** — live auth and admin, simulated business transactions, repository-backed reads where they exist, and mock-only notification read state.

If those are done, the panel will see a coherent system and a candidate who understands exactly what is real, what is simulated, and what comes next.
