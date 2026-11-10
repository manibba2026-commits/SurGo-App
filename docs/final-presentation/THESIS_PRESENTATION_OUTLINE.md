# SurGo — Thesis Presentation Outline

**Deck length:** 15 slides. **Target defense time:** 12–18 minutes, leaving time for the live demo and Q&A.

**Rules for this outline**

- Do not invent research findings, statistics, evaluation results, or references.
- Anything marked **[RESEARCHER TO SUPPLY]** must be filled from your actual literature review, methodology, or evaluation.
- Keep claims aligned with [FEATURE_AUDIT.md](FEATURE_AUDIT.md). Say "simulated" when it is simulated.

---

## Slide 1 — Title

**Title:** SurGo: A Multi-Service Mobility and Errand Platform for Tandag City

**Main content**

- Your name, program, adviser, institution, and defense date.
- One-line description: ride booking, vehicle rentals, and Pasuyo errands in one account.
- Prototype stack: Flutter, Supabase, Next.js admin dashboard.

**Suggested visuals**

- SurGo wordmark or app splash screenshot.
- A three-panel strip: Passenger / Rider-Helper / Vehicle Owner.
- Subtle map or route motif.

**Speaker notes**

> "Good morning. I am [name], and this is SurGo — a multi-service platform that lets one person book a ride, rent a vehicle, or request a Pasuyo errand without creating three different accounts. The prototype is built in Flutter, uses Supabase for identity and data, and includes a separate web dashboard for administrators."

---

## Slide 2 — The Problem

**Title:** Fragmented Local Transport and Errand Services

**Main content**

- Residents juggle separate apps, group chats, and informal arrangements for rides, rentals, and errands.
- Small operators lack a shared digital storefront and a consistent booking record.
- Trust and verification are handled ad hoc.
- Administrators have little visibility into activity, fees, or disputes.

**Suggested visuals**

- A "before" diagram with disconnected channels: phone call, chat, tricycle stand, rental contact, errand runner.
- A simple pain-point table: passenger, rider, owner, administrator.

**Speaker notes**

> "In a city like Tandag, the services exist, but they are fragmented. A passenger may message one person for a ride, another for a rental, and a third for an errand. Riders and owners have no shared storefront, and there is no common record of who did what. SurGo asks whether one account and one platform can serve all three needs without losing trust or accountability."

> **[RESEARCHER TO SUPPLY]** Local context: current modes of transport, documented pain points, and any interviews or observations. Do not state numbers you cannot cite.

---

## Slide 3 — Objectives and Scope

**Title:** Objectives and Delimitation

**Main content**

- **General objective:** design and prototype a unified multi-service platform for rides, rentals, and Pasuyo errands.
- **Specific objectives:**
  1. One account with role-based modes.
  2. End-to-end passenger, rider/helper, and owner experiences.
  3. A verification and administration layer.
  4. A transparent pricing and fee model.
- **In scope:** UX, authentication, seeded business flows, schema/RLS, admin review.
- **Out of scope for the prototype:** real payments, live GPS, production dispatch, push notifications, full persistence of business writes.

**Suggested visuals**

- Objective → feature → evidence table.
- A scope boundary diagram: "prototype" vs "production".

**Speaker notes**

> "The goal was not to ship a production transport company. It was to prove that the workflow, the trust model, and the data architecture can be designed coherently. That is why the defense distinguishes what is implemented, what is simulated, and what is planned."

---

## Slide 4 — Context and Related Work

**Title:** Related Systems and Design Lessons

**Main content**

- Ride-hailing platforms: dispatch, fare transparency, driver/rider ratings.
- Rental marketplaces: availability, owner approval, deposits, damage handling.
- Errand/delivery services: task lifecycle, proof of purchase, fee splits.
- Local relevance: cash-first payments, informal operators, trust through verification.

**Suggested visuals**

- A comparison matrix: feature × related system × SurGo.
- A "lessons adopted" list.

**Speaker notes**

> "SurGo borrows the strongest patterns from ride-hailing, rental marketplaces, and errand services, but adapts them to a cash-first local context. The key lesson is that trust is not only a rating score; it is a combination of identity verification, clear fees, and an audit trail."

> **[RESEARCHER TO SUPPLY]** The actual literature, systems, and citations. This slide must be grounded in your reviewed sources, not generic claims.

---

## Slide 5 — Methodology and Design Approach

**Title:** Design and Development Methodology

**Main content**

- Requirements gathering: **[RESEARCHER TO SUPPLY method and participants]**.
- Role modeling: passenger, rider/helper, vehicle owner, administrator.
- Iterative prototyping: screen flows → state machines → repository layer → backend schema.
- Validation: static analysis, unit/widget tests, SQL tests, admin build/typecheck.
- Honest boundary: simulated business writes for demo safety.

**Suggested visuals**

- A development cycle: discover → model → prototype → test → refine.
- A role/capability matrix.

**Speaker notes**

> "The method was iterative. I modeled the roles and capabilities first, then built the screens and state machines, then extracted a repository layer, and finally designed the Supabase schema and admin dashboard. Each iteration ended with a check: does the code path exist, and can it be demonstrated honestly?"

> **[RESEARCHER TO SUPPLY]** The formal methodology (e.g., Agile, Design Science, Rapid Application Development), timeline, and validation instruments.

---

## Slide 6 — System Architecture

**Title:** Three-Part Architecture

**Main content**

- Flutter client: screens, `AppState`, `DbService`, repository registry.
- Supabase: Auth, Postgres, RLS, Storage, audited admin functions.
- Next.js admin: server components, `requireAdmin()`, server actions.
- Two data modes: mock business data (default) and read-only Supabase.
- Live authentication, simulated business writes.

**Suggested visuals**

- The architecture Mermaid diagram from [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md#1-architectural-summary).
- A callout: "Auth is real; business writes are in-memory."

**Speaker notes**

> "The architecture separates identity from business data. Authentication is live in Supabase. Business reads can be live, but most writes are intentionally kept in memory so the prototype can demonstrate flows without moving money or corrupting shared data. The repository registry is the seam where the remaining writes will move next."

---

## Slide 7 — Data Model and Security

**Title:** Schema, RLS, and Audited Administration

**Main content**

- 30 tables locally; 26 on the hosted project (financial migrations pending).
- Identity, catalog, rides, rentals, Pasuyo, money, engagement, admin.
- 24 enums locally; status machines mirrored in Dart.
- RLS enabled on every public table; read-only client baseline.
- No client write policies.
- Admin actions through audited `SECURITY DEFINER` RPCs.
- The admin dashboard reads as the signed-in `authenticated` role through SELECT-only `admin_read_*` policies; no service-role key in the browser.
- `admin_audit_logs` is not readable by the authenticated role (42501 by design); the settings page renders it as unavailable.

**Suggested visuals**

- Simplified ER diagram from [DATABASE_OVERVIEW.md](DATABASE_OVERVIEW.md#5-entity-relationships-simplified).
- A security layers diagram: session → `is_admin()` → RLS → RPC → audit.

**Speaker notes**

> "The security model is the strongest backend contribution. The browser and the Flutter app can read only what RLS allows. They cannot write business tables. Administrative decisions go through server-side functions that re-check the admin role and write an audit row. That is a deliberate defense against a compromised client."

---

## Slide 8 — Passenger Ride Workflow

**Title:** From Booking to Live Trip

**Main content**

- Pickup/destination, vehicle class, fare breakdown.
- Platform fee = `min(₱30, max(₱5, distance × ₱2))`; provider keeps the fare.
- Request → matching → confirmation → live trip → completion → rating.
- The waiting state names the proposed rider and opens Live Trip automatically when the simulated rider accepts.
- The Live Trip action follows the status machine (accepted → heading to pickup → arrived → in progress); only in-progress settles through `completeActiveRide`, and the rating screen reads the settled ride and driver, so history is not duplicated.
- Matching and rider acceptance are simulated on timers.
- Live trip includes status stepper, chat, share, and SOS (simulated).

**Suggested visuals**

- Booking screen screenshot.
- Fare breakdown close-up.
- Matching → live trip screenshots.
- A flow diagram from [USER_WORKFLOWS.md](USER_WORKFLOWS.md#2-passenger-ride-booking).

**Speaker notes**

> "This is the core passenger journey. The important design choice is the fare breakdown: the provider fare and the platform fee are separate, and the rider keeps the full fare. The dispatch itself is simulated for the demo, and I will say so when I show it."

---

## Slide 9 — Rider and Helper Workflow

**Title:** One Earner Mode for Rides and Errands

**Main content**

- Online/offline presence.
- Incoming ride requests and nearby Pasuyo tasks.
- Accept, advance status, complete.
- Earnings by service and withdrawal.
- Vehicle documents and verification status.
- Same account can switch modes.

**Suggested visuals**

- Rider Home screenshot.
- Accept → active trip sequence.
- Earnings breakdown screenshot.

**Speaker notes**

> "The rider and helper share one earner mode. That reduces the number of accounts and matches the reality of informal workers who take both rides and errands. The request list is seeded, and the acceptance is in-memory; the value shown is the workflow and the state machine, not a live dispatch network."

---

## Slide 10 — Vehicle Rentals and Pasuyo

**Title:** Two Additional Service Lines

**Main content**

- **Rentals:** browse, dates, total, one-live-booking guard, owner approval, active rental.
- **Pasuyo:** post, accept, purchase, deliver, complete, rate.
- **Fee splits:** rental 10% legacy, Pasuyo 15% legacy — both unresolved.
- Shared patterns: status stepper, participant-scoped data, ratings.

**Suggested visuals**

- Rental detail screenshot with date/total.
- Pasuyo stepper screenshot.
- A side-by-side lifecycle diagram.

**Speaker notes**

> "Rentals and Pasuyo reuse the same building blocks: a request, a participant, a status machine, and a settlement. Rentals add date validation and owner approval; Pasuyo adds a purchasing/delivery lifecycle. The commission rates for these two are still legacy and are explicitly marked unresolved in the pricing document."

---

## Slide 11 — Trust, Safety, and Verification

**Title:** Capability-Based Verification

**Main content**

- Capabilities: passenger, earner/rider, vehicle owner.
- Document checklists per capability.
- Approval gates mode access.
- Flutter demo: simulated 2 s → 5 s auto-approval.
- Admin: real review queue, signed document previews, audited decisions.
- **Gap:** the two workflows are not yet connected.

**Suggested visuals**

- Capability card screenshot.
- Verification state diagram.
- Admin verification queue screenshot.

**Speaker notes**

> "Trust is modeled as capabilities, not a single verified badge. A passenger can use the app immediately; a rider or owner must be approved for that capability. In the Flutter demo the review is simulated so the flow can be shown. The admin dashboard has the real review workflow, but the two are not yet wired together — that is a known limitation."

---

## Slide 12 — Administration and Reports

**Title:** Operational Visibility for Administrators

**Main content**

- Email/password sign-in; server-side `is_admin()` check.
- Dashboard reads as the signed-in `authenticated` role through SELECT-only admin policies; no service-role key in the browser.
- Dashboard: users, rides, rentals, Pasuyo, fees, attention list.
- Verification and vehicle-document review with signed previews and honest missing-file states.
- Users, vehicles, rides, rentals, Pasuyo, providers.
- Finance: cash fee remittances and transactions.
- Reports: 7/14/30/90-day windows, growth, usage, demand by barangay.
- Audit log is written by the RPCs but not readable by `authenticated` (42501 by design); the settings page shows it as unavailable.

**Suggested visuals**

- Dashboard screenshot.
- Verification queue screenshot.
- Reports charts screenshot.

**Speaker notes**

> "The admin dashboard is a separate Next.js app. It never writes tables from the browser; every decision goes through an audited server function. The reports page is intentionally operational: it shows what happened in a window, not a predictive model."

> Note: the dashboard has been verified by TypeScript tests, typecheck, lint, production build, and direct hosted read checks; the maintained audit covers 132 checks and the admin-read check covers 52. It has not had a full manual browser pass. State that if asked.

---

## Slide 13 — Prototype Demonstration and Results

**Title:** What the Prototype Demonstrates

**Main content**

- Live Supabase authentication.
- Three role experiences and shared navigation.
- Repository-backed reads for profiles, Recent Bookings, notifications, wallet history, owner fleet, and vehicle documents.
- End-to-end ride, rental, and Pasuyo flows.
- Transparent pricing and integer-centavo money handling.
- RLS and audited admin functions.
- Honest simulated boundary.

**Suggested visuals**

- A screenshot grid of the key screens.
- A "implemented / simulated / planned" matrix.
- The live demo follows this slide.

**Speaker notes**

> "The result is a prototype that demonstrates the full user experience and a security architecture that is ready for real writes. It does not claim production payments, live GPS, or two-device dispatch. The next slide states exactly what remains."

> **[RESEARCHER TO SUPPLY]** Formal evaluation results: usability scores, test coverage, performance measurements, participant feedback, or expert review. Do not fabricate these.

---

## Slide 14 — Limitations and Future Work

**Title:** Limitations and the Next Phase

**Main content**

- Business writes are in-memory; reload resets.
- No payment gateway, payout, escrow, or refunds.
- No live GPS, routing, or real-time dispatch.
- No push notifications.
- Notification read state is not persisted in Supabase data mode.
- Flutter verification and admin verification are disconnected.
- Pasuyo and rental pricing unresolved.
- Hosted project lacks the four financial migrations.
- The audit-log panel is unavailable to the authenticated role by design; reading it needs the service-role channel.
- Admin dashboard needs a full browser pass.

**Future work**

1. Move each write to a server-side transaction/RPC.
2. Deploy the financial ledger and activate pricing policies.
3. Integrate a cash/GCash payment and remittance workflow.
4. Add real-time dispatch and push notifications.
5. Connect verification end-to-end.
6. Run a usability and field pilot.

**Suggested visuals**

- A "now / next / later" roadmap.
- A risk matrix.

**Speaker notes**

> "The limitations are deliberate and documented. The most important next step is not more screens; it is moving the write paths to the server and deploying the financial ledger. That is what turns a convincing prototype into an accountable service."

---

## Slide 15 — Conclusion and Recommendations

**Title:** Conclusion

**Main content**

- SurGo shows that rides, rentals, and errands can share one account and one trust model.
- The strongest contributions are the unified UX, capability-based verification, transparent ride pricing, RLS, and audited administration.
- The prototype is honest about its simulated boundary.
- Recommendation: proceed to a server-side write layer and a limited field pilot before adding more features.

**Suggested visuals**

- Three takeaway cards.
- A final architecture or journey image.
- Thank-you / questions slide.

**Speaker notes**

> "To conclude: SurGo is a coherent, working prototype of a multi-service platform, with real authentication, a real schema and security model, and a clear path to production. It is not yet a production transaction system, and the documentation says so. I recommend the next phase focus on persistence, payments, and a field pilot. Thank you — I am ready for your questions."

---

## Appendix slides (optional, not counted)

Use only if the panel asks:

- A1. Fare formula and money handling.
- A2. RLS policy matrix.
- A3. Admin RPC list and audit model.
- A4. Hosted-vs-local migration state.
- A5. Seed-data caveats.
- A6. Live demo recovery plan.

## Researcher-supplied checklist

Before presenting, fill or confirm:

- [ ] Formal problem statement and local context.
- [ ] Literature review and citations.
- [ ] Methodology and timeline.
- [ ] Participants/instruments for requirements gathering.
- [ ] Evaluation design and results.
- [ ] Ethical considerations and data privacy statement.
- [ ] Adviser and panel formatting requirements.
- [ ] Institution-specific title slide details.
