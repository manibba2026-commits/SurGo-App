// Applies the idempotent demo presence and history seeds to the hosted project.
//
// The schema changes are tracked migrations; this tool only writes demo rows.
// It uses the Supabase Management API SQL channel and the access token the CLI
// already keeps in Windows Credential Manager. The token is never printed.
//
//   node supabase/tools/apply_demo_seed.mjs preflight
//   node supabase/tools/apply_demo_seed.mjs apply
//   node supabase/tools/apply_demo_seed.mjs verify
//
// `apply` is safe to rerun: every row is keyed by a deterministic id or an
// ON CONFLICT target. It never creates an account or a UUID.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { sql } from './db_admin.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SEEDS = ['demo-presence.sql', 'demo-activity.sql'].map((name) => ({
  name,
  sql: fs.readFileSync(path.resolve(HERE, '..', name), 'utf8'),
}));

const DEMO_PHONES = Array.from(
  { length: 19 },
  (_, index) => `+6391700000${String(index + 1).padStart(2, '0')}`,
);

const EXPECTED = {
  online: 6,
  offline: 2,
  newRides: 4,
};

async function preflight() {
  const columns = await sql(`
    select table_name, column_name
      from information_schema.columns
     where table_schema = 'public'
       and column_name = 'is_simulated'
       and table_name in (
         'ride_requests', 'rental_bookings', 'service_requests',
         'service_transactions', 'wallet_transactions', 'notifications',
         'ride_status_events', 'service_status_events', 'ride_ratings'
       )
     order by table_name;
  `);
  if (columns.length !== 9) {
    throw new Error(
      'the demo activity migration is not applied: expected 9 is_simulated columns, ' +
        `found ${columns.length}`,
    );
  }

  const accounts = await sql(`
    select
      count(*) filter (where p.account_status = 'suspended') as suspended,
      count(*) filter (where p.account_status = 'active') as active,
      count(*) filter (where p.account_status = 'suspended'
        and p.full_name = 'Junel Ramos') as junel_suspended
      from public.profiles p
     where p.phone in (${DEMO_PHONES.map((phone) => `'${phone}'`).join(', ')});
  `);
  const row = accounts[0] ?? {};
  if (Number(row.junel_suspended) !== 1) {
    throw new Error('Junel Ramos is missing or no longer suspended — ABORT');
  }
  if (Number(row.active) < 19) {
    throw new Error('expected at least 19 active demo accounts — ABORT');
  }

  const pricing = await sql('select count(*) as n from public.pricing_policies;');
  if (Number(pricing[0]?.n ?? -1) !== 0) {
    throw new Error('pricing_policies is not empty — ABORT, do not change pricing');
  }

  const presence = await sql(`
    select
      count(*) filter (where rp.is_online) as online,
      count(*) filter (where not rp.is_online) as offline,
      count(*) filter (where rp.is_simulated) as simulated
      from public.rider_presence rp;
  `);
  console.log('hosted demo accounts:', JSON.stringify(row));
  console.log('hosted presence before apply:', JSON.stringify(presence[0] ?? {}));
}

async function apply() {
  const body = SEEDS.map(({ sql: text }) =>
    text.replace(/^begin;\s*\n/, '').replace(/\ncommit;\s*$/, '\n'),
  ).join('\n');
  await sql(`begin;\n${body}\ncommit;`);
  console.log('applied:', SEEDS.map((seed) => seed.name).join(', '));
}

async function verify() {
  const presence = await sql(`
    select
      count(*) filter (where rp.is_online and rp.is_available) as online,
      count(*) filter (where not rp.is_online) as offline,
      count(*) filter (where rp.is_simulated) as simulated,
      count(*) filter (where p.account_status = 'suspended') as suspended_rows,
      count(*) filter (where rp.latitude is null or rp.longitude is null) as no_fix
      from public.rider_presence rp
      join public.profiles p on p.id = rp.profile_id
     where p.phone in (${DEMO_PHONES.map((phone) => `'${phone}'`).join(', ')});
  `);
  const p = presence[0] ?? {};
  if (Number(p.online) !== EXPECTED.online) {
    throw new Error(`expected ${EXPECTED.online} online demo riders, found ${p.online}`);
  }
  if (Number(p.offline) !== EXPECTED.offline) {
    throw new Error(`expected ${EXPECTED.offline} offline demo riders, found ${p.offline}`);
  }
  if (Number(p.simulated) !== EXPECTED.online + EXPECTED.offline) {
    throw new Error('every demo presence row must be marked simulated');
  }
  if (Number(p.suspended_rows) !== 0 || Number(p.no_fix) !== 0) {
    throw new Error('a suspended account or a rider without a position holds presence');
  }

  const history = await sql(`
    select
      (select count(*) from public.ride_requests where is_simulated) as rides,
      (select count(*) from public.ride_requests
        where id in (
          md5('surgo:demo:ride:carlo-rosalinda')::uuid,
          md5('surgo:demo:ride:danny-nena')::uuid,
          md5('surgo:demo:ride:isabella-grace')::uuid,
          md5('surgo:demo:ride:bebot-danilo')::uuid
        )) as seeded_rides,
      (select count(*) from public.ride_status_events where is_simulated) as ride_events,
      (select count(*) from public.service_status_events where is_simulated) as pasuyo_events,
      (select count(*) from public.ride_ratings where is_simulated) as ratings,
      (select count(*) from public.service_transactions where is_simulated) as transactions,
      (select count(*) from public.notifications where is_simulated) as notifications,
      (select count(*) from public.wallet_transactions where is_simulated) as wallet_rows,
      (select count(*) from public.ride_requests
        where is_simulated and status = 'completed') as completed_rides,
      (select count(*) from public.ride_requests
        where is_simulated and status = 'awaiting_acceptance' and rider_id is null) as stale_open,
      (select count(*) from public.ride_requests
        where is_simulated and status = 'completed' and completed_at is null) as broken_completed
    ;
  `);
  const h = history[0] ?? {};
  if (Number(h.seeded_rides) !== EXPECTED.newRides) {
    throw new Error(`expected ${EXPECTED.newRides} seeded rider-history rides, found ${h.seeded_rides}`);
  }
  if (Number(h.stale_open) !== 0 || Number(h.broken_completed) !== 0) {
    throw new Error('demo history still contains an inconsistent ride row');
  }
  if (Number(h.ratings) < Number(h.completed_rides)) {
    throw new Error('a completed demo ride is missing its rating');
  }

  const money = await sql(`
    select
      count(*) filter (where status = 'completed' and not is_simulated) as actual_completed,
      coalesce(sum(platform_revenue_centavos) filter (where not is_simulated), 0) as actual_revenue,
      coalesce(sum(platform_revenue_centavos) filter (where is_simulated), 0) as simulated_revenue,
      coalesce(sum(customer_pays_centavos) filter (where is_simulated and status = 'completed'), 0) as simulated_cash,
      (select count(*) from public.pricing_policies) as pricing
      from public.service_transactions;
  `);
  const m = money[0] ?? {};
  if (Number(m.pricing) !== 0) throw new Error('pricing was activated by the seed');
  if (Number(m.simulated_revenue) !== 0) {
    throw new Error('a simulated settlement carries platform revenue');
  }
  if (Number(m.actual_revenue) !== 0) {
    console.log('NOTE: actual platform revenue is non-zero; review the real rows.');
  }

  const discovery = await sql(`
    begin;
    select set_config(
      'request.jwt.claim.sub',
      (select id::text from public.profiles where phone = '+639170000019'),
      true
    );
    set local role authenticated;
    select
      count(*) as online_riders,
      count(*) filter (where is_simulated) as simulated_riders,
      count(*) filter (where full_name in ('Jomar Lim', 'Marlon Uy')) as offline_leak,
      count(*) filter (where full_name = 'Junel Ramos') as suspended_leak
      from public.find_available_riders();
    rollback;
  `);
  const d = Array.isArray(discovery) ? discovery.at(-1) ?? {} : discovery;
  if (Number(d.online_riders) !== EXPECTED.online) {
    throw new Error(`discovery returned ${d.online_riders} riders, expected ${EXPECTED.online}`);
  }
  if (Number(d.offline_leak) !== 0 || Number(d.suspended_leak) !== 0) {
    throw new Error('discovery returned an offline or suspended rider');
  }

  console.log('presence:', JSON.stringify(p));
  console.log('history:', JSON.stringify(h));
  console.log('money:', JSON.stringify(m));
  console.log('discovery:', JSON.stringify(d));
  console.log('demo seed verified');
}

const mode = process.argv[2];
if (mode === 'preflight') await preflight();
else if (mode === 'apply') await apply();
else if (mode === 'verify') await verify();
else {
  console.error('usage: apply_demo_seed.mjs preflight|apply|verify');
  process.exit(1);
}
