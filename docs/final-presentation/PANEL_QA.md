# SurGo — Panel Q&A

**How to use this document:** answer in two layers — first the direct answer, then the prototype/future boundary. If you do not know, say so and state how it would be verified. Never improvise a statistic.

---

## A. Scope and honesty

### 1. Is SurGo a working app or a mockup?

It is a working **prototype**. The screens, navigation, state machines, authentication, and admin dashboard are real code. Most business writes are simulated in memory, so it is not a production transaction system. The accurate description is: "a working product prototype with live authentication and a read-only Supabase data layer, where transactional writes are simulated for demonstration."

### 2. What exactly is simulated?

Rider matching and acceptance timers, live-trip movement, SOS delivery, trip sharing, rental owner approval, wallet top-up/cash-out, Pasuyo lifecycle persistence, Flutter verification auto-approval, and most business writes. Each is labelled in the feature audit.

### 3. What is genuinely real?

Supabase authentication, session restoration, role/capability loading, selected repository reads (passenger/earner profiles, notification feed and unread counts, Recent Bookings, wallet balances and history, owner fleet, vehicle documents), the seeded data model, ride pricing arithmetic, the schema, RLS policies, storage buckets, and the audited admin RPCs and dashboard reads. Notification **read state** is the exception: the feed is a real read, but marking a notification read is mock-only.

### 4. Why not just say it is finished?

Because that would be false and easy to disprove. The prototype's credibility comes from a precise boundary: the UX and architecture are demonstrable, while persistence, payments, and live dispatch are explicitly future work.

---

## B. Authentication and roles

### 5. How does authentication work?

The Flutter app uses Supabase Auth. A user signs in with a phone OTP or Google OAuth. Supabase verifies the credential and returns a session. The app then loads the profile and approved roles, maps them to capabilities, and routes the user to an available mode. There is no password login in Flutter.

### 6. Why phone OTP instead of passwords?

It fits a mobile, cash-first context, avoids password storage and reset burden, and verifies possession of the phone number. The trade-off is dependence on SMS delivery and rate limits.

### 7. Can the seeded demo accounts sign in?

No. Each demo person has an `auth.users` row with no password and `banned_until = 'infinity'`. They exist for data relationships, not login. The only unbanned hosted account is the operator's admin account.

### 8. Can that real account sign into Flutter?

Not currently through the app's phone/Google flows. It has an **email identity only**, no phone, and no linked Google identity. It can sign into the **admin dashboard** with email/password. A Flutter demo should use a phone-registered account or a linked identity.

### 9. How are roles and capabilities determined?

Approved `user_roles` rows are mapped to capabilities: `passenger` → Passenger; `earner` → Earner; `rider` → Rider + Earner; `vehicle_owner` → Vehicle Owner. The app gates modes on these capabilities, not on whether a screen exists.

### 10. What if the role read fails?

The identity loader falls back to passenger capability rather than locking a valid session out. That is a deliberate availability choice; it is logged for diagnosis.

### 11. Can a user grant themselves a role?

No. The client has no write policy on `user_roles`. Role grants happen through the auth trigger (passenger on sign-up) or an authorized admin/server process.

---

## C. Data and persistence

### 12. Is business data saved to Supabase?

Not from the Flutter app. Reads can come from Supabase in `SURGO_DATA_SOURCE=supabase`, but writes remain in `AppState`/`DbService` memory. A reload restores the seed. Notification read state is also not written back. The schema and RPCs are ready for the next phase.

### 13. What is the difference between the two data modes?

- **Default:** live Supabase Auth + local mock business data. Coherent and stable for demos.
- **Supabase data mode:** live Supabase Auth + read-only Supabase business data. Useful for verifying reads, but writes still go to memory, so the state can diverge. Notification read state is not persisted either.

### 14. Why keep writes in memory?

To demonstrate complete flows without moving money, corrupting shared demo data, or depending on a payment provider. It also keeps the defense reproducible.

### 15. How would you make writes persistent?

Move each command to a server-side transaction or `SECURITY DEFINER` RPC, validate authorization and state transitions in the database, write the ledger and status events atomically, then refresh the client from the repository layer.

### 16. How many tables are there?

30 in the local migration set. The hosted project has 26 because four financial migrations are local-only. The hosted project has 18 enums; the local set has 24.

### 17. What is missing from the hosted schema?

The financial ledger tables (`cash_collections`, `cash_payment_disputes`, `platform_fee_receivables`, `provider_fee_remittances`), six financial enums, and the financial RPCs. They are designed and locally tested but not deployed.

---

## D. Security and RLS

### 18. How is RLS configured?

RLS is enabled on every public table. The baseline grants reads only: public catalog, active pricing policies, own profile/roles/wallet/notifications, provider discovery, listed/owned vehicles, and participant-scoped ride/rental/Pasuyo rows. There are no client write policies.

### 19. Can a client write tables with the publishable key?

No. The key is public by design, but RLS and grants prevent writes. Business writes must go through a server-side function. The service role is a trusted tooling channel, not an app write path.

### 20. How does admin authorization work?

The Next.js app requires a Supabase session, then calls `is_admin()`, which checks for an approved `admin` role. Every server action re-checks this before calling an RPC. A valid non-admin session is rejected. Dashboard reads run as the signed-in `authenticated` role through migration-14's SELECT-only `admin_read_*` policies; the browser does not use a service-role key.

### 21. What prevents an admin from being spoofed?

Authorization is server-side and database-backed. The browser cannot grant itself a role, and the RPC re-checks `is_admin()` independently of the UI.

### 22. How are admin actions audited?

The five write RPCs call `_admin_audit()` and write an `admin_audit_logs` row with actor, action, entity, before/after, and reason. The authenticated role has no table-level `SELECT` grant on that table, so even an admin session receives SQLSTATE 42501; the settings page renders the panel as unavailable, and the log is read through `service_role`.

### 23. Why `SECURITY DEFINER`?

So the function can perform the authorized update even though the calling role has no direct table write grant. The function must therefore enforce its own authorization and a safe `search_path`. SurGo does both.

### 24. How are verification documents protected?

They live in private storage buckets. The admin dashboard lists folders through the signed-in admin's session and creates short-lived signed URLs (600 seconds). Missing files are reported as missing, not as a broken preview.

### 25. What are the main security risks that remain?

Compromised admin credentials, SMS interception/rate limits, document privacy, and the absence of a formal data-protection review. RLS and auditing reduce blast radius but do not replace operational security.

---

## E. Pricing and money

### 26. How is money represented?

As integer **centavos**. `Money.format` is the only renderer, and `Money.tryParsePesos` is the only parser. This avoids floating-point rounding errors.

### 27. How is the ride platform fee computed?

`platformFee = min(₱30.00, max(₱5.00, distanceKm × ₱2.00))`. The customer pays `providerFare + platformFee`. The provider keeps 100% of the provider fare.

### 28. Does the rider lose a commission?

No, not on rides. The old 10% ride commission is retired. The platform fee is a separate customer charge. `FeeRates.bpsFor(ServiceType.ride)` throws rather than returning a stale rate.

### 29. Is the distance real?

No. It is a seeded or straight-line mock distance. `TripDistance.source` records whether it came from a seeded trip or a mock place pair. No live GPS or routing result is claimed.

### 30. What about Pasuyo and rental pricing?

Both still use legacy percentage commissions: Pasuyo 15%, rental 10%. The policy is explicitly unresolved: who pays, whether it is flat or percentage, and how distance/value affects it. Do not present these as final.

### 31. How does the platform get paid?

The prototype assumes cash. A ride platform fee is recorded as **earned** at settlement and only becomes **collected** when a remittance is marked remitted. The admin finance page tracks this distinction.

---

## F. Workflows

### 32. How does ride matching work?

The passenger requests a ride; the matching screen waits 900 ms, proposes a seeded rider, and the passenger confirms. The waiting state names that rider, and after 2 seconds the rider "accepts" and the live trip opens automatically. It is a simulation of dispatch, not a real dispatch network. The Home **Recent Bookings** card is a separate repository read: it lists only terminal rides (`completed`, `cancelled`), newest first, at most three, because an open request is not yet a booking.

### 33. Is ride acceptance real?

The state transition is real and guarded by the ride state machine, but the counterparty is simulated. There is no second device or real rider.

### 34. How does live trip tracking work?

The screen renders a route and status stepper from seeded/mock coordinates. It does not consume live GPS or a routing service. The action button follows the ride's own state machine: earlier steps advance the status, and only in-progress settles. SOS and sharing show simulated notices.

### 35. How do rentals work?

The passenger browses seeded vehicles, chooses dates, sees `days × pricePerDay`, and requests a booking. A 10-second timer simulates owner approval and flips the booking to active. Date validation and the one-live-booking guard are real.

### 36. How does Pasuyo work?

A customer posts an errand with a budget. A helper accepts it and advances through purchasing and delivery states. The customer and helper see the same task. The lifecycle is in-memory, and the 15% commission is legacy.

### 37. Can the same account be customer and helper on one errand?

The app refuses self-acceptance when the customer and helper ids match. In the seeded demo, the customer and earner ids differ, so the dual view works. In a fresh live account they share one id, so a posted task cannot be accepted by the same account.

### 38. How does the wallet work?

Balances and role-specific history lists are read through the wallet repository (separate balance and `*WalletEntries` slots for passenger, earner, and owner). Top-up and cash-out mutate memory and enforce the ₱300 minimum. There is no payment gateway or payout provider.

### 39. Are notifications real-time or push?

No. The feed and unread count are repository reads, and notification ages come from each record's real `createdAt`. Mark-read is mock-only: it mutates the seeded feed, and a Supabase build does not persist it, so a badge can return after refresh. There is no push delivery or realtime subscription.

---

## G. Verification and administration

### 40. How does verification work?

Capabilities have document checklists. In Flutter, submitting moves the application through submitted → under review → approved on timers (2 s and 5 s). In the admin dashboard, a real review queue loads applications and documents, and approval/rejection runs through an audited RPC.

### 41. Why does Flutter auto-approve?

So the demo can show the full capability-unlock flow without a second operator. It is explicitly simulated and does not write to Supabase.

### 42. Is the admin dashboard connected to Flutter verification?

Not yet. A Flutter application does not appear in the admin queue, and an admin decision does not update a running Flutter session. Connecting them is future work.

### 43. What reports exist?

The reports page supports 7/14/30/90-day windows and shows new users, rides, rentals, Pasuyo, fees recorded, user growth, revenue trend, service usage, and ride demand by pickup barangay. It uses live RPCs and ride data.

### 44. Has the admin dashboard been tested in a browser against production?

Not by a full manual pass. The evidence is TypeScript unit tests, typecheck, lint, production build, PGlite SQL tests, and direct hosted read checks. The maintained hosted audit covers 127 checks and the admin-read check covers 52; both can be re-run. Treat browser behaviour as "implemented but needs verification".

### 45. Can the admin approve a real application safely?

Only with a disposable test application. Approving a real applicant changes roles and is auditable; do not do it just to demo.

---

## H. Architecture and technology

### 46. Why Flutter?

One codebase for Android, iOS, web, and desktop; strong widget control for a custom UI; good fit for a rapid, visually rich prototype.

### 47. Why Supabase?

It provides Auth, Postgres, RLS, Storage, and Realtime in one managed service, which matches the project's need for a secure, relational backend without building an auth stack from scratch.

### 48. Why Next.js for admin?

Server components and server actions keep authorization and data access on the server, which is the right model for an administrative dashboard. It also deploys easily.

### 49. How scalable is it?

The schema is normalized and indexed, and RLS scopes reads. But there has been no load test, no connection-pooling analysis, and no real-time dispatch benchmark. Scalability is a design claim, not a measured result.

### 50. Does it work offline?

The app can boot with the seed when Supabase is unreachable, but authentication is disabled in that case. There is no offline credential cache or offline write queue.

---

## I. Evaluation and contribution

### 51. What is the unique contribution?

The combination of (a) one account with three capability-gated modes, (b) a transparent ride platform-fee model, (c) a schema and RLS baseline designed for participant-scoped access, and (d) audited server-side administration in a student prototype.

### 52. How did you test it?

Flutter static analysis and 428 Flutter tests at the time of this review, 10 Node tests for the admin logic, PGlite SQL verification of migrations and demo data, TypeScript typecheck/lint/build, and read-only hosted checks. Formal usability or field evaluation is separate and must be supplied by the researcher.

### 53. What would you do next?

1. Move writes to server-side transactions/RPCs.
2. Deploy the financial ledger and activate pricing policies.
3. Integrate cash/GCash payment and remittance.
4. Add real-time dispatch and push notifications.
5. Connect verification end-to-end.
6. Run a usability and field pilot.

### 54. How would you measure success?

For the prototype: task completion, flow correctness, and security review. For a pilot: booking completion rate, time-to-match, verification turnaround, dispute rate, and user satisfaction. The specific metrics and results must come from your evaluation plan, not from this document.

### 55. What is the biggest limitation?

The persistence boundary. The experience is complete, but most business writes are not durable. That is the first thing to fix before any real deployment.

---

## J. Questions to deflect honestly

If asked something not covered:

> "That is not implemented in the prototype. The closest implemented behaviour is [X]. In production it would require [Y], and I have not measured it."

If asked for a statistic you do not have:

> "I do not have a measured figure for that. I can show the code path and the design, but I will not invent a number."

If asked whether something is live:

> "The authentication and admin reads are live. The business transaction you are describing is simulated in memory; I can show you the exact boundary in the feature audit."
