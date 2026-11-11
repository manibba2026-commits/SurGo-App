// One-shot verifier for supabase/demo-data.sql (NOT part of `npm test`).
//
// Boots PGlite with the same stubs as run.mjs, but with an auth.users shaped
// like the hosted one (aud, role, banned_until, is_sso_user, ...), applies
// migrations + seed.sql + demo-data.sql TWICE (idempotency), then asserts the
// expected demo counts, wallet reconciliation and the pricing dormancy.
//
//   node supabase/tests/verify_demo.mjs

import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const supabaseDir = path.resolve(here, '..');

const BOOTSTRAP = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;

  create schema auth;
  create schema storage;

  create table auth.users (
    id uuid primary key default gen_random_uuid(),
    aud varchar(255) not null default 'authenticated',
    role varchar(255) not null default 'authenticated',
    email text,
    phone text,
    raw_app_meta_data jsonb not null default '{}'::jsonb,
    raw_user_meta_data jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    is_sso_user boolean not null default false,
    is_anonymous boolean not null default false,
    banned_until timestamptz
  );

  create or replace function auth.uid()
  returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  $$;

  create publication supabase_realtime;

  create table storage.buckets (
    id text primary key, name text not null, public boolean not null default false,
    file_size_limit bigint, allowed_mime_types text[]
  );
  create table storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text not null references storage.buckets (id),
    name text not null, owner uuid, metadata jsonb
  );
  alter table storage.objects enable row level security;
  create or replace function storage.foldername(name text)
  returns text[] language sql immutable as $$
    select string_to_array(name, '/');
  $$;

  grant usage on schema auth, storage to anon, authenticated, service_role;
`;

const EXPECTED = {
  profiles: 19, user_roles: null, provider_profiles: 15, vehicles: 14,
  vehicle_documents: 5, verification_applications: 3,
  verification_documents: 8, ride_requests: 23, rental_bookings: 16,
  service_requests: 20, service_request_items: 23, service_transactions: 33,
  wallet_accounts: 11, wallet_transactions: 79, notifications: 33,
  pricing_policies: 0, cash_fee_remittances: 0, device_tokens: 0,
};

// Same default-privilege simulation as run.mjs: applied immediately before the
// admin dashboard migration, which is the first file that revokes them.
const DEFAULTS_MARKER = 'admin_dashboard_access_and_actions';

async function bootWithDemo() {
  const db = new PGlite();
  await db.waitReady;
  await db.exec(BOOTSTRAP);

  const migrations = fs.readdirSync(path.join(supabaseDir, 'migrations'))
    .filter((f) => f.endsWith('.sql')).sort();
  for (const file of migrations) {
    if (file.includes(DEFAULTS_MARKER)) {
      await db.exec(`
        grant usage on schema public, storage to anon, authenticated, service_role;
        grant all on all tables in schema public to anon, authenticated, service_role;
        grant all on all sequences in schema public to anon, authenticated, service_role;
        grant execute on all functions in schema public to anon, authenticated, service_role;
        grant all on all tables in schema storage to anon, authenticated, service_role;
      `);
    }
    try {
      await db.exec(fs.readFileSync(path.join(supabaseDir, 'migrations', file), 'utf8'));
    } catch (e) {
      throw new Error(`migration ${file} failed: ${e.message}`);
    }
  }
  await db.exec(fs.readFileSync(path.join(supabaseDir, 'seed.sql'), 'utf8'));

  const demo = fs.readFileSync(path.join(supabaseDir, 'demo-data.sql'), 'utf8');
  for (const pass of [1, 2]) {
    try {
      await db.exec(demo);
    } catch (e) {
      throw new Error(`demo-data.sql pass ${pass} failed: ${e.message}`);
    }
  }

  // Presence and activity are separate idempotent seeds applied after the
  // profiles exist. Each runs twice to prove a rerun does not duplicate rows.
  for (const seed of ['demo-presence.sql', 'demo-activity.sql']) {
    const sql = fs.readFileSync(path.join(supabaseDir, seed), 'utf8');
    for (const pass of [1, 2]) {
      try {
        await db.exec(sql);
      } catch (e) {
        throw new Error(`${seed} pass ${pass} failed: ${e.message}`);
      }
    }
  }
  return db;
}

async function count(db, table) {
  const r = await db.query(`select count(*)::int as n from public.${table}`);
  return r.rows[0].n;
}

function check(label, actual, expected) {
  const ok = actual === expected;
  console.log(`  ${ok ? 'OK ' : 'FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
  if (!ok) process.exitCode = 1;
}

const db = await bootWithDemo();
console.log('Counts (second import pass must not duplicate):');
for (const [table, expected] of Object.entries(EXPECTED)) {
  if (expected === null) continue;
  check(table, await count(db, table), expected);
}

console.log('Invariants:');
const bal = await db.query(`
  select count(*)::int as n from public.wallet_accounts w
  join lateral (
    select balance_after_centavos from public.wallet_transactions t
    where t.wallet_account_id = w.id order by t.created_at desc, t.id desc limit 1
  ) last on true
  where last.balance_after_centavos <> w.balance_centavos
  or last.balance_after_centavos < 0`);
check('wallet ledgers end at account balance', bal.rows[0].n, 0);

const fees = await db.query(
  `select count(*)::int as n from public.service_transactions
   where platform_fee_centavos <> 0 or platform_revenue_centavos <> 0`);
check('no platform fees charged', fees.rows[0].n, 0);

const banned = await db.query(
  `select count(*)::int as n from auth.users
   where banned_until is null and is_anonymous = false
     and email is distinct from '${process.env.SURGO_REAL_USER_EMAIL ?? ''}'`);
check('demo users cannot sign in', banned.rows[0].n, 0);

const dup = await db.query(
  `select count(*)::int as n from (
     select phone from public.profiles where phone is not null
     group by phone having count(*) > 1
     union all
     select lower(email) from public.profiles where email is not null
     group by lower(email) having count(*) > 1) d`);
check('profile email/phone uniqueness holds', dup.rows[0].n, 0);

const merged = await db.query(
  `select count(*)::int as n from public.profiles
   where full_name in ('Jr Derigay','Bebot Lim','Carlo Mendoza','Danny Reyes','Edwin Santillan','Isabella Dizon','Grace Ann Villaflor','Danilo Cruz','Rosalinda Pajo')`);
check('multi-role humans share one profile', merged.rows[0].n, 9);

const unread = await db.query(
  `select count(*)::int as n from public.notifications
   where profile_id = (select id from public.profiles where full_name = 'Jr Derigay')
     and read_at is null`);
check('Jr unread notifications (P001+R001 merged)', unread.rows[0].n, 4);

const plates = await db.query(
  `select count(*)::int as n from public.vehicles where plate_number = 'NGD 6612'`);
check('duplicate plate NGD 6612 both imported', plates.rows[0].n, 2);

console.log('Presence:');
const online = await db.query(
  `select count(*)::int as n from public.rider_presence
   where is_online and is_available and is_simulated and source = 'demo'`);
check('six demo riders online and available', online.rows[0].n, 6);

const offline = await db.query(
  `select count(*)::int as n from public.rider_presence
   where not is_online and is_simulated`);
check('two demo riders deliberately offline', offline.rows[0].n, 2);

const suspended = await db.query(
  `select count(*)::int as n from public.rider_presence rp
   join public.profiles p on p.id = rp.profile_id
   where p.account_status = 'suspended'`);
check('a suspended account has no dispatchable presence', suspended.rows[0].n, 0);

const noFix = await db.query(
  `select count(*)::int as n from public.rider_presence
   where is_online and (latitude is null or longitude is null)`);
check('every online rider has a simulated fix', noFix.rows[0].n, 0);

await db.exec(`select set_config('request.jwt.claim.sub',
  (select id::text from public.profiles where phone = '+639170000001'), false)`);
let discoverable;
try {
  discoverable = await db.query(
    `select count(*)::int as n from public.find_available_riders()`);
} catch (error) {
  console.log('  discovery query failed:', error.message);
  throw error;
}
check('discovery returns the online demo riders', discoverable.rows[0].n, 6);

console.log('Simulated attribution:');
const unmarked = await db.query(`
  select (
    (select count(*) from public.ride_requests rr
      where (rr.passenger_id in (select id from public.profiles
                                  where phone like '+63917000%')
          or rr.rider_id in (select id from public.profiles
                              where phone like '+63917000%'))
        and not rr.is_simulated)
    + (select count(*) from public.rental_bookings rb
        where (rb.renter_id in (select id from public.profiles
                                 where phone like '+63917000%')
            or rb.owner_id in (select id from public.profiles
                                where phone like '+63917000%'))
          and not rb.is_simulated)
    + (select count(*) from public.service_requests sr
        where (sr.customer_id in (select id from public.profiles
                                   where phone like '+63917000%')
            or sr.provider_id in (select id from public.profiles
                                   where phone like '+63917000%'))
          and not sr.is_simulated)
    + (select count(*) from public.service_transactions st
        where (st.customer_id in (select id from public.profiles
                                   where phone like '+63917000%')
            or st.provider_id in (select id from public.profiles
                                   where phone like '+63917000%'))
          and not st.is_simulated)
    + (select count(*) from public.notifications n
        where n.profile_id in (select id from public.profiles
                                where phone like '+63917000%')
          and not n.is_simulated)
    + (select count(*) from public.wallet_transactions wt
        join public.wallet_accounts wa on wa.id = wt.wallet_account_id
        where wa.profile_id in (select id from public.profiles
                                 where phone like '+63917000%')
          and not wt.is_simulated)
  )::int as n`);
check('every demo-linked history row is marked simulated', unmarked.rows[0].n, 0);

const actualRevenue = await db.query(
  `select count(*)::int as n from public.service_transactions
   where is_simulated and (platform_fee_centavos <> 0
     or platform_revenue_centavos <> 0)`);
check('demo settlements carry no platform revenue', actualRevenue.rows[0].n, 0);

const stale = await db.query(
  `select count(*)::int as n from public.ride_requests rr
   join public.profiles p on p.id = rr.passenger_id
   where p.phone like '+63917000%'
     and rr.status = 'awaiting_acceptance'
     and rr.rider_id is null
     and coalesce(rr.requested_at, rr.created_at) < now() - interval '1 hour'`);
check('no stale unanswered demo request stays live', stale.rows[0].n, 0);

const ratings = await db.query(`
  select (select count(*) from public.ride_requests rr
           join public.profiles p on p.id = rr.passenger_id
           where p.phone like '+63917000%' and rr.status = 'completed'
             and rr.rider_id is not null
             and rr.passenger_id <> rr.rider_id)::int as rides,
         (select count(*) from public.ride_ratings where is_simulated)::int as rated`);
check('every completed demo ride has one rating',
  ratings.rows[0].rated, ratings.rows[0].rides);

const timeline = await db.query(`
  select count(*)::int as n from public.ride_requests rr
   join public.profiles p on p.id = rr.passenger_id
   where p.phone like '+63917000%' and rr.is_simulated
     and not exists (select 1 from public.ride_status_events e
                      where e.ride_id = rr.id)`);
check('every simulated ride has a status timeline', timeline.rows[0].n, 0);

await db.close();
console.log(
  process.exitCode
    ? '\nDEMO VERIFY FAILED'
    : '\nDEMO VERIFY PASSED: migrations + seed + demo-data x2, all invariants hold',
);
