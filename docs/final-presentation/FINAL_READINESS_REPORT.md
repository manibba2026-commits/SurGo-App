# SurGo — Final Readiness Report

**Report date:** 9 November 2026
**Scope:** Documentation-only review of the repository and hosted Supabase project. No application code, schema, data, or configuration was changed.

---

## 1. Bottom line

SurGo is **ready to present as a prototype**, with conditions.

- The **user experience, authentication, schema, RLS, pricing logic, and audited admin design** are strong enough for a thesis defense.
- The **live demo is constrained by account readiness**, not by missing screens.
- The **business transaction layer is simulated**, and the presentation must say so.
- The **admin dashboard is implemented but not fully browser-verified** against the hosted project.
- The **hosted schema is behind the local migration set**; the financial ledger is not deployed.

**Recommended posture:** present the architecture and the honest prototype boundary with confidence, use a prepared Flutter session and a prepared admin session, and have a recorded backup for the role-specific flows.

---

## 2. Readiness scorecard

| Area | Readiness | Notes |
| --- | --- | --- |
| Documentation package | ✅ Ready | Ten documents plus index. |
| Flutter UI breadth | ✅ Ready | All three role shells and service flows exist. |
| Live authentication (code) | ✅ Ready | Phone OTP, Google, session restore. |
| Live authentication (demo setup) | 🔶 Conditional | Account strategy must be fixed before the defense. |
| Business persistence | 🟠 Simulated | In-memory writes; reload resets. |
| Ride pricing | ✅ Ready | Platform fee implemented; centavos. |
| Pasuyo/rental pricing | 🔶 Unresolved | Legacy 15% / 10%. |
| Supabase schema | ✅ Ready (hosted subset) | 26 hosted tables; 30 local. |
| RLS and admin RPCs | ✅ Ready | Read-only baseline, audited RPCs. |
| Financial ledger | 🔶 Local only | Not applied to hosted. |
| Admin dashboard code | ✅ Ready | Pages, actions, tests, build. |
| Admin browser verification | 🟡 Needs verification | No full manual pass recorded. |
| Seed/demo data | ✅ Ready with caveats | Hosted counts verified; local inconsistencies. |
| Live demo | 🔶 Conditional | Depends on account roles and session. |
| Thesis content | 🔶 Researcher input needed | Literature, methodology, evaluation. |

---

## 3. What is ready

### 3.1 Product experience

- Passenger Home, Activity, Wallet, Profile.
- Rider/Helper Home, Trips, Earnings, Profile.
- Vehicle Owner Home, Bookings, Earnings, Profile.
- Ride booking, matching, live trip, chat, rating.
- Rental browse, detail, request, active rental.
- Pasuyo post, helper accept, lifecycle, rating.
- Verification center with capability checklists.
- Maps, saved places, payment methods, emergency contacts, settings.
- Notifications feed and unread counts.

### 3.2 Authentication

- Supabase initialization at boot.
- Phone OTP sign-in and registration.
- Google OAuth code path.
- Passwordless recovery.
- Session restore.
- Role/capability loading with a safe fallback.
- Identity-to-seed bridging.

### 3.3 Backend design

- 30-table local schema, 24 enums.
- RLS enabled on all public tables.
- Read-only client baseline; no client write policies.
- Admin-only read policies.
- Five audited admin write RPCs.
- `admin_overview` and `admin_daily_activity`.
- Three storage buckets with scoped policies.
- Auth trigger creating profile + passenger role.

### 3.4 Administration

- Next.js 14 App Router dashboard.
- Email/password sign-in.
- Server-side `is_admin()` authorization.
- Verification queue with signed document previews.
- Users, vehicles, rides, rentals, Pasuyo, providers.
- Finance and remittances.
- Reports with 7/14/30/90-day windows.
- Audit logging.

### 3.5 Documentation

- System overview, architecture, database, workflows, feature audit, test checklist, thesis outline, demo script, panel Q&A, and this report.

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

**Finding:** a fresh account has an empty wallet, empty notifications, and may have an empty Pasuyo customer hub.

**Action:** do not demo wallet/notifications as populated. Focus on rides, rentals, seeded Pasuyo helper tasks, owner fleet, and admin.

### 4.5 Admin login

**Finding:** the real account has a password set, but the actual password is not in the repository.

**Action:** confirm the password out-of-band and test the admin login before the defense. Prepare a second browser session.

---

## 5. Verification needed

### 5.1 Must verify before the defense

| Item | Why | How |
| --- | --- | --- |
| Flutter build | Ensure the demo machine compiles | `flutter pub get`, `flutter analyze`, `flutter test`, `flutter run -d chrome` |
| Session restore | Avoid OTP on stage | Relaunch the app; confirm the signed-in state |
| Flutter account roles | Determines the live path | Check the profile/role rows or the mode switcher |
| Admin password and login | Admin demo depends on it | Sign in at `/login` |
| Admin dashboard pages | No full browser pass recorded | Open every page you plan to show |
| Admin reports charts | Chart rendering can fail silently | Switch 7/14/30/90 days |
| Hosted counts | Confirm demo data is present | Read-only SQL or admin dashboard |
| Backup recording | Fallback for role-specific flows | Record and play locally |

### 5.2 Should verify if time allows

- Google OAuth redirect allow-list.
- SMS delivery and rate limits.
- Signed document previews in the admin verification queue.
- Mobile/tablet layout and projector resolution.
- `flutter test` and admin `npm test` on the defense machine.
- Pasuyo helper flow after enabling Errands.
- Rental owner-approval timer.
- Ride no-riders state.

### 5.3 Not verified by this review

- A full manual browser pass of every admin page against the hosted project.
- End-to-end live SMS in the venue network.
- Google OAuth on the demo device.
- Real-time behavior under multiple users.
- Load, performance, or accessibility testing.
- Formal usability or field evaluation.

---

## 6. Qoder dependencies and recheck list

The working tree contains uncommitted Qoder work. This review did not modify or revert it. After Qoder finishes, recheck:

### 6.1 Admin dashboard

- [ ] `lib/admin/src/components/Verification.tsx`
- [ ] `lib/admin/src/lib/verification.ts`
- [ ] `lib/admin/src/lib/query.ts` and `query.test.mts`
- [ ] `lib/admin/src/lib/verification.test.mts`
- [ ] `lib/admin/src/app/actions.ts`
- [ ] `lib/admin/src/app/(admin)/verification/page.tsx`
- [ ] `lib/admin/src/app/(admin)/users/[id]/page.tsx`
- [ ] `lib/admin/src/app/(admin)/settings/page.tsx`
- [ ] `lib/admin/package.json`, `tsconfig.json`, `.gitignore`
- [ ] Re-run `npm run typecheck`, `npm run lint`, `npm test`, `npm run build`.

### 6.2 Supabase

- [ ] `supabase/migrations/20261106091300_admin_dashboard_access_and_actions.sql` (hosted records it as `20261106062246`).
- [ ] `supabase/demo-data.sql` (generated; do not hand-edit).
- [ ] `supabase/tests/run.mjs` changes.
- [ ] Whether the four `2026110614xxxx` financial migrations are applied to hosted.
- [ ] Whether demo data was re-applied and counts still match.
- [ ] Whether the real account's roles changed.

### 6.3 Flutter data/state

- [ ] `lib/state/app_state.dart`
- [ ] `lib/state/domain_cache.dart`
- [ ] `lib/data/db_models.dart`
- [ ] `lib/repositories/backend_rows.dart`
- [ ] `lib/repositories/repository_mappers.dart`
- [ ] `lib/repositories/notification_repository.dart`
- [ ] `lib/repositories/ride_repository.dart`
- [ ] `lib/repositories/vehicle_repository.dart`
- [ ] Modified screens: notifications, rider home, vehicle documents, owner home, owner vehicles, wallet.
- [ ] Re-run `flutter analyze` and `flutter test`.

### 6.4 Seed data

- [ ] `assets/db/rides.json`
- [ ] `assets/db/users.json`
- [ ] `assets/db/vehicles.json`
- [ ] Whether the duplicate plate and sub-1.0 ratings were fixed.
- [ ] Whether capability/history mismatches were corrected.

### 6.5 Documentation

- [ ] `supabase/README.md` changes.
- [ ] `lib/admin/README.md` changes.
- [ ] Whether the root `README.md` and `surgo_special_readme.md` were updated.
- [ ] Reconcile any changed claims with this package.

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
| Flutter verification auto-approval as a real review | Timer-driven simulation. |
| Admin approval of a real application | Changes real roles; use disposable data only. |
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
9. Open every admin page you plan to show.
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
| SMS rate limit | Medium | High | Do not rely on live OTP; keep a session. |
| Projector overflow | Medium | Low | Test resolutions; use a phone-sized window. |
| Panel asks for persistence | High | Low | State the boundary and the migration plan. |
| Panel asks for evaluation results | High | Medium | Supply real results or say they are not measured. |
| Seed inconsistency noticed | Low | Low | Acknowledge and explain the hosted clamp. |
| Running over time | Medium | Medium | Cut owner/Activity/Pasuyo; protect the close. |

---

## 11. Final recommendation

**Proceed with the defense.** The prototype is broad, the backend design is credible, and the documentation now states the boundary clearly. The two conditions that matter most are:

1. **Fix the Flutter account/session and role situation before the defense.**
2. **Rehearse the honest framing** — live auth and admin, simulated business transactions.

If those are done, the panel will see a coherent system and a candidate who understands exactly what is real, what is simulated, and what comes next.
