# SurGo Admin Dashboard

Next.js 14 · TypeScript · Tailwind · Supabase (Auth + Postgres RLS). Runs locally; no deployment config.

## Run

```bash
cp .env.example .env.local      # public URL + publishable key only
npm install
npm run dev                      # http://localhost:3100
npm run typecheck && npm run lint && npm run build
npm test                         # node --test src/**/*.test.mts
```

`npm test` runs the 10 pure-TypeScript unit tests (storage-existence lookup and
labels, the verification bundle shape, and result unwrapping) against a stubbed
Supabase client. They need no database and no credentials.

## Create the first administrator (one time, done by you in the database)

Admin roles can only be granted in the database; the dashboard cannot grant them.

1. Supabase Dashboard → Authentication → Users → **Add user** (email + password, auto-confirm).
2. SQL Editor (replace the email):

```sql
insert into public.user_roles (profile_id, role, status, approved_at)
select id, 'admin', 'approved', now() from public.profiles where email = 'you@example.com';
```

If `profiles` has no row for that user, the `on_auth_user_created` trigger did not run; check the user's email matches.

## Security model

- Browser holds only the anon/publishable key. The service-role key is never used.
- Every page runs server-side as the signed-in user, so Postgres RLS applies. Admin read access comes from `public.is_admin()` policies (migration `admin_dashboard_access_and_actions`; locally `supabase/migrations/20261106091300_admin_dashboard_access_and_actions.sql`, the same SQL the host applied as `20261106062246`).
- Admin writes go only through audited `SECURITY DEFINER` RPCs that re-check `is_admin()`:
  `admin_review_verification`, `admin_review_document`, `admin_set_account_status`, `admin_set_vehicle_status`, `admin_update_remittance`.
  Each writes to `admin_audit_logs`. An admin cannot suspend their own account.
- Document previews use 10-minute signed URLs created server-side under an admin-only storage read policy.
- Query failures show an error page. The dashboard never falls back to mock data.

## Verification review

`src/lib/verification.ts` is the only place verification reads are written. Both
surfaces consume it, so the queue and a person's page can never disagree:

| screen | entry point | shows |
| ------ | ----------- | ----- |
| `/verification` | `verificationQueue(db, filter)` | every open/decided application, its documents, and vehicle documents pending review |
| `/users/[id]` | `verificationForProfile(db, profileId)` | that person's applications with capability type, status, submitted/reviewed/decided dates, rejection or resubmission reason and documents, plus a panel for documents on their vehicles |

Approve, reject and request-resubmission use the same server actions as before
(`reviewApplication`, `reviewDocument`), which re-check `is_admin()` server-side
and call the audited RPCs. The panel adds no new write path and no new business
rule; `isReviewable()` and `allDocsApproved()` only mirror what
`admin_review_verification` / `admin_review_document` already enforce in SQL.
`actions.ts` revalidates paths as `layout` so `/users/[id]` refreshes together
with its list page.

**File states are honest.** A document row can reference a `storage_path` whose
object does not exist — the imported demo data does exactly that. `fileStates()`
lists each referenced folder once under the admin-only storage read policy and
signs only the paths that are actually present, so the UI says:

| condition | label |
| --------- | ----- |
| no `storage_path` | *No file uploaded* |
| listed, signed | *Preview* link to a 10-minute signed URL |
| referenced but absent from the bucket | *No file on record*, quoting the missing path |
| the listing itself failed | *Preview unavailable* |

Nothing is ever exposed through a public URL: `verification-documents` and
`vehicle-documents` stay private, previews are server-signed, and the whole panel
renders only for a session that passes `is_admin()`.

**Hosted state today** (read-only probe, 2026-11-06): both document buckets are
empty, and of the 8 `verification_documents` rows 6 reference a path with no
object behind it and 2 have no path at all; all 5 `vehicle_documents` have no
path. So the panel currently shows *No file on record* / *No file uploaded* for
every document — that is the data, not a lookup failure, and uploading stand-ins
is deliberately not done.

The audit trail is the one section an admin session cannot read: the host keeps a
`SELECT` policy for it but no table privilege for `authenticated`, so
`/users/[id]` and `/settings` render "not readable by this session" through
`okOrDenied()` instead of failing the page. A 42501 is the only error that
degrades; anything else still throws.

## Money rules reflected in the UI

Integer centavos everywhere. Customer total = provider fare + platform fee. Fees are labelled **accrued** until a remittance row is marked `remitted` with a reference number. Rental and Pasuyo fee policy are not defined, so values are displayed as stored.

## What this dashboard has not been exercised against

No browser session has driven these pages against a live Supabase stack: this
workstation cannot run `supabase start` (Docker is not installed and Windows
refuses to enable the WSL2 backend, `0x80073712`) and the hosted project is not a
test target. The current evidence is: the local PGlite RPC/authorization suite
(`supabase/tests/sql/09_admin_verification_review_test.sql`, fresh + reset), the
10 stub-driven unit tests above, `typecheck` / `lint` / `build`, and
`node supabase/tools/verify_admin_reads.mjs`, which validates all 32 dashboard
select strings plus the privilege and policy each read table needs against the
hosted database. Layout, links and empty states still need one manual pass once a
stack is available.
