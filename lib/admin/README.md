# SurGo Admin Dashboard

Next.js 14 · TypeScript · Tailwind · Supabase (Auth + Postgres RLS). Runs locally; no deployment config.

## Run

```bash
cp .env.example .env.local      # public URL + publishable key only
npm install
npm run dev                      # http://localhost:3100
npm run typecheck && npm run lint && npm run build
```

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
- Every page runs server-side as the signed-in user, so Postgres RLS applies. Admin read access comes from `public.is_admin()` policies (migration `admin_dashboard_access_and_actions`).
- Admin writes go only through audited `SECURITY DEFINER` RPCs that re-check `is_admin()`:
  `admin_review_verification`, `admin_review_document`, `admin_set_account_status`, `admin_set_vehicle_status`, `admin_update_remittance`.
  Each writes to `admin_audit_logs`. An admin cannot suspend their own account.
- Document previews use 10-minute signed URLs created server-side under an admin-only storage read policy.
- Query failures show an error page. The dashboard never falls back to mock data.

## Money rules reflected in the UI

Integer centavos everywhere. Customer total = provider fare + platform fee. Fees are labelled **accrued** until a remittance row is marked `remitted` with a reference number. Rental and Pasuyo fee policy are not defined, so values are displayed as stored.
