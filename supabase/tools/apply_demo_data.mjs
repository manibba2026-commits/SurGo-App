// Applies supabase/demo-data.sql to the linked hosted project through the
// Supabase Management API (execute_sql equivalent), using the access token the
// Supabase CLI already keeps in the Windows Credential Manager. The token is
// read into process memory only; it is never printed or written to disk.
//
//   node supabase/tools/apply_demo_data.mjs preflight
//   node supabase/tools/apply_demo_data.mjs apply
//   node supabase/tools/apply_demo_data.mjs verify
//
// Statements are split on ";\n\n" (semicolons inside string literals never
// precede a blank line) and applied in transactional chunks. The SQL is
// idempotent, so a resumed run after any failure converges.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  REF, REAL_USER_EMAIL, REAL_USER_ID, sql,
} from './db_admin.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SQL = fs
  .readFileSync(path.resolve(HERE, '..', 'demo-data.sql'), 'utf8')
  .replace(/^begin;\n/, '')
  .replace(/\ncommit;\n$/, '\n');

const TABLES = [
  'profiles', 'user_roles', 'provider_profiles', 'vehicles',
  'vehicle_documents', 'verification_applications', 'verification_documents',
  'ride_requests', 'rental_bookings', 'service_requests',
  'service_request_items', 'service_transactions', 'wallet_accounts',
  'wallet_transactions', 'notifications', 'pricing_policies',
  'cash_fee_remittances',
];

async function preflight() {
  if (!REAL_USER_ID || !REAL_USER_EMAIL) {
    throw new Error('set SURGO_REAL_USER_ID and SURGO_REAL_USER_EMAIL before applying');
  }
  const rows = await sql(`
    select
      (select count(*) from public.profiles) as profiles,
      (select count(*) from public.pricing_policies) as pricing,
      (select count(*) from public.ride_requests) as rides,
      (select count(*) from public.vehicles) as vehicles,
      (select count(*) from auth.users
        where id = '${REAL_USER_ID}' and email = '${REAL_USER_EMAIL}'
          and banned_until is null) as real_user_ok;
  `);
  console.log('hosted state before apply:', JSON.stringify(rows[0] ?? rows));
  if (String(rows[0]?.real_user_ok) !== '1') {
    throw new Error('real user missing or unexpected — ABORT, do not apply');
  }
  if (Number(rows[0]?.rides) > 0 || Number(rows[0]?.vehicles) > 0) {
    console.log('NOTE: business rows already exist; the import is idempotent upserts.');
  }
}

async function apply() {
  const statements = SQL.split(/;\n\n/).map((s) => s.trim()).filter(Boolean);
  const CHUNK = 60;
  let done = 0;
  for (let i = 0; i < statements.length; i += CHUNK) {
    const chunk = statements.slice(i, i + CHUNK);
    const body = chunk.map((s) => (s.endsWith(';') ? s : `${s};`)).join('\n');
    try {
      await sql(`begin;\n${body}\ncommit;`);
    } catch (e) {
      try { await sql('rollback;'); } catch { /* best effort */ }
      throw new Error(`chunk starting at statement ${i} failed after ${done} ok: ${e.message}`);
    }
    done += chunk.length;
    console.log(`  applied ${done}/${statements.length} statements`);
  }
  console.log('apply complete');
}

async function verify() {
  const counts = await sql(`
    select
      (select count(*) from public.profiles) as profiles,
      (select count(*) from public.user_roles) as user_roles,
      (select count(*) from public.provider_profiles) as providers,
      (select count(*) from public.vehicles) as vehicles,
      (select count(*) from public.vehicle_documents) as vehicle_documents,
      (select count(*) from public.verification_applications) as applications,
      (select count(*) from public.verification_documents) as verification_documents,
      (select count(*) from public.ride_requests) as rides,
      (select count(*) from public.rental_bookings) as rentals,
      (select count(*) from public.service_requests) as pasuyo,
      (select count(*) from public.service_request_items) as pasuyo_items,
      (select count(*) from public.service_transactions) as transactions,
      (select count(*) from public.wallet_accounts) as wallets,
      (select count(*) from public.wallet_transactions) as wallet_txns,
      (select count(*) from public.notifications) as notifications,
      (select count(*) from public.pricing_policies) as pricing;
  `);
  console.log('hosted counts:', JSON.stringify(counts[0] ?? counts, null, 2));
  const real = await sql(`
    select id, email, banned_until is null as can_sign_in,
           (select count(*) from public.user_roles r where r.profile_id = u.id) as roles
      from auth.users u where u.email = '${REAL_USER_EMAIL}';
  `);
  console.log('real user:', JSON.stringify(real[0] ?? real));
  const badBal = await sql(`
    select count(*) as mismatches from public.wallet_accounts w
    join lateral (
      select balance_after_centavos from public.wallet_transactions t
      where t.wallet_account_id = w.id
      order by t.created_at desc limit 1) last on true
    where last.balance_after_centavos <> w.balance_centavos;
  `);
  console.log('wallet mismatches:', JSON.stringify(badBal[0] ?? badBal));
}

async function authRoster() {
  const rows = await sql(`
    select email,
           coalesce(encrypted_password, '') <> '' as has_password,
           banned_until is not null as banned,
           (select count(*) from public.user_roles r
             where r.profile_id = u.id) as roles
      from auth.users u order by email;
  `);
  for (const r of rows) console.log(JSON.stringify(r));
}

const mode = process.argv[2];
if (mode === 'preflight') await preflight();
else if (mode === 'apply') await apply();
else if (mode === 'verify') await verify();
else if (mode === 'auth') await authRoster();
else {
  console.error('usage: apply_demo_data.mjs preflight|apply|verify|auth');
  process.exit(1);
}
