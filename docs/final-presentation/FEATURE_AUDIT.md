# SurGo — Feature Audit

## 1. Purpose

This audit answers one question per feature: **if the panel asks to see it, what will actually happen?**

The status labels are defined in [README.md](README.md). Evidence is cited by file so the claim can be checked.

## 2. Executive summary

| Status | Meaning in this project |
| --- | --- |
| ✅ Implemented and demonstrable | Reachable and supported by a working code path; suitable for a live demo. |
| 🟡 Implemented but needs verification | Code exists, but a live check is environment-dependent or has not been completed. |
| 🟠 Simulated/demo data | Intentionally faked with timers, seeds, or in-memory mutations. |
| 🔶 Partially implemented | Real and simulated layers are mixed; the boundary matters. |
| ❌ Not implemented | No working code path. |
| ⚪ Provisional | Could not be confirmed. |

**Overall:** the prototype is strongest in **user experience breadth, authentication, seeded data, pricing logic, schema design, RLS, and audited admin functions**. It is weakest in **persistence of business writes, real-time dispatch, payments, and the link between Flutter verification and admin verification**.

## 3. Required-area audit

### 3.1 Authentication

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Splash and session restore | ✅ | `splash_screen.dart`, `AppState.restoreSession` | Show only if a session already exists; otherwise sign in live. |
| Phone OTP sign-in | ✅ | `login_screen.dart`, `otp_screen.dart`, `supabase_auth_repository.dart` | Requires SMS delivery and network. Have a fallback account ready. |
| Phone OTP registration | ✅ | `register_screen.dart` | Creates a passenger-only account via the auth trigger. |
| Google OAuth | 🟡 | `signInWithGoogle`, `redirectTo` | Verify redirect allow-list and platform config before relying on it. |
| Passwordless recovery | ✅ | `forgot_password_screen.dart` | Same phone OTP path; not a separate password reset. |
| Account linking | 🔶 | `linkGoogleIdentity`, `linkPhone` mode | Do not demo unless verified. |
| Sign out | ✅ | `AppState.signOut` | Safe. |
| Capability gating | ✅ | `auth_models.dart`, `accounts.json` | Explain that approved roles, not screen presence, unlock modes. |
| Fixed OTP `123456` | 🟠 | `mock_auth_repository.dart` | Test/preview only; not installed by `main.dart`. Never present as live. |
| Live account with all modes | 🟡 | Hosted roles | The only unbanned hosted account is email-only (admin dashboard) with `passenger` + `admin`; a phone-registered Flutter account starts passenger-only and needs approved roles. |

**Critical demo fact:** demo seed accounts are banned in Supabase Auth. A live Flutter login must use a **dedicated phone-registered account** (the only unbanned hosted account is email-only and is used for the admin dashboard) or a newly created phone account. A newly created account starts as passenger only.

### 3.2 Passenger dashboard

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Home with service tiles | ✅ | `home_screen.dart` | Safe; shows rides, rentals, Pasuyo, map, assisted booking. |
| Live ride card / active trip entry | ✅ | `home_screen.dart`, `live_trip_screen.dart` | Appears after a ride is requested. |
| Activity tabs (Rides/Rentals/Pasuyo) | ✅ | `activity_screen.dart` | Seeded history makes this look populated. |
| Wallet tab | 🔶 | `wallet_screen.dart` | Reads balance via repository; top-up/cash-out are in-memory. |
| Profile tab | 🔶 | `profile_screen.dart` | Profile read is real; edits/settings are in-memory. |
| Maps | 🟠 | `passenger_map_screen.dart`, `surgo_map.dart` | Visual only; no GPS/routing. |
| Saved places | 🔶 | `saved_places_screen.dart` | In-memory. |
| Payment methods | 🔶 | `payment_methods_screen.dart` | Display only; no gateway. |
| Emergency contacts | 🔶 | `emergency_contacts_screen.dart` | In-memory; used by simulated SOS. |
| Account settings | 🔶 | `account_settings_screen.dart` | In-memory. |
| Assisted booking | 🟡 | `assisted_booking_screen.dart`, `home_screen.dart` | Reachable; not a core demo path. Verify before showing. |
| Platform revenue screen | 🟠 | `revenue_screen.dart` | In-memory ledger; do not present as accounting. |

### 3.3 Ride booking

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Pickup/destination selection | ✅ | `booking_screen.dart` | Use seeded places; no GPS. |
| Vehicle class and fare options | ✅ | `booking_screen.dart`, `ride_pricing.dart` | Safe. |
| Platform-fee breakdown | ✅ | `ride_pricing.dart`, `docs/PRICING.md` | Strong slide/demo moment: provider fare + platform fee. |
| Ride request creation | ✅ | `AppState.requestRide` | In-memory. |
| Rider matching | 🟠 | `matching_screen.dart` | 900 ms simulated search. Say "simulated dispatch". |
| Passenger confirmation | ✅ | `matching_screen.dart` | Real UI commitment. |
| Simulated rider acceptance | 🟠 | `matching_screen.dart` | 2 s timer. Say "simulated acceptance". |
| Decline / cancel | ✅ | `matching_screen.dart` | Safe. |
| No-riders state | ✅ | `matching_screen.dart` | Good honest edge case. |
| Persistence | ❌ | `AppState` memory | Reload resets. |

### 3.4 Rider dashboard

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Online/offline toggle | 🟠 | `rider_home_screen.dart` | Simulated presence. |
| Incoming request list | 🟠 | `rider_home_screen.dart` | Seeded requests; no real dispatch. |
| Earnings summary | 🟠 | `rider_home_screen.dart`, `rider_earnings_screen.dart` | In-memory/seed. |
| Trips history | 🟠 | `rider_trips_screen.dart` | Seeded. |
| Vehicle documents | 🔶 | `vehicle_documents_screen.dart` | Reads repository; review status is demo. |
| Rider profile | 🔶 | `rider_profile_screen.dart` | Read via repository; edits in-memory. |
| Rider map | 🟠 | `rider_map_screen.dart` | Visual only. |
| Nearby Pasuyo | 🟠 | `rider_home_screen.dart` | Seeded tasks. |

### 3.5 Ride acceptance

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Accept a request | ✅ | `AppState.acceptRideRequest` | In-memory; suitable for demo. |
| Reject a request | ✅ | Rider request card | In-memory. |
| Assign rider and vehicle | ✅ | `AppState`, `ride_match.dart` | Seed rider assignment. |
| Status transitions | ✅ | `ride_status.dart` | Real state machine, in-memory. |
| Two-device dispatch | ❌ | — | Do not claim. |
| Persistence | ❌ | — | Reload resets. |

### 3.6 Active trip

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Live trip screen | ✅ | `live_trip_screen.dart` | Safe visual. |
| Route/map display | 🟠 | `surgo_map.dart` | Static/simulated. |
| Status stepper | ✅ | `live_trip_screen.dart`, `ride_status.dart` | Safe. |
| Ride chat | 🟠 | `ride_chat_screen.dart`, `ride_chat.dart` | In-memory messages. |
| Share trip | 🟠 | `live_trip_screen.dart` | Shows a simulated notice. |
| SOS | 🟠 | `live_trip_screen.dart` | Requires an emergency contact; simulated alert. |
| Complete trip | ✅ | `AppState.completeRide` | In-memory settlement. |
| Rate trip | ✅ | `rate_trip_screen.dart` | In-memory. |
| Real GPS / ETA | ❌ | — | Do not claim. |

### 3.7 Vehicle rentals

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Browse rentals | ✅ | `rental_list_screen.dart` | Seeded vehicles. |
| Vehicle detail and pricing | ✅ | `rental_detail_screen.dart` | `days × pricePerDay`. |
| Date validation | ✅ | `rental_detail_screen.dart` | Safe. |
| One live booking guard | ✅ | `rental_detail_screen.dart` | Safe edge case. |
| Request booking | ✅ | `AppState.requestRental` | In-memory. |
| Owner approval | 🟠 | `app_state.dart` | 10 s timer. Say "simulated owner approval". |
| Active rental | ✅ | `active_rental_screen.dart` | Safe. |
| Owner bookings | 🔶 | `vehicle_owner_bookings_screen.dart` | Seeded + in-memory. |
| Owner fleet management | 🔶 | `vehicle_owner_vehicles_screen.dart` | Reads repository; writes in-memory. |
| Rental earnings | 🟠 | `vehicle_owner_earnings_screen.dart` | Seeded/in-memory. |
| Payment/deposit/insurance/damage | ❌ | — | Do not claim. |
| Rental pricing policy | 🔶 | `docs/PRICING.md` | 10% legacy commission is unresolved. |

### 3.8 Pasuyo

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Customer hub | ✅ | `pasuyo_screen.dart` | Seeded active/history. |
| Post an errand | ✅ | `pasuyo_post_screen.dart` | In-memory. |
| Helper nearby list | 🟠 | `rider_home_screen.dart` | Seeded. |
| Accept task | ✅ | `pasuyo_task_screen.dart`, `AppState.acceptPasuyoTask` | In-memory. |
| Status stepper | ✅ | `pasuyo_task_screen.dart`, `pasuyo_status.dart` | Real state machine. |
| Fee split | 🟠 | `fee_calculator.dart` | 15% legacy commission; unresolved. |
| Completion and rating | ✅ | `pasuyo_task_screen.dart` | In-memory. |
| Report/cancel | ✅ | `pasuyo_task_screen.dart` | In-memory. |
| Two-device coordination | ❌ | — | Do not claim. |

### 3.9 Wallet

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Balance display | 🔶 | `wallet_screen.dart`, `WalletRepository` | Real read in Supabase mode; mock otherwise. |
| Transaction history | 🔶 | `wallet_screen.dart` | Seed or live read. |
| Top up | 🟠 | `wallet_screen.dart` | In-memory. |
| Cash out | 🟠 | `wallet_screen.dart` | In-memory; min ₱300 enforced. |
| Payout provider | ❌ | — | Do not claim. |
| Ride fee ledger | 🟠 | `platform_ledger`, `revenue_screen.dart` | In-memory; platform fee recorded as earned. |
| Remittance collection | 🟠 | `revenue_screen.dart`, admin finance | Flutter side in-memory; admin reads hosted `cash_fee_remittances` (0 rows). |

### 3.10 Notifications

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Feed | 🔶 | `notifications_screen.dart`, `NotificationRepository` | Real read possible; mock by default. |
| Unread count | 🔶 | `rider_home_screen.dart`, `DomainCache` | Real read possible. |
| Mark one/all read | 🟠 | `notifications_screen.dart`, `AppState` | In-memory. |
| Push delivery | ❌ | `device_tokens` table only | Do not claim. |
| Realtime updates | ❌ | — | Do not claim. |

### 3.11 User profiles

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| View profile | ✅ | `profile_screen.dart`, `ProfileRepository` | Real read possible. |
| Roles display | ✅ | `ProfileRepository.fetchApprovedRoles` | Real read possible. |
| Edit profile | 🟠 | `AppState` | In-memory. |
| Saved places | 🟠 | `saved_places_screen.dart` | In-memory. |
| Emergency contacts | 🟠 | `emergency_contacts_screen.dart` | In-memory. |
| Account settings | 🟠 | `account_settings_screen.dart` | In-memory. |
| Avatar upload | ❌ | `avatars` bucket exists | No upload flow verified. |

### 3.12 Verification

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Capability status cards | ✅ | `verification_screen.dart` | Safe. |
| Document checklist | ✅ | `verification_policy.dart` | Safe. |
| Submit application | 🟠 | `AppState.startVerification` | In-memory. |
| Simulated review | 🟠 | `verification_policy.dart` | 2 s → under review, 5 s → approved. |
| Auto-approval | 🟠 | `AppState.advanceVerificationReviews` | Demo only. |
| Admin review queue | 🟡 | Next.js `/verification` | Real, but not browser-verified here. |
| Admin approve/reject | 🟡 | `admin_review_verification` | Audited RPC; verify with live data. |
| Flutter ↔ admin sync | ❌ | — | The two workflows are disconnected. |
| Document upload to Storage | ❌ | Buckets/policies exist | No verified Flutter upload path. |

### 3.13 Admin dashboard

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| Email/password sign-in | 🟡 | `login/page.tsx` | The real account has a password set; confirm the password before demo. |
| Admin authorization | ✅ | `lib/auth.ts`, `is_admin()` | Server-side; strong talking point. |
| Dashboard overview | 🟡 | `dashboard/page.tsx`, `admin_overview` | Reads live hosted data; verify in browser. |
| Verification queue | 🟡 | `verification/page.tsx`, `verification.ts` | Signed URLs and missing-file states implemented. |
| Users and user detail | 🟡 | `/users`, `/users/[id]` | Reads live; actions audited. |
| Vehicles | 🟡 | `/vehicles` | Reads live. |
| Rides and ride detail | 🟡 | `/rides`, `/rides/[id]` | Reads live. |
| Rentals | 🟡 | `/rentals` | Reads live. |
| Pasuyo | 🟡 | `/pasuyo` | Reads live. |
| Providers | 🟡 | `/providers` | Reads live. |
| Finance | 🟡 | `/finance` | Reads live; zero remittances currently. |
| Settings | 🟡 | `/settings` | Verify. |
| Audit trail | ✅ | `admin_audit_logs` + RPCs | Readable only through `service_role`. |
| Browser-tested against production | ⚪ | `lib/admin/README.md` says untested | Say "verified by tests and build, not yet a full browser pass". |

### 3.14 Reports

| Feature | Status | Evidence | Demo guidance |
| --- | --- | --- | --- |
| 7/14/30/90-day windows | 🟡 | `reports/page.tsx` | Verify in browser. |
| New users / rides / rentals / Pasuyo | 🟡 | `admin_daily_activity` | Live RPC. |
| Fees recorded | 🟡 | `admin_daily_activity` | Live; demo rows have zero platform fees. |
| User growth chart | 🟡 | `LineTrend` | Verify rendering. |
| Revenue trend | 🟡 | `LineTrend` | Will be flat at zero for demo data. |
| Service usage chart | 🟡 | `StackedBars` | Live. |
| Ride demand by barangay | 🟡 | `ride_requests` query | Live; GPS coverage is partial. |
| Exported reports (PDF/CSV) | ❌ | — | Do not claim. |

## 4. Cross-cutting findings

### 4.1 Persistence boundary

Most business writes are in `AppState`/`DbService` memory. A page reload restores the seed. This is the single most important caveat to state.

### 4.2 Repository adoption is partial

The repository layer covers nine domains and is used for selected reads, but many screens still read `AppState` directly. Do not claim "the app is fully repository-driven".

### 4.3 Two verification systems

- Flutter: simulated auto-approval.
- Admin: real audited review.

They do not share data. This is a design gap, not a bug to hide.

### 4.4 Pricing is only settled for rides

- Rides: platform fee implemented; provider keeps 100%.
- Pasuyo: 15% legacy commission, unresolved.
- Rentals: 10% legacy commission, unresolved.

### 4.5 Hosted auth roster is thin

Only one unbanned hosted account exists: the operator's admin account, with an email identity only and approved roles `passenger` and `admin`. Demo accounts are banned. This constrains the live demo: it is the admin-dashboard account, and Flutter needs a separate phone-registered account.

### 4.6 Hosted schema is behind local

Four financial migrations are local-only. Do not claim the hosted project has the full financial ledger.

### 4.7 Seed inconsistencies

- Implausible vehicle ratings below 1.0 in local `vehicles.json`.
- Duplicate plate `NGD 6612`.
- Some seeded people have history in services they are not approved for.
- Hosted import clamps only sub-1.0 ratings up to 1.00; `RV005`'s 1.1 stays 1.10 and its service area is nulled.

### 4.8 Stale documentation

`README.md` and `surgo_special_readme.md` contain outdated claims (10% ride commission, password login, no database reads). Use this package and the code instead.

## 5. Features to avoid live

Do not put these on the critical demo path:

- Google OAuth (unless redirects are verified).
- Account linking.
- Wallet top-up/cash-out as a "real" payment.
- SOS as a real emergency alert.
- Admin finance remittance actions (zero hosted rows; could look empty).
- Admin verification approval on a real application (unless a disposable test application exists).
- Any claim of two-device dispatch, GPS, push notifications, or persistence.

## 6. Best live features

These are the strongest, most honest demonstrations:

1. Phone OTP sign-in with the dedicated phone-registered Flutter account.
2. Passenger booking with the platform-fee breakdown.
3. Simulated matching and live trip, explicitly labelled.
4. Pasuyo customer/helper dual view.
5. Rental request with date validation and simulated owner approval.
6. Admin dashboard overview and verification queue (read-only if no disposable application).
7. RLS and audited-RPC architecture explanation.

## 7. Audit conclusion

SurGo is a **credible, broad prototype** with unusually strong backend security design for a student project. Its claims should be framed around **demonstrated user experience, real authentication, real read paths, schema/RLS design, and audited administration**, not around production transaction processing.
