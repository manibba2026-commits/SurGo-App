# SurGo — Live Demo Script

**Target length:** 10–11 minutes (hard limit 12). **Goal:** show the strongest real flows, label the simulated parts honestly, and avoid every known failure mode.

---

## 1. Demo strategy

### 1.1 One Flutter account, one admin account

Use **two accounts in two different apps**, not repeated account switching:

| Purpose | Account | Why |
| --- | --- | --- |
| Flutter demo | A dedicated account created in the app by phone OTP | The app only supports phone OTP and Google; a phone-created account has a working Flutter session. |
| Admin demo | The operator's admin account (email + password, supplied out-of-band) | It is the only unbanned hosted account with an approved `admin` role. |

Do **not** try to sign into Flutter with that admin account: the hosted user has an **email identity only**, no phone and no linked Google identity, while the Flutter app has no email/password login. This is a verified limitation, not a guess.

Do **not** try to sign in with a seeded demo account (`jr.derigay@email.com`, etc.). Those auth rows are banned.

### 1.2 Prepare the Flutter account before the defense

1. Install/run the app on the demo device.
2. Register with a real phone number you control.
3. Complete the SMS OTP.
4. Keep the session active (do not sign out).
5. Verify the app restores the session on relaunch.

If you want rider/owner/helper modes in the live demo, an authorized person must grant approved `earner` and `vehicle_owner` roles to that account's profile in Supabase **before** the defense. This is a privileged data change; get approval and record it.

Role-grant template (do not run without authorization):

```sql
-- Replace <PROFILE_UUID> with the Flutter demo account's profile id.
insert into public.user_roles (profile_id, role, status, approved_at)
values
  ('<PROFILE_UUID>', 'earner', 'approved', now()),
  ('<PROFILE_UUID>', 'vehicle_owner', 'approved', now())
on conflict (profile_id, role) do update
  set status = 'approved', approved_at = now();
```

Without those roles, the Flutter demo is **passenger-only**; use the reduced path in section 6.

### 1.3 Data mode

Use the **default mode** (no `SURGO_DATA_SOURCE` define): live Supabase Auth + local mock business data. It is the most coherent demo because most writes are in memory anyway.

Do not switch to `SURGO_DATA_SOURCE=supabase` during the demo.

### 1.4 What the fresh account will and will not show

A phone-registered account gets a fresh local passenger/earner/owner slice:

| Screen | What to expect |
| --- | --- |
| Passenger Home | Works; shared seeded lists where applicable. |
| Ride booking / matching / live trip | Works. The matching proposal assigns a seeded rider, so the driver card is populated. |
| Activity | Seeded ride history plus the new ride. |
| Wallet | Balance may be ₱0 and history empty. **Do not demo as rich.** |
| Notifications | May be empty. **Do not demo.** |
| Pasuyo customer hub | May be empty (seeded tasks belong to other customer ids). Show the post form instead, or skip. |
| Pasuyo helper | Seeded open tasks appear **only after enabling Errands** in Rider Profile. |
| Rider profile | Vehicle fields may be blank. **Do not linger.** |
| Owner fleet | Shared seeded vehicles appear. |
| Owner profile | May be sparse. **Do not linger.** |
| Verification | Simulated. **Do not demo as a real review.** |

### 1.5 Do not demo live

- Google OAuth (unless redirects and identity linking are verified).
- Account linking.
- Wallet top-up/cash-out as a real payment.
- SOS as a real emergency alert.
- Push notifications.
- Flutter verification auto-approval as a real admin decision.
- Admin approval of a real application (unless a disposable test application exists).
- Pasuyo customer post → same-account helper accept (the app refuses self-acceptance).
- Any claim of two-device dispatch or GPS.

---

## 2. Sample data to reference

| Item | Seed value |
| --- | --- |
| Seeded pending ride requests | 5 (`assets/db/rides.json`) |
| Seeded Pasuyo tasks | 20: 3 posted, 3 accepted, 3 delivering, 1 purchasing, 8 completed, 2 cancelled |
| Seeded rental vehicles | 14 (`RV001`–`RV014`) |
| Example vehicle | Honda Click 125i, ₱500/day (`RV001`) |
| Example vehicle | Toyota Avanza, ₱1,500/day (`RV003`) |
| Seeded rental history | 8 completed |
| Ride platform fee | `min(₱30, max(₱5, km × ₱2))` |
| Pasuyo commission | 15% legacy (unresolved) |
| Rental commission | 10% legacy (unresolved) |
| Payout minimum | ₱300.00 |
| Hosted demo rows | 20 profiles, 19 rides, 16 rentals, 20 Pasuyo, 29 transactions |

---

## 3. Main demo sequence (full path, ~11 minutes)

### 0:00–0:40 — Open and frame

**Screen:** Slide 1 or the app splash.

**Action:** Start on the title/architecture slide, then bring the app forward.

**Say:**

> "This is SurGo. One account, three modes: Passenger, Rider/Helper, and Vehicle Owner. Authentication is live in Supabase. The business flows are intentionally simulated in memory for a safe demo. I will label each one as I go."

**Expected:** App is already signed in and on Passenger Home.

**Recovery:** If not signed in, use the prepared session or the reduced path.

---

### 0:40–3:20 — Passenger ride booking → matching → live trip

**Screen:** Passenger Home → Booking.

**Actions:**

1. Tap the **Ride** tile.
2. Show pickup and destination. Change one if the UI allows.
3. Point to the vehicle options and the fare breakdown.
4. Highlight **Provider fare**, **SurGo platform fee**, **Total customer payment**.
5. Tap **Request** / **Book**.
6. Matching screen appears; wait for the proposal.
7. Tap **Confirm** / **Accept**.
8. Wait ~2 seconds for the simulated rider acceptance.
9. Live trip screen opens.
10. Point to the driver card, status stepper, chat, share, and SOS.
11. Advance/complete the trip.
12. Rate the trip.

**Say:**

> "The platform fee is separate from the provider fare. The rider keeps the entire fare; the customer pays the platform fee on top. Matching is simulated — a 900-millisecond search and a two-second rider acceptance — so I can show the state transitions without a second device."

**Expected:**

- Matching shows a rider proposal, not an eternal spinner.
- Confirmation shows the waiting state.
- Live trip shows a populated seeded driver.
- Completion reaches the rating screen.
- The ride appears in Activity.

**Recovery:**

- No riders: explain the honest no-riders state, go back, retry.
- Wrong screen: use the system back or restart the app; the seed reloads.
- Timer stalls: wait 2–3 seconds; if still stuck, restart and skip to Activity.

---

### 3:20–4:10 — Passenger Activity and rental entry

**Screen:** Passenger Activity → Home → Rental.

**Actions:**

1. Open **Activity** and show the Rides tab with the new completed ride plus seeded history.
2. Briefly show Rentals and Pasuyo tabs.
3. Return Home and tap **Rental**.

**Say:**

> "Activity is the shared history view. The ride I just completed is at the top, and the seeded history shows what a populated account looks like."

**Expected:** Tabs render; new ride is visible.

**Recovery:** If the new ride is missing, continue with seeded history and do not dwell.

---

### 4:10–5:40 — Rental request and simulated owner approval

**Screen:** Rental list → Vehicle detail → Active rental.

**Actions:**

1. Open **Honda Click 125i** (₱500/day) or **Toyota Avanza** (₱1,500/day).
2. Pick pickup and return dates.
3. Show the computed total.
4. Try an invalid range briefly to show validation (optional).
5. Tap **Request Rental**.
6. Show the pending card on Home/Active rental.
7. Wait ~10 seconds for the simulated owner approval.
8. Show the active rental.

**Say:**

> "The total is days times the daily rate. The owner approval is simulated on a ten-second timer. A real deployment would notify the owner and require an explicit decision."

**Expected:** Pending → active after ~10 seconds; active rental renders.

**Recovery:**

- If a live rental already exists, the app blocks a second one. Explain the guard and show the existing rental instead.
- If the timer does not fire, restart and show the seeded active rental.

---

### 5:40–7:10 — Rider acceptance (if roles granted)

**Screen:** Profile → Switch to Rider → Rider Home.

**Actions:**

1. Open **Profile**.
2. Use the mode switcher to select **Rider / Earner**.
3. Toggle **Online**.
4. Show the incoming request list.
5. Accept one seeded request.
6. Show the active ride banner.
7. Open Trips or complete the ride.

**Say:**

> "The rider sees the seeded incoming requests. Accepting moves the request into the active ride state. This is in-memory; there is no second device dispatching."

**Expected:** Online state, request list, accept action, active ride banner.

**Recovery:**

- No requests: go offline/online again or restart; the seed restores 5 pending requests.
- Blank vehicle fields: do not open the rider profile; stay on the request list and banner.
- If roles were not granted, skip to the reduced path.

---

### 7:10–8:10 — Pasuyo helper (if Errands enabled)

**Screen:** Rider Profile → enable Errands → Rider Home → Nearby Pasuyo.

**Actions:**

1. In Rider Profile, turn on **Errands** (and/or Deliveries).
2. Return to Rider Home.
3. Open a seeded nearby Pasuyo task.
4. Accept it.
5. Advance the stepper: accepted → purchasing → delivering → delivered.
6. Show the fee split.

**Say:**

> "Pasuyo is the errands line. The helper accepts a seeded task and advances the same status machine the customer sees. The fee split is 15% legacy commission, which is explicitly unresolved in the pricing document."

**Expected:** Task appears, accept works, stepper advances, fee split visible.

**Recovery:**

- No nearby tasks: confirm Errands is on; restart if needed.
- Do not try to accept a task you just posted as the customer; the app refuses self-acceptance.

---

### 8:10–9:00 — Owner mode (if roles granted)

**Screen:** Profile → Switch to Vehicle Owner → Owner Home → Bookings.

**Actions:**

1. Switch to **Vehicle Owner**.
2. Show the seeded fleet.
3. Open **Bookings**.
4. Open a seeded booking.
5. Show the active rental detail.

**Say:**

> "The owner sees the shared fleet and booking requests. The fleet is seeded; owner approval is simulated on the passenger side."

**Expected:** Fleet and bookings render.

**Recovery:** If sparse, return to Passenger mode and skip.

---

### 9:00–10:40 — Admin dashboard

**Screen:** Second browser window/profile → `http://localhost:3100` (or deployed admin URL).

**Actions:**

1. Sign in with the operator's admin account email (supplied out-of-band) and the known password.
2. Show the **Dashboard** overview.
3. Open **Verification**; show the queue and document file states.
4. Open **Reports**; switch the window between 7 and 30 days.
5. Point out that the dashboard reads live hosted data and that actions go through audited RPCs.

**Say:**

> "The admin app is separate. It authenticates with Supabase, checks `is_admin()` server-side, and never writes tables from the browser. Review decisions go through audited security-definer functions. The dashboard reads live hosted data; the Flutter business writes are the part still simulated."

**Expected:** Dashboard, verification queue, and reports render without server errors.

**Recovery:**

- Login fails: confirm password and network; use a prepared session in a second browser.
- A page errors: switch to the architecture slide and explain the RPC/RLS design; do not debug live.
- Finance is empty: that is expected; zero remittances are seeded.

---

### 10:40–11:20 — Close

**Screen:** Slide 14 or 15.

**Say:**

> "To close: authentication, the schema, RLS, and the audited admin workflow are real. The transactional business layer is simulated so the flows can be shown safely. The next phase is moving each write to a server-side transaction and deploying the financial ledger. Thank you."

---

## 4. Timing table

| Time | Segment | Priority |
| --- | --- | --- |
| 0:00–0:40 | Open and frame | Must |
| 0:40–3:20 | Passenger ride flow | Must |
| 3:20–4:10 | Activity | Should |
| 4:10–5:40 | Rental flow | Must |
| 5:40–7:10 | Rider acceptance | If roles granted |
| 7:10–8:10 | Pasuyo helper | If Errands enabled |
| 8:10–9:00 | Owner mode | Optional |
| 9:00–10:40 | Admin dashboard | Must |
| 10:40–11:20 | Close | Must |

If you are running long, cut **Owner mode**, then **Activity**, then **Pasuyo**. Never cut the close or the honest framing.

---

## 5. Exact screen/action/expected table

| # | Screen | Action | Expected | If it fails |
| --- | --- | --- | --- | --- |
| 1 | Passenger Home | Tap Ride | Booking opens | Restart; seed reloads |
| 2 | Booking | Choose pickup/destination | Labels update | Use defaults |
| 3 | Booking | Inspect fare | Provider fare + platform fee + total | Explain from slide |
| 4 | Booking | Request | Matching opens | Back and retry |
| 5 | Matching | Wait ~1 s | Proposal or no-riders | Retry or skip |
| 6 | Matching | Confirm | Waiting state | Wait 2 s |
| 7 | Matching | Wait ~2 s | Live trip opens | Open Activity card |
| 8 | Live trip | Inspect/advance | Stepper moves | Use back/restart |
| 9 | Live trip | Complete | Rating screen | Skip rating |
| 10 | Activity | Open Rides | New ride at top | Use seeded history |
| 11 | Rental list | Open vehicle | Detail + price | Use another vehicle |
| 12 | Rental detail | Pick dates | Total updates | Use defaults |
| 13 | Rental detail | Request | Pending card | Show existing rental |
| 14 | Home/Active | Wait ~10 s | Active rental | Restart; show seed |
| 15 | Profile | Switch to Rider | Rider Home | Skip if no role |
| 16 | Rider Home | Go online | Requests appear | Toggle again |
| 17 | Rider Home | Accept | Active ride banner | Retry |
| 18 | Rider Profile | Enable Errands | Nearby tasks appear | Restart |
| 19 | Pasuyo task | Accept/advance | Stepper moves | Skip |
| 20 | Profile | Switch to Owner | Owner Home | Skip if no role |
| 21 | Owner Bookings | Open booking | Rental detail | Skip |
| 22 | Admin login | Email/password | Dashboard | Use prepared session |
| 23 | Admin verification | Open queue | Applications/docs | Explain empty state |
| 24 | Admin reports | Change window | Charts update | Explain from slide |

---

## 6. Reduced live path (if roles are not granted)

Use this if the Flutter account is passenger-only. It still fits 8–9 minutes.

| Time | Segment | Action |
| --- | --- | --- |
| 0:00–0:40 | Frame | State the real/simulated boundary. |
| 0:40–3:30 | Passenger ride | Book → match → live trip → complete. |
| 3:30–4:15 | Activity | Show completed ride + seeded history. |
| 4:15–5:45 | Rental | Browse → dates → request → active. |
| 5:45–7:00 | Recorded clip | Rider accept, Pasuyo helper, owner booking. |
| 7:00–8:40 | Admin | Dashboard → verification → reports. |
| 8:40–9:20 | Close | Limitations and next phase. |

**Narration for the recorded clip:**

> "Because the live Flutter account is passenger-only, I am showing the rider, Pasuyo, and owner flows from a recording made on the seeded demo build. The code paths are the same; only the account's approved roles differ."

This is honest and avoids a failed live attempt.

---

## 7. Recovery playbook

| Symptom | Immediate action | Narration |
| --- | --- | --- |
| Not signed in | Use the prepared session; if unavailable, register with a phone and continue passenger-only. | "I'll use the prepared demo account." |
| OTP not received | Do not wait on stage; switch to the prepared session or recorded clip. | "SMS delivery is rate-limited; I'll use the prepared session." |
| App state corrupted | Restart the app; the seed reloads. | "The prototype is in-memory, so a restart restores the demo data." |
| No riders | Retry once; if it persists, show Activity and move on. | "This is the honest no-riders state." |
| Rental timer stalls | Show the seeded active rental or restart. | "The owner approval is a simulated timer." |
| Admin login fails | Use the second prepared browser session. | "I'll use the prepared admin session." |
| Admin page 500s | Switch to the architecture slide. | "The dashboard is a separate app; I'll show the design instead." |
| Projector overflow | Reduce window width or use a phone. | — |
| Running over 12 minutes | Cut owner, Activity, Pasuyo. | — |

---

## 8. Closing lines

> "SurGo demonstrates the full user experience and a security architecture that is ready for real writes. Authentication and administration are live; the transactional business layer is intentionally simulated. The next step is server-side persistence and the financial ledger."

---

## 9. Pre-demo checklist (short)

- [ ] Flutter account created, signed in, session restored.
- [ ] Roles granted if the full path is planned.
- [ ] Errands capability enabled if Pasuyo helper is planned.
- [ ] Admin account password confirmed.
- [ ] Admin session opened in a second browser/profile.
- [ ] Recorded clip ready for the reduced path.
- [ ] Seed data visible.
- [ ] Timer visible.
- [ ] Backup device/network ready.
