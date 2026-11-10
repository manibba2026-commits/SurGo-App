# SurGo database foundation

PostgreSQL schema for SurGo, managed with the Supabase CLI. The pilot market is
Tandag City, Surigao del Sur; the payment method for the pilot is cash.

This directory is infrastructure only. The schema is applied to the hosted
project. The Flutter app and the admin dashboard read through the repository
layer and the audited RPCs; they never hold a service-role key.

## Migrations

Apply in filename order. Each migration is a single concern and assumes the
previous one ran.

| # | File | Purpose |
| - | ---- | ------- |
| 1 | `20261106090000_helpers.sql` | `set_updated_at()` trigger helper |
| 2 | `20261106090100_enums.sql` | 18 status/type enums mirroring the Dart models |
| 3 | `20261106090200_catalog_and_pricing.sql` | `service_areas`, `barangays`, `puroks`, `pricing_policies` |
| 4 | `20261106090300_identity_and_verification.sql` | `profiles`, `user_roles`, `provider_profiles`, `vehicles`, `vehicle_documents`, `verification_applications`, `verification_documents` |
| 5 | `20261106090400_rides.sql` | `ride_requests`, `ride_status_events`, `ride_locations`, `ride_ratings` |
| 6 | `20261106090500_rentals.sql` | `rental_bookings` |
| 7 | `20261106090600_service_requests.sql` | `service_requests`, `service_request_items`, `service_status_events` |
| 8 | `20261106090700_money.sql` | `service_transactions`, `wallet_accounts`, `wallet_transactions`, `cash_fee_remittances` |
| 9 | `20261106090800_engagement.sql` | `notifications`, `device_tokens`, `admin_audit_logs` |
| 10 | `20261106090900_auth_profile_trigger.sql` | profile + passenger role on `auth.users` insert; email/phone/name sync on update |
| 11 | `20261106091000_storage_buckets.sql` | `avatars`, `verification-documents`, `vehicle-documents` buckets and owner-path policies |
| 12 | `20261106091100_realtime_publication.sql` | adds live tables to `supabase_realtime` |
| 13 | `20261106091200_rls_baseline.sql` | read-own/catalog RLS plus access helper functions |
| 14 | `20261106091300_admin_dashboard_access_and_actions.sql` | `is_admin()`, admin read policies, the five review RPCs, `admin_overview`/`admin_daily_activity` |
| 15 | `20261106130000_security_hardening.sql` | least-privilege grants, pinned `search_path`, hardened default privileges |
| 16 | `20261106140000_pricing_versions.sql` | versioned policies, fee modes/types and immutable approved terms |
| 17 | `20261106140100_financial_ledger.sql` | pricing snapshots, cash collections, disputes, receivables, remittances, RLS |
| 18 | `20261106140200_financial_rpc.sql` | server-side pricing, settlement, cash, dispute and remittance RPCs |
| 19 | `20261106140300_financial_reporting.sql` | provider earnings and platform revenue views |
| 20 | `20261110100000_verification_submission.sql` | applicant-side verification submission RPC |
| 21 | `20261110120000_verification_review_integrity.sql` | approval requires every document approved; decided applications freeze their documents |
| 22 | `20261111100000_account_management.sql` | admin profile edits, role grant/revoke/suspend, admin-managed documents |
| 23 | `20261111120000_attachments.sql` | private `attachments` bucket, metadata table, RPCs and storage policies |

Row 14 is a **verbatim copy** of SQL that is already on the hosted project under
a different timestamp — see [Admin dashboard migration sync](#admin-dashboard-migration-sync).

All 31 business tables use UUID primary keys, `timestamptz` timestamps and
`bigint` centavos. Every mutable table has an `updated_at` trigger.

## Money and pricing

- Amounts are integer centavos (`bigint`), currency `PHP`, and all pricing,
  fees and totals are calculated server-side.
- `pricing_policies` is versioned per service type. A new row gets the next
  `version`; approved commercial terms are immutable, so a change requires a
  new version. Only one policy per service type may be active, and a policy can
  only be active when it has an `approved_at` and `effective_from`.
- `platform_fee_mode` controls how the fee is charged:
  - `customer_addon`: `customer_pays = fare + platform_fee`,
    `provider_payout = fare`
  - `provider_deduction`: `customer_pays = fare`,
    `provider_payout = fare - platform_fee`
- `platform_fee_type` is `fixed`, `distance` (per-km fee) or `percentage`
  (basis points of the fare). Minimum and maximum fee bounds apply after
  half-up centavo rounding.
- `service_transactions` also enforces:
  - `provider_payout + platform_revenue = customer_pays`
  - `provider_payout <= fare`
  - exactly one of `ride_id`, `rental_id`, `service_request_id`
  - one settlement row per service (partial unique indexes)
- `settle_service_transaction()` is idempotent: a repeated settlement returns
  the original row rather than charging twice. Each completed row stores an
  immutable JSONB pricing snapshot and cannot be updated or deleted.
- Cash is the only `payment_method`. `cash_collections` records the cash the
  customer handed to the provider; confirmation requires the exact expected
  amount. Confirmed provider cash never credits a wallet or SurGo revenue.
- `platform_fee_receivables` records the fee the provider still owes from cash
  already collected. `provider_fee_remittances` records a provider's claim that
  it remitted cash. Only an admin-verified remittance increases
  `amount_remitted_centavos`; submitted or rejected claims do not count as cash.
- `cash_payment_disputes` allows one live dispute per transaction. An open
  dispute marks the receivable `disputed` and blocks new remittances until an
  admin resolves or rejects it.
- Reporting views: `provider_earnings_summary`, `platform_revenue_daily` and
  `platform_revenue_summary`. They use `security_invoker`, so normal RLS still
  applies to the caller.
- Real wallet top-ups, withdrawals and payment-gateway integration are **not**
  implemented. The legacy `cash_fee_remittances` table remains in the schema,
  but the new cash flow uses receivables plus verified remittances.

`pricing_policies` is intentionally **empty** in the seed and no policy is
activated by any migration. There is no seeded ₱3/km policy, no assumed
commission rate and none of the old 10%/15%/10% defaults. The values in the SQL
tests are test fixtures only. Activating a production policy is a deliberate,
reviewed data change after explicit developer approval.

## Identity

`auth.users` owns credentials and OTP/Google identity. The trigger
`public.handle_new_auth_user()` creates:

- one `profiles` row, using `full_name` / `name` / `given_name` + `family_name`
  metadata, then the email local part, then the phone number, then `SurGo User`
- one **approved** `passenger` role

Provider roles (`earner`, `rider`, `vehicle_owner`) are never granted by the
signup trigger. They come from the verification workflow. `user_roles` has a
unique `(profile_id, role)` constraint, so duplicate roles are impossible.

## Seed

`seed.sql` creates exactly:

- 1 service area: Tandag City, Surigao del Sur (`9.0785, 126.1985`)
- 21 barangays
- 115 puroks

It contains **no users, no demo credentials and no pricing policies**. IDs are
derived with `md5('surgo:...')::uuid`, so re-running the seed does not duplicate
geography. Local sample users in `assets/db/users.json` and
`assets/db/accounts.json` are deliberately not migrated.

## Demo data

`assets/db/*.json` is the mock dataset the Flutter app paints in dev mode. It is
an **import input**, not a runtime source: the app never reads those files from
the database, and `demo-data.sql` is generated from them.

```
assets/db/*.json  ->  supabase/tools/gen_demo_data.mjs  ->  supabase/demo-data.sql
                                                        ->  supabase/tests/verify_demo.mjs   (PGlite, twice)
                                                        ->  supabase/tools/apply_demo_data.mjs (hosted)
```

`demo-data.sql` is one `begin; … commit;` block of upserts keyed by deterministic
UUIDs (`md5('surgo:demo:<kind>:<key>')::uuid`), so re-running it converges to the
same rows instead of duplicating them. It lives outside `migrations/` and
`seed.sql` so no demo row can reach a production deploy by accident.

Applied to `lrhgktxmavnhjatqzbzr` on 2026-11-06 after local PGlite validation.
Totals are what the hosted project holds now, so they include the real
account's own `profiles` / `user_roles` rows on top of the 19 demo people:

| table | rows | table | rows |
| ----- | ---- | ----- | ---- |
| `profiles` | 20 | `service_requests` | 20 |
| `user_roles` | 60 | `service_request_items` | 23 |
| `provider_profiles` | 15 | `service_transactions` | 29 |
| `vehicles` | 14 | `wallet_accounts` | 11 |
| `vehicle_documents` | 5 | `wallet_transactions` | 79 |
| `verification_applications` | 3 | `notifications` | 25 |
| `verification_documents` | 8 | `ride_requests` | 19 |
| `rental_bookings` | 16 | | |

Rules the generator follows:

- **One profile per person.** `P001` / `R001` / `VOW-77213` in the JSON are the
  same human, so they collapse into one `profiles` row with several `user_roles`
  and `provider_profiles` entries. 11 roster people + 8 archived accounts = 19.
- **Demo accounts cannot sign in.** Each gets an `auth.users` row with no
  password and `banned_until = 'infinity'`; the trigger-created profile is then
  overwritten by the imported row (`on conflict (id) do update`).
- **Per-user scoping, not per-user databases.** All 19 people share the same 30
  tables; the RLS read-own policies scope every query through `auth.uid()`, so an
  account only sees its own profile, roles, wallets, ledger and notifications
  plus the rides, rentals and Pasuyo jobs it actually participates in. Separate
  databases per user would break the foreign keys and the admin dashboard.
- **The real account is never touched.** The operator's admin account (supplied
  through `SURGO_REAL_USER_ID` / `SURGO_REAL_USER_EMAIL`) stays unbanned with
  its own roles; the demo roster's Jr uses `jr.derigay@email.com`.
  `apply_demo_data.mjs preflight` aborts if those variables are unset or if that
  row is missing or changed.
- **Cash only.** `payment_method` stays `cash`; GCash/Maya mentions from the
  JSON are preserved in the row's `note`.
- **Wallets reconcile by construction.** Each account is seeded with an opening
  `adjustment` derived from the JSON balance minus its ledger, plus two final
  corrections (`P002`, `P005`). The generator throws if the ledger does not end
  at `wallet_accounts.balance_centavos`.
- **No platform fees.** Every `service_transactions` row uses
  `platform_fee_centavos = 0` and pays the provider the full fare, because
  `pricing_policies` is still empty and no pricing policy is approved for
  activation. `verify` re-checks this on the hosted project. What the shipped
  pricing logic *would* have earned on those 29 settlements is
  **₱1,923.50** — ₱1,590.00 rental commission (10%), ₱268.50 Pasuyo commission
  (15%) and only ₱65.00 of ride platform fees, because all 13 imported rides
  carry `distance_km = 0` and so fall to the ₱5.00 floor. `--fees` recomputes
  that per transaction; nothing is written while pricing stays gated.
- **Ownership follows foreign keys, not JSON labels.** A rental booking's
  `owner_id` is the vehicle's real owner even when the JSON names someone else;
  `RV001` belongs to `alex-tan`, `RV002/003/008/013/014` to `rico-d`, the rest to
  `ACC001`. `RV005` keeps `service_area_id = null` because its plate duplicates
  `NGD 6612` under the partial unique index.
- **Ratings below 1 are clamped to 1.00** and relative labels ("Just now",
  "Yesterday") are anchored to 2026-11-06T12:00Z so re-runs are stable.
- Anything the JSON cannot express honestly is left out rather than invented: no
  records exist beyond what the mock files describe.

Deliberately **not** imported, because no table models them (or they are device
state):

- `assets/db/config.json` — rates and fare rules; owned by the pricing phase,
  which is on hold until settlement/payout merges.
- favorites, saved places, free-form places, emergency contacts — device-local.
- payment methods (the schema allows `cash` only), account settings.
- `assets/db/manifest.json` — import bookkeeping.
- `ride_ratings` and earnings aggregates — the JSON stores a single per-user
  average, which is derived data; the tables would need real per-trip ratings.

Verification:

```bash
node supabase/tests/verify_demo.mjs    # PGlite: migrations + seed + demo-data.sql, twice
cd supabase/tests && npm test          # tracked schema tests stay green (9 files)
node supabase/tools/apply_demo_data.mjs preflight   # read-only hosted check
node supabase/tools/apply_demo_data.mjs apply       # chunked upserts
node supabase/tools/apply_demo_data.mjs verify      # counts, real user, wallet balance match
node supabase/tools/apply_demo_data.mjs auth        # auth roster: demo banned, real user not
node supabase/tools/audit_hosted.mjs                # 132 read-only integrity checks
node supabase/tools/audit_hosted.mjs --fees         # + the fee each settlement would owe
```

`apply_demo_data.mjs` uses the Supabase Management API SQL endpoint with the
access token the Supabase CLI already keeps in the Windows Credential Manager; it
posts no service-role key, prints no token, and the hosted project has no
`db push` of these rows. The demo SQL was generated before the financial
migrations reached the host and references none of their columns
(`pricing_snapshot`, `fee_mode`, `fee_type`, `distance_km`, `duration_minutes`).

### Hosted audit

`audit_hosted.mjs` shares the same read-only channel (`db_admin.mjs`) and runs
132 checks: the documented counts, an id-by-id comparison of every table against
the ids in `demo-data.sql` (so a re-import cannot have duplicated a row), FK
orphans in both directions, the role → provider → vehicle → wallet graph, wallet
ledger replay, settlement coverage against the service rows it points at, the
eight archived accounts, and the real account's untouched state. It also prints
the remote migration history: 15 rows, every one of which now has a local file —
`20261106062246_admin_dashboard_access_and_actions` is kept in the repo under the
retimed name `20261106091300`, so the audit reports that single known ledger
version drift instead of a remote-only migration, and the four
`2026110614xxxx` financial migrations are the only local-only files.

Four results are inconsistencies in the imported source data, not import damage,
and the audit reports them as `NOTED` instead of hiding them:

- **An approved `vehicle_owner` role with no listed vehicle** (Isabella Dizon,
  and the demo `Jr Derigay`). Capability verification is account-level, so a
  verified owner who happens to list nothing is legal.
- **Edwin Santillan earns without an approved earner role.** His JSON
  capabilities are `pending`, yet the history gives him a provider row, an earner
  wallet at ₱2,035.00 and a completed Pasuyo settlement. A real signed-in flow
  could not reproduce that, so Stage 3 must not assume every earner wallet has an
  approved role behind it.
- **Three ledger rows replay out of order.** The demo `Jr Derigay` earner wallet
  has two entries in the same second (`2026-08-29T00:00:00Z`);
  `balance_after_centavos` was written in JSON array order, so replaying by
  `(created_at, id)` swaps them. Net sum and closing balance both reconcile — the
  wallet ledger simply has no sequence column, which Stage 3 writes will need.

## RLS baseline

RLS is enabled on all 31 tables. The baseline only grants reads:

- catalog (`service_areas`, `barangays`, `puroks`) to any signed-in user
- the active `pricing_policies` row
- own profile, roles, wallet, ledger, notifications and device tokens
- participants of a ride, rental or Pasuyo request
- the customer/provider on a cash collection, dispute, receivable or remittance
- active vehicle listings plus a user's own vehicles
- audit logs: no baseline policy, so only `service_role` can read them

No INSERT/UPDATE/DELETE policies exist. Mobile writes should go through reviewed
RPCs, and the admin dashboard only ever calls the audited `admin_*` RPCs as the
signed-in `authenticated` role — migration 14's ten `admin_read_*` policies and
its `surgo admin read documents` storage policy are SELECT-only and gated on
`public.is_admin()`, which is why the dashboard needs no table writes and no
service-role key in the browser.

`admin_audit_logs` keeps one deliberate asymmetry: migration 14 adds an
`admin_read_audit_logs` policy for it, but the hardening migration withholds the
table-level `SELECT` grant from `authenticated` for that single table, and a
policy cannot substitute for a privilege. So even an admin session gets
`permission denied for table admin_audit_logs` (SQLSTATE 42501) from PostgREST;
the log is written by the `SECURITY DEFINER` RPCs and readable only through
`service_role`. Local test 09 asserts that denial stays true instead of working
around it, and `verify_admin_reads.mjs` reports the table as
`privilege withheld by design` so the asymmetry cannot silently change.

## Privilege hardening

The baseline revoked function EXECUTE from `PUBLIC` only; Supabase's default ACL
had also granted it explicitly to `anon`, and granted ALL on every table. The
hardening migration fixes the grants:

- `anon`: no table privilege, no sequence privilege, no function EXECUTE.
- `authenticated`: `SELECT` on every table except `admin_audit_logs` (no client
  grant at all), and EXECUTE on only the eight RLS helpers. No writes.
- `service_role`: full access, unchanged.
- `set_updated_at` pins `search_path = ''` and has no direct EXECUTE; triggers
  still fire because runtime trigger invocation does not check the privilege.
- Default privileges for future `postgres`-owned objects match the above, so a
  new RPC must be granted EXECUTE explicitly in its migration.

Eight `authenticated_security_definer_function_executable` advisor warnings
remain by design: RLS policies call those helpers as the signed-in role, so
revoking EXECUTE would make every protected read fail. They return booleans and
never row data.

## File attachments

`20261111120000_attachments.sql` adds one private bucket and one metadata table.
The bytes live in Supabase Storage; the database stores only the pointer and the
facts needed to validate it. There is no base64 column and no file is ever
written to the `public` schema.

| piece | rule |
| ----- | ---- |
| bucket | `attachments`, `public = false`, `file_size_limit = 20971520` |
| object name | `<owner_profile_id>/<timestamp>-<random>.<ext>` |
| table | `public.attachments` (`owner_profile_id`, `bucket_id`, `storage_path`, `file_name`, `mime_type`, `size_bytes`, generated `category`, `label`, `uploaded_by`) |
| read | owner (`owner_profile_id = auth.uid()`) or `public.is_admin()`; `SELECT` only |
| write | only `register_attachment`, `replace_attachment`, `delete_attachment` |
| link | short-lived signed URL (5 minutes in both clients) |

The allowlist is repeated in three places that must stay in sync: the bucket's
`allowed_mime_types`, `public.attachment_mime_allowed()` (used by the table check
constraint and the RPCs), and the client-side extension maps. It covers PDF,
DOC/DOCX/RTF/TXT, XLS/XLSX/CSV, PPT/PPTX, raster images (JPEG/PNG/WebP/GIF/
HEIC/HEIF/BMP/TIFF), ZIP, audio and video. **SVG is deliberately excluded** — a
signed URL can render it as an active document in a browser. The 20 MB limit is
enforced by the bucket, `attachments_size_check` and every RPC, so a client
cannot raise it.

Why writes are RPC-only:

- `attachments` grants `authenticated` only `SELECT`. Direct
  INSERT/UPDATE/DELETE is revoked, so a signed-in account cannot invent a row
  that points at a missing object or another person's path.
- `_attachment_validate()` re-checks the owner profile, the
  `<owner>/...` prefix, the file name, the MIME type and the size, and then
  confirms the object exists in `storage.objects`. When Storage recorded
  `metadata->>'size'` / `metadata->>'mimetype'`, those must match too.
- `register_attachment` upserts on `(bucket_id, storage_path)` but refuses to
  take over a path owned by a different profile.
- `replace_attachment` returns the previous path; `delete_attachment` returns
  the removed path. The caller removes the now-unreferenced object.
- Admin actions (`v_uid <> owner_profile_id`) are written through
  `_admin_audit()` as `attachment.registered`, `attachment.replaced` and
  `attachment.deleted`.

Storage policies mirror the verification buckets: an account may read, insert,
update and delete only inside its own top-level folder, and an admin may do the
same in any folder. Both clients upload bytes **first**, call the RPC **second**,
and remove the just-uploaded object if the RPC fails, so a failed metadata write
cannot leave a phantom row. A successful RPC followed by a failed read-back
throws instead of deleting anything, because the row is already committed.

Client entry points:

- Flutter: `lib/repositories/attachment_repository.dart` (validation, upload,
  replace, delete, orphan cleanup) and `lib/screens/attachments_screen.dart`
  (**Profile → My Files**). The repository chooses the storage path, so a caller
  cannot file bytes under another account's folder. Progress is stage-based
  (`uploading` → `recording`) because the SDK does not expose byte progress.
  `MockAttachmentRepository` throws `RepositoryFailure.unsupported`; it never
  fakes a successful upload.
- Admin: `lib/admin/src/components/AttachmentsManager.tsx` on the user detail
  page (**Files** panel), backed by `registerAttachment` / `replaceAttachment` /
  `deleteAttachment` in `app/actions.ts`. Uploads use the signed-in admin's own
  session; the service-role key stays server-only and is never sent to the
  browser. On an environment where the migration has not been applied,
  `attachmentsForProfile()` returns `null` and the panel says so instead of
  breaking the page.

Both clients accept multiple files, show per-file progress, preview images
in-app, and open everything else through a short-lived signed URL. There is no
public URL for this bucket.

## Running locally

The standard Supabase path needs Docker:

```bash
npx supabase start
npx supabase db reset          # migrations + seed
npx supabase test db           # pgTAP, if added later
```

This workstation cannot run the local stack: Docker Desktop needs the WSL2
backend, and Windows fails to enable `VirtualMachinePlatform` with
`0x80073712` (component store corrupted). The hosted project is therefore the
only available target for now, and `supabase/tests/` is the local verifier. It
executes the real migration files against PGlite with small Supabase stubs
(`auth.users`, `auth.uid()`, storage, roles, realtime publication):

```bash
cd supabase/tests
npm install
npm test
```

The harness boots the schema twice (fresh and reset), applies the seed twice,
then runs the SQL tests in `supabase/tests/sql/`.

Current result: **23 migrations + seed + 12 SQL test files pass on both runs.**

Supabase grants default privileges to `anon`/`authenticated`/`service_role` when
an object is created. The harness simulates that immediately before the first
migration that revokes it again — `DEFAULTS_MARKER` in `tests/run.mjs` and
`tests/verify_demo.mjs` names `admin_dashboard_access_and_actions`, the end of
the baseline. Placing the simulation after that file would hand `anon` back the
EXECUTE the admin migration had just revoked, and the local privileges would stop
matching the hosted project (`anon_rpc: false`, `auth_rpc: true`).

The tests cover:

- exactly 31 tables, 24 enums and RLS on every table
- FK integrity across purok → barangay → service area
- purok/barangay mismatch, cross-area references and owner/vehicle mismatch
- invalid statuses, negative money, zero quantities and timestamp requirements
- rating range, duplicate rating, duplicate open verification applications
- settlement conservation, payout-over-fare, multi-service and double settlement
- wallet duplicate accounts, zero movements, negative balances, duplicate remittances
- server-side pricing: fail-closed missing policy, half-up rounding, fixed/distance/percentage fees, min/max bounds, versioning and immutable approved terms
- idempotent cash settlement, immutable snapshots, exact-amount confirmation, cash failures and disputes
- provider cash never crediting a wallet; submitted/rejected remittances never counting as SurGo cash
- partial and complete remittance, rejection, overpayment, zero/negative amounts and duplicate references
- provider earnings and platform revenue reconciliation across the reporting views
- pricing activation approval, one active policy, hidden inactive policy
- auth profile creation, duplicate role prevention and profile sync
- RLS read-own visibility and blocked writes
- anon denied all table/function access; authenticated SELECT-only grants
- RLS helper EXECUTE kept for authenticated, removed for anon and trigger functions
- hardened default privileges for future tables, functions and sequences
- storage folder isolation and audit-log isolation
- admin RPC EXECUTE boundary: authenticated-only, `_admin_audit` not callable
  directly, every admin function pins `search_path = ''`
- admin review decisions: reason rules, resubmission, re-deciding a decided
  application, the granted capability role, `approved_by`, untouched passenger
  role and the audit row per decision
- the per-person verification read shape the dashboard uses, including a
  referenced document whose storage object is absent
- `admin_overview()` pending counts and `admin_daily_activity(7)` day rows
- verification submission from the applicant side, including the decided-application freeze
- admin account management: profile edits, role grant/revoke/suspend, the
  approved-verification gate for rider/owner roles, and admin-managed documents
- attachments: bucket limits and allowlist, owner/admin read RLS, direct writes
  denied, `_attachment_validate()` rejecting a foreign folder, wrong MIME,
  oversized or missing objects, the admin audit rows, and storage folder isolation
- seed counts, deterministic IDs and idempotent re-seeding
- `updated_at` trigger behavior

## Admin dashboard migration sync

The admin dashboard's SQL lived only on the hosted project: it was applied as
`20261106062246_admin_dashboard_access_and_actions` before this repo tracked it,
so `supabase/migrations/` had no file for it and a fresh local `db reset` could
not reproduce verification review. Migration 14 is now that same SQL, stored
verbatim in the repo.

**It is a copy, not a change.** Nothing was applied to, or reverted on, the hosted
database to create it. `node supabase/tools/verify_migration_sync.mjs` reads the
statement back out of `supabase_migrations.schema_migrations` and compares it
byte-for-byte with the local file (currently 13,538 bytes, one statement), so the
copy cannot silently drift from what the host runs.

**One deviation: the timestamp is not the original.** Requirement was to keep
`20261106062246`; that filename sorts before `090100_enums.sql`, and the SQL
cannot run there. Applying it at the original position fails with
`type "public.user_role_type" does not exist`, because it needs:

| needs | provided by |
| ----- | ----------- |
| `user_role_type` (`'admin'` literal) | `20261106090100_enums.sql` |
| `verification_applications`, `verification_documents`, `vehicles`, `profiles`, `user_roles`, `admin_audit_logs` | `20261106090300` / `090400` / `090500` / `090600` / `090800` |
| `has_approved_role()` (behind `is_admin()`) | `20261106091200_rls_baseline.sql` |
| `storage.objects` + the two document buckets | Supabase's own `storage` schema + `20261106091000_storage_buckets.sql` |

`20261106091300` is the first slot that satisfies all four and still lands before
`20261106130000_security_hardening.sql`, which only *excludes*
`admin_audit_logs` from its blanket SELECT grant and never depends on these
functions. So the retimed file changes **ordering only** — the SQL text is
unchanged, and the hosted ledger still says `20261106062246`.

Consequences to keep in mind:

- `npx supabase migration list` will show this one file as version drift. That is
  expected and is exactly what `audit_hosted.mjs` reports as
  `history: known ledger version drift` (1 row). Do **not** "fix" it with
  `migration repair` or by renaming the local file without a decision; renaming
  to `062246` would break `db reset` again.
- Never `db push --remote --include-all` here: the local-only financial
  migrations (16-19) are not approved for the host, and a push would also try to
  reapply migration 14 under the new version.
- There are no remote-only dependencies outside the table above. Everything the
  host had when this SQL was applied is tracked locally.

Local verification that the synced file really reproduces review:
`supabase/tests/sql/09_admin_verification_review_test.sql` (runs on both the fresh
and reset boots) covers the EXECUTE boundary of the eight admin functions, the
per-role RLS read counts, non-admin denial leaving no audit row, the document and
verification decision paths including the `needs_resubmission` reason rule and the
granted capability role, and `admin_overview()` / `admin_daily_activity(7)`.

`node supabase/tools/verify_admin_reads.mjs` closes the other half of the loop. It
walks every `.from(...).select(...)` in `lib/admin/src` — currently 32 select
strings across the whole dashboard — and validates each column and PostgREST embed
against the **hosted** catalog, then checks every table those reads touch for what
the `authenticated` role actually holds: a table privilege, RLS enabled, and at
least one SELECT policy an administrator satisfies for someone else's rows. That
last part matters because a read can be perfectly typed and still return an error
(no privilege) or an empty list (no policy) in the browser. It is read-only and
reports `ADMIN READS OK: 52 checks against the hosted database`.

## Applying to the hosted project

The first 14 migrations (1-13 plus security hardening) were applied on
2026-11-06 to project `lrhgktxmavnhjatqzbzr`: 14/14 migrations, 26 tables, the
Tandag seed (1 service area, 21 barangays, 115 puroks), and 3 storage buckets.
The baseline hardening reduced security advisors from 21 WARNs to the 8 expected
RLS-helper notices. Migration 14 reached the host through a different route and
under a different version — see
[Admin dashboard migration sync](#admin-dashboard-migration-sync).

The hosted project stopped at migration 15
(`20261106130000_security_hardening`) until 2026-11-11. On that date the
remaining eight migrations were applied in filename order through the Management
API SQL channel, with each repo version recorded in the ledger:

| # | File | Adds |
| - | ---- | ---- |
| 16 | `20261106140000_pricing_versions` | versioned pricing policies |
| 17 | `20261106140100_financial_ledger` | cash collections, disputes, receivables, remittances |
| 18 | `20261106140200_financial_rpc` | settlement, cash, dispute and remittance RPCs |
| 19 | `20261106140300_financial_reporting` | provider earnings and platform revenue views |
| 20 | `20261110100000_verification_submission` | applicant verification submission RPC |
| 21 | `20261110120000_verification_review_integrity` | document-approval gate and decided-application freeze |
| 22 | `20261111100000_account_management` | admin profile/role/document write paths |
| 23 | `20261111120000_attachments` | `attachments` bucket, table, RPCs and storage policies |

The hosted schema now has 23 migrations, 31 tables, 24 enums, 24 `updated_at`
triggers and 4 storage buckets. None of the migrations seeds or activates a
pricing policy. The 29 existing `service_transactions` rows and the demo roster
were left untouched, and `public.attachments` starts empty.

The attachment feature depends on migration 23. On any environment where it has
not been applied, `storage.buckets` has no `attachments` row and PostgREST has no
`public.attachments` table; the Flutter screen reports the failure and the admin
Files panel shows the feature as unavailable. Neither client fakes a success.

`login` and `link` are interactive and must be run in a normal terminal (the CLI
refuses the browser flow in non-TTY shells). The database password is entered at
the prompt and is never stored in the repo.

```bash
npx supabase login
npx supabase link --project-ref lrhgktxmavnhjatqzbzr
```

CLI 3.0.0 links through the session pooler by default, which works on IPv4-only
networks. `db push` targets the local stack unless `--remote` is passed. Review
the change set without writing anything first:

```bash
npx supabase migration list --remote
npx supabase db push --remote --dry-run
```

`--include-seed` also applies `seed.sql`; the seed is idempotent, so re-running
it is safe. Only run the real push after explicit approval:

```bash
npx supabase db push --remote
```

Before the push, confirm the hosted `public` schema is empty. This repo creates
`public.profiles`, so an existing quickstart `profiles` (or any table with the
same name as one of the 31) must be dropped or renamed first, otherwise the push
fails midway. `todos` from a quickstart can stay; it is unrelated. The hosted
project was empty at push time, so no collision check was needed.

The auth trigger only fires for users created after the migration. If the hosted
project already has `auth.users` rows, backfill them once after the push:

```sql
insert into public.profiles (id, full_name, first_name, email, phone)
select u.id,
       coalesce(
         nullif(trim(coalesce(
           u.raw_user_meta_data ->> 'full_name',
           u.raw_user_meta_data ->> 'name',
           concat_ws(' ', u.raw_user_meta_data ->> 'given_name',
                          u.raw_user_meta_data ->> 'family_name')
         )), ''),
         nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
         nullif(u.phone, ''),
         'SurGo User'
       ),
       nullif(trim(coalesce(
         u.raw_user_meta_data ->> 'given_name',
         u.raw_user_meta_data ->> 'first_name'
       )), ''),
       u.email,
       u.phone
from auth.users u
on conflict (id) do nothing;

insert into public.user_roles (profile_id, role, status, approved_at)
select id, 'passenger', 'approved', now() from public.profiles
on conflict (profile_id, role) do nothing;
```

Run `db push` only after the migration diff has been reviewed and the schema
change approved. The Flutter app initializes this project at boot with the
publishable key (`lib/services/supabase_bootstrap.dart`) but every screen still
reads its in-memory `AppState`; moving screens onto the database is a separate
change.
