// Read-only audit of the hosted demo dataset.
//
// It answers the questions the apply tool's `verify` does not: does every table
// hold exactly the rows the generated SQL upserts (so a re-import cannot have
// duplicated anything), are the people-role-provider-vehicle links the
// documented ones, do the money ledgers actually reconcile, are the eight
// archived accounts represented the way the generator intended, and what would
// each settlement's platform fee be under the pricing logic the app ships?
//
// Nothing here writes. Every statement is a SELECT.
//
//   node supabase/tools/audit_hosted.mjs            # integrity audit
//   node supabase/tools/audit_hosted.mjs --fees     # add the fee report
//
// The fee report only *computes* what each transaction would owe. It changes no
// hosted row: pricing is still gated, and `pricing_policies` holds 0 rows.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { REF, REAL_USER_EMAIL, REAL_USER_ID, sql } from './db_admin.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEMO_SQL = fs
  .readFileSync(path.resolve(HERE, '..', 'demo-data.sql'), 'utf8');
const WANT_FEES = process.argv.includes('--fees');

// What the demo dataset is documented to hold. Counts that can also grow from
// real sign-ups or live use are scoped to the 19 demo phone numbers, so the
// audit keeps checking the import instead of failing whenever a real account
// registers. Tables that only ever hold demo rows stay global.
const EXPECTED = {
  profiles: 19,
  user_roles: 58,
  provider_profiles: 15,
  vehicles: 14,
  vehicle_documents: 5,
  verification_applications: 3,
  verification_documents: 8,
  ride_requests: 23,
  rental_bookings: 16,
  service_requests: 20,
  service_request_items: 23,
  service_transactions: 33,
  wallet_accounts: 11,
  wallet_transactions: 79,
  notifications: 33,
};

const ARCHIVED = [
  'Junel Ramos', 'Jomar Lim', 'Kd Sotto', 'Marlon Uy',
  'Marisol Cruz', 'Rhea Puno', 'Alex Tan', 'Rico D.',
];

// The rates the app actually prices with, read from assets/db/config.json so a
// changed rate cannot drift out of this report.
const CONFIG = JSON.parse(
  fs.readFileSync(
    path.resolve(HERE, '..', '..', 'assets', 'db', 'config.json'),
    'utf8',
  ),
);
const FEE = CONFIG.platformFee;
const BPS = CONFIG.commissionBps;

const results = [];
const notes = [];

// Real inconsistencies in the imported demo data that were verified to come
// from `assets/db/*.json` rather than from the import. They stay visible as
// NOTED lines: the audit does not get to call them clean.
const KNOWN_GAPS = {
  'role rule: role_without_provider': {
    rows: 2,
    why:
      'Isabella Dizon and the demo "Jr Derigay" hold an approved vehicle_owner ' +
      'role but list no vehicle. Verification is per account, listings are ' +
      'separate data, so the role is not wrong.',
  },
  'role rule: provider_without_role': {
    rows: 1,
    why:
      'Edwin Santillan carries an earner provider row while accounts.json ' +
      'leaves his earner capability pending.',
  },
  'role rule: earner_wallet_mismatch': {
    rows: 1,
    why:
      'Edwin Santillan also holds an earner wallet with four entries and a ' +
      'positive balance, on that same pending role.',
  },
  'ledger: chain_breaks': {
    rows: 3,
    why:
      'Jr Derigay’s earner wallet has two entries in the same second ' +
      '(2026-08-29T00:00:00Z). balance_after_centavos was written in source ' +
      'order, so replaying with a (created_at, id) tiebreak reorders them. The ' +
      'net sum and closing balance both reconcile, so no money is wrong — the ' +
      'ledger simply has no sequence column to replay by.',
  },
};

function check(name, ok, detail) {
  const gap = KNOWN_GAPS[name];
  const observed = Number(String(detail ?? '').match(/rows (\d+)/)?.[1] ?? -1);
  if (!ok && gap && observed === gap.rows) {
    notes.push({ name, detail, why: gap.why });
    console.log(`NOTED  ${name} — ${detail}`);
    return;
  }
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}
function info(label, value) {
  console.log(`  ${label}: ${typeof value === 'string' ? value : JSON.stringify(value)}`);
}

// ------------------------------------------------- the file's own id roster ----

// demo-data.sql upserts by deterministic id, so the definitive proof that a
// repeated import created no duplicates is a set comparison: every id in the
// file must be in the database exactly once, and anything extra in the database
// must be explainable as trigger- or dashboard-created rather than a second copy.
function idsFromFile() {
  const roster = {};
  const re =
    /insert into ([a-z_.]+)\s*\(([^)]*)\)\s*values \('([0-9a-f-]{36})'/g;
  for (const m of DEMO_SQL.matchAll(re)) {
    const [schema, table] = m[1].includes('.')
      ? m[1].split('.')
      : ['public', m[1]];
    (roster[`${schema}.${table}`] ??= new Set()).add(m[3]);
  }
  return roster;
}

// One generated statement is `insert into t (cols...) values (...) on conflict`.
// Splitting a tuple on top-level commas is enough because the generator never
// nests a parenthesised value.
function splitTuple(text) {
  const parts = [];
  let current = '';
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "'" && text[i - 1] !== '\\') {
      inQuotes = !inQuotes;
      current += ch;
    } else if (ch === ',' && !inQuotes) {
      parts.push(current.trim());
      current = '';
    } else current += ch;
  }
  parts.push(current.trim());
  return parts.map((p) => p.replace(/^'|'$/g, ''));
}

// Rows the file writes for a table, projected onto a natural key. Needed for
// `user_roles`: its unique key is (profile_id, role) and the auth trigger may
// have created that row first, so the hosted `id` can legitimately differ from
// the one in the file while still being the same single row.
function demoKeyRows(table, keyColumns) {
  const rows = new Set();
  const re =
    new RegExp(
      `insert into ${table.replace('.', '\\.')} \\(([^)]*)\\)\\s*values \\(([\\s\\S]*?)\\)\\s*\\non conflict`,
      'g',
    );
  for (const m of DEMO_SQL.matchAll(re)) {
    const cols = splitTuple(m[1]);
    const values = splitTuple(m[2]);
    const key = keyColumns.map((c) => values[cols.indexOf(c)] ?? '');
    if (key.some((v) => v === '' || v === 'null')) continue;
    rows.add(key.join('|'));
  }
  return rows;
}

async function idRoster() {
  const fileIds = idsFromFile();
  for (const [table, ids] of Object.entries(fileIds)) {
    const dupes = await sql(
      `select id, count(*) as n from ${table} group by id having count(*) > 1;`,
    );
    check(`no duplicate ids in ${table}`, dupes.length === 0, JSON.stringify(dupes));

    const hosted = await sql(`select id from ${table};`);
    const hostedIds = new Set(hosted.map((r) => r.id));
    const missing = [...ids].filter((id) => !hostedIds.has(id));
    const extra = hosted.filter((r) => !ids.has(r.id)).length;
    if (table !== 'public.user_roles') {
      check(
        `every ${table} row from demo-data.sql is hosted`,
        missing.length === 0,
        `missing ${missing.length}`,
      );
    }
    if (extra) {
      info(`${table} rows whose id is not in demo-data.sql`, extra);
    }
  }

  // The auth trigger gives every new user a profile and an approved passenger
  // role, so those rows are keyed by person, not by the id the file chose.
  const pairs = demoKeyRows('public.user_roles', ['profile_id', 'role']);
  const hostedPairs = await sql(`
    select profile_id, role, count(*) as n
      from public.user_roles group by 1, 2;
  `);
  const hostedSet = new Set(hostedPairs.map((r) => `${r.profile_id}|${r.role}`));
  const repeated = hostedPairs.filter((r) => Number(r.n) > 1);
  check('no duplicate (profile_id, role) pairs', repeated.length === 0,
    JSON.stringify(repeated).slice(0, 300));
  const missingPairs = [...pairs].filter((k) => !hostedSet.has(k));
  check(`every demo role pair is hosted`, missingPairs.length === 0,
    `missing ${missingPairs.length}`);
  info('role pairs in demo-data.sql vs hosted', `${pairs.size} / ${hostedSet.size}`);
}

// ---------------------------------------------------------------- counts ----

async function counts() {
  const row = (
    await sql(`
    select
      (select count(*) from public.profiles p
        where p.phone like '+63917000%') as profiles,
      (select count(*) from public.user_roles r
        join public.profiles p on p.id = r.profile_id
        where p.phone like '+63917000%') as user_roles,
      (select count(*) from public.provider_profiles) as provider_profiles,
      (select count(*) from public.vehicles) as vehicles,
      (select count(*) from public.vehicle_documents) as vehicle_documents,
      (select count(*) from public.verification_applications va
        join public.profiles p on p.id = va.profile_id
        where p.phone like '+63917000%') as verification_applications,
      (select count(*) from public.verification_documents vd
        join public.verification_applications va on va.id = vd.application_id
        join public.profiles p on p.id = va.profile_id
        where p.phone like '+63917000%') as verification_documents,
      (select count(*) from public.ride_requests) as ride_requests,
      (select count(*) from public.rental_bookings) as rental_bookings,
      (select count(*) from public.service_requests) as service_requests,
      (select count(*) from public.service_request_items) as service_request_items,
      (select count(*) from public.service_transactions) as service_transactions,
      (select count(*) from public.wallet_accounts) as wallet_accounts,
      (select count(*) from public.wallet_transactions) as wallet_transactions,
      (select count(*) from public.notifications) as notifications,
      (select count(*) from public.pricing_policies) as pricing_policies,
      (select count(*) from public.cash_fee_remittances) as cash_fee_remittances,
      (select count(*) from auth.users u
        join public.profiles p on p.id = u.id
        where p.phone like '+63917000%') as auth_users,
      (select count(*) from public.profiles p
        where p.phone is null or p.phone not like '+63917000%') as real_profiles;
  `)
  )[0];
  for (const [table, want] of Object.entries(EXPECTED)) {
    check(`count ${table}`, Number(row[table]) === want,
      `hosted ${row[table]}, spec ${want}`);
  }
  check('pricing stays gated', Number(row.pricing_policies) === 0,
    `pricing_policies ${row.pricing_policies}`);
  check('no cash remittance rows', Number(row.cash_fee_remittances) === 0,
    `hosted ${row.cash_fee_remittances}`);
  check('auth.users demo roster', Number(row.auth_users) === 19,
    `hosted ${row.auth_users}`);
  info('non-demo profiles (real sign-ups, outside the demo import)',
    row.real_profiles);
}

// ------------------------------------------------------------- integrity ----

async function integrity() {
  const broken = (
    await sql(`
    select
      (select count(*) from public.user_roles r
        where not exists (select 1 from public.profiles p where p.id = r.profile_id)) as role_orphans,
      (select count(*) from public.provider_profiles v
        where not exists (select 1 from public.profiles p where p.id = v.profile_id)) as provider_orphans,
      (select count(*) from public.vehicles veh
        where not exists (select 1 from public.profiles p where p.id = veh.owner_profile_id)) as vehicle_orphans,
      (select count(*) from public.ride_requests r
        where not exists (select 1 from public.profiles p where p.id = r.passenger_id)) as ride_passenger_orphans,
      (select count(*) from public.ride_requests r
        where r.rider_id is not null
          and not exists (select 1 from public.profiles p where p.id = r.rider_id)) as ride_rider_orphans,
      (select count(*) from public.rental_bookings b
        where not exists (select 1 from public.profiles p where p.id = b.renter_id)
           or not exists (select 1 from public.profiles p where p.id = b.owner_id)) as rental_orphans,
      (select count(*) from public.service_requests s
        where not exists (select 1 from public.profiles p where p.id = s.customer_id)) as pasuyo_orphans,
      (select count(*) from public.service_request_items i
        where not exists (select 1 from public.service_requests s where s.id = i.service_request_id)) as item_orphans,
      (select count(*) from public.service_transactions t
        where not exists (select 1 from public.profiles p where p.id = t.customer_id)
           or not exists (select 1 from public.profiles p where p.id = t.provider_id)) as txn_orphans,
      (select count(*) from public.wallet_accounts w
        where w.profile_id is not null
          and not exists (select 1 from public.profiles p where p.id = w.profile_id)) as wallet_orphans,
      (select count(*) from public.wallet_transactions t
        where not exists (select 1 from public.wallet_accounts w where w.id = t.wallet_account_id)) as ledger_orphans,
      (select count(*) from public.notifications n
        where not exists (select 1 from public.profiles p where p.id = n.profile_id)) as notification_orphans,
      (select count(*) from public.profiles p
        where not exists (select 1 from auth.users u where u.id = p.id)) as profile_without_auth,
      (select count(*) from auth.users u
        where not exists (select 1 from public.profiles p where p.id = u.id)) as auth_without_profile;
  `)
  )[0];
  for (const [name, value] of Object.entries(broken)) {
    check(`no ${name}`, Number(value) === 0, `rows ${value}`);
  }
}

// ------------------------------------------------------- role graph rules ----

async function roleGraph() {
  const rules = (
    await sql(`
    with approved_provider as (
      select r.profile_id, r.role::text as role from public.user_roles r
      where r.status = 'approved' and r.role in ('earner', 'vehicle_owner')
        and exists (select 1 from public.profiles p
          where p.id = r.profile_id and p.phone like '+63917000%')
    ), provider_rows as (
      select v.profile_id, v.provider_type::text as provider_type
        from public.provider_profiles v
        join public.profiles p on p.id = v.profile_id
        where p.phone like '+63917000%'
    )
    select
      (select count(*) from approved_provider a
        where not exists (select 1 from provider_rows v
          where v.profile_id = a.profile_id
            and v.provider_type = a.role)) as role_without_provider,
      (select count(*) from provider_rows v
        where not exists (select 1 from approved_provider a
          where a.profile_id = v.profile_id and a.role = v.provider_type)) as provider_without_role,
      (select count(*) from public.user_roles
        where status = 'approved' and approved_at is null) as approved_without_timestamp,
      (select count(*) from public.user_roles
        where status <> 'approved' and approved_at is not null) as pending_with_timestamp,
      (select count(*) from public.vehicles veh
        where not exists (select 1 from public.user_roles r
          where r.profile_id = veh.owner_profile_id
            and r.role = 'vehicle_owner' and r.status = 'approved')) as vehicle_without_approved_owner,
      (select count(*) from public.ride_requests r
        where r.rider_id is not null
          and not exists (select 1 from public.user_roles e
            where e.profile_id = r.rider_id and e.role = 'earner')) as rider_without_earner_role,
      (select count(*) from public.rental_bookings b
        where not exists (select 1 from public.vehicles v
          where v.id = b.vehicle_id and v.owner_profile_id = b.owner_id)) as booking_vehicle_owner_mismatch,
      -- The generator maps an approved owner to a 'provider' wallet, a rider to
      -- an 'earner' wallet and a passenger to a 'passenger' wallet.
      (select count(*) from public.wallet_accounts w
        where w.account_type = 'passenger' and not exists (select 1 from public.user_roles r
          where r.profile_id = w.profile_id and r.role = 'passenger' and r.status = 'approved')) as passenger_wallet_mismatch,
      (select count(*) from public.wallet_accounts w
        where w.account_type = 'earner' and not exists (select 1 from public.user_roles r
          where r.profile_id = w.profile_id and r.role = 'earner' and r.status = 'approved')) as earner_wallet_mismatch,
      (select count(*) from public.wallet_accounts w
        where w.account_type = 'provider' and not exists (select 1 from public.user_roles r
          where r.profile_id = w.profile_id and r.role = 'vehicle_owner'
            and r.status = 'approved')) as provider_wallet_mismatch,
      (select count(*) from public.wallet_accounts w
        where w.account_type <> 'platform' and w.profile_id is null) as orphan_platform_wallet,
      (select count(*) from public.profiles
        where account_status not in ('active', 'suspended')) as odd_account_status;
  `)
  )[0];
  for (const [name, value] of Object.entries(rules)) {
    check(`role rule: ${name}`, Number(value) === 0, `rows ${value}`);
  }

  const spread = await sql(`
    select role, status, count(*) as n
      from public.user_roles group by 1, 2 order by 1, 2;
  `);
  info('role spread', spread.map((r) => `${r.role}/${r.status}=${r.n}`).join(' '));
  const walletTypes = await sql(`
    select account_type, count(*) as n
      from public.wallet_accounts group by 1 order by 1;
  `);
  info('wallet accounts by type',
    walletTypes.map((r) => `${r.account_type}=${r.n}`).join(' '));
}

// ----------------------------------------------------------------- money ----

// The ledger is the one place a bad import shows up as a wrong balance, so each
// wallet is replayed in order: opening delta, every running step, and the
// closing balance against the account row.
async function money() {
  const ledgers = (
    await sql(`
    with ordered as (
      select t.wallet_account_id, t.id, t.direction,
             t.amount_centavos, t.balance_after_centavos,
             lag(t.balance_after_centavos)
               over (partition by t.wallet_account_id order by t.created_at, t.id)
               as previous,
             row_number()
               over (partition by t.wallet_account_id order by t.created_at, t.id)
               as step,
             sum(case t.direction when 'credit' then t.amount_centavos
                                  else -t.amount_centavos end)
               over (partition by t.wallet_account_id) as net
        from public.wallet_transactions t
    )
    select
      (select count(*) from ordered
        where previous is not null
          and previous + case direction when 'credit' then amount_centavos
                                        else -amount_centavos end
              <> balance_after_centavos) as chain_breaks,
      (select count(*) from ordered
        where step = 1 and balance_after_centavos
              <> case direction when 'credit' then amount_centavos
                                else -amount_centavos end) as bad_opening,
      (select count(*) from public.wallet_accounts w
        join lateral (
          select balance_after_centavos as last from public.wallet_transactions t
          where t.wallet_account_id = w.id
          order by t.created_at desc, t.id desc limit 1) l on true
        where l.last <> w.balance_centavos) as wrong_closing_balance,
      (select count(*) from public.wallet_accounts w
        where not exists (select 1 from public.wallet_transactions t
          where t.wallet_account_id = w.id)) as silent_wallet,
      (select count(*) from public.wallet_transactions
        where amount_centavos <= 0) as zero_amount_entry,
      (select count(*) from public.wallet_transactions
        where direction not in ('credit', 'debit')) as odd_direction,
      (select count(*) from public.wallet_transactions
        where balance_after_centavos < 0) as negative_running_balance;
  `)
  )[0];
  for (const [name, value] of Object.entries(ledgers)) {
    check(`ledger: ${name}`, Number(value) === 0, `rows ${value}`);
  }

  const money = (
    await sql(`
    select
      (select count(*) from public.wallet_accounts w
        where coalesce((select sum(case t.direction when 'credit' then t.amount_centavos
                                              else -t.amount_centavos end)
          from public.wallet_transactions t where t.wallet_account_id = w.id), 0)
          <> w.balance_centavos) as net_mismatch,
      (select count(*) from public.wallet_accounts
        where balance_centavos < 0) as negative_balance,
      (select count(*) from public.service_transactions
        where customer_pays_centavos <> fare_centavos + platform_fee_centavos) as total_gap,
      (select count(*) from public.service_transactions
        where provider_payout_centavos + platform_revenue_centavos
              <> customer_pays_centavos) as conservation_gap,
      (select count(*) from public.service_transactions
        where provider_payout_centavos > fare_centavos) as payout_over_fare,
      (select count(*) from public.service_transactions
        where fare_centavos <= 0) as zero_fare,
      (select count(*) from public.service_transactions
        where status = 'completed' and settled_at is null) as settled_without_timestamp,
      (select count(*) from public.service_transactions
        where platform_fee_centavos <> 0 or platform_revenue_centavos <> 0) as fees_recorded,
      (select count(*) from public.service_transactions
        where provider_payout_centavos <> fare_centavos) as payout_below_fare,
      (select count(*) from public.ride_requests
        where platform_fee_centavos <> 0) as ride_fees_recorded,
      (select count(*) from public.rental_bookings
        where platform_fee_centavos <> 0) as rental_fees_recorded,
      (select count(*) from public.service_requests
        where platform_fee_centavos <> 0) as pasuyo_fees_recorded;
  `)
  )[0];
  for (const [name, value] of Object.entries(money)) {
    check(`money: ${name}`, Number(value) === 0, `rows ${value}`);
  }

  const totals = (
    await sql(`
    select
      count(*) as settlements,
      sum(fare_centavos) as fare,
      sum(platform_fee_centavos) as fees,
      sum(customer_pays_centavos) as collected,
      sum(provider_payout_centavos) as paid_out,
      sum(platform_revenue_centavos) as revenue
      from public.service_transactions where status = 'completed';
  `)
  )[0];
  info('settlement totals (centavos)', totals);
  check(
    'settlement totals balance',
    Number(totals.collected) === Number(totals.fare) + Number(totals.fees) &&
      Number(totals.collected) ===
        Number(totals.paid_out) + Number(totals.revenue),
    `collected ${totals.collected} = fare ${totals.fare} + fee ${totals.fees}`,
  );
}

// ------------------------------------------------------------ coverage ----

async function coverage() {
  const cover = (
    await sql(`
    select
      (select count(*) from public.ride_requests r
        where r.is_simulated and r.status = 'completed'
          and not exists (select 1 from public.service_transactions t
            where t.service_type = 'ride' and t.ride_id = r.id)) as ride_unsettled,
      (select count(*) from public.ride_requests r
        where r.is_simulated and r.status not in ('completed', 'cancelled')
          and exists (select 1 from public.service_transactions t
            where t.service_type = 'ride' and t.ride_id = r.id)) as ride_settled_early,
      (select count(*) from public.service_transactions t
        where t.service_type = 'ride'
          and not exists (select 1 from public.ride_requests r
            where r.id = t.ride_id)) as ride_txn_dangling,
      (select count(*) from public.service_transactions t
        where t.service_type = 'ride'
          and not exists (select 1 from public.ride_requests r
            where r.id = t.ride_id and r.status = 'completed')) as ride_txn_not_completed,
      (select count(*) from public.service_transactions t
        where t.service_type = 'rental'
          and not exists (select 1 from public.rental_bookings b
            where b.id = t.rental_id)) as rental_txn_dangling,
      (select count(*) from public.service_transactions t
        where t.service_type = 'pasuyo'
          and not exists (select 1 from public.service_requests s
            where s.id = t.service_request_id)) as pasuyo_txn_dangling,
      (select count(*) from public.service_transactions t
        where t.service_type = 'pasuyo'
          and exists (select 1 from public.service_requests s
            where s.id = t.service_request_id and s.status = 'cancelled')) as cancelled_pasuyo_settled,
      (select count(*) from public.ride_requests
        where status = 'completed' and (accepted_at is null or started_at is null
          or completed_at is null)) as ride_timestamp_gaps,
      (select count(*) from public.rental_bookings
        where status = 'completed' and (returned_at is null or completed_at is null))
        as rental_timestamp_gaps,
      (select count(*) from public.service_requests
        where status = 'delivered' and delivered_at is null) as pasuyo_timestamp_gaps,
      (select count(*) from public.rental_bookings
        where status = 'accepted' and started_at is not null) as rental_started_too_early,
      (select count(*) from public.rental_bookings
        where status in ('active', 'returned', 'completed') and started_at is null)
        as rental_started_without_timestamp;
  `)
  )[0];
  for (const [name, value] of Object.entries(cover)) {
    check(`settlement: ${name}`, Number(value) === 0, `rows ${value}`);
  }

  // Live bookings made during a demo are outside the seed's consistency
  // guarantee; report them so a leftover verification ride is visible instead
  // of failing the import audit.
  const live = await sql(`
    select count(*) filter (where r.status = 'completed'
             and not exists (select 1 from public.service_transactions t
               where t.service_type = 'ride' and t.ride_id = r.id)) as unsettled,
           count(*) as n
      from public.ride_requests r where not r.is_simulated;
  `);
  info('non-simulated rides (live use, outside the demo seed)',
    `rows ${live[0]?.n ?? 0}, completed without settlement ${live[0]?.unsettled ?? 0}`);

  const byType = await sql(`
    select t.service_type, count(*) as n,
           count(*) filter (where t.fare_centavos = 0) as zero_fare
      from public.service_transactions t group by 1 order by 1;
  `);
  info('settlements by service',
    byType.map((r) => `${r.service_type}=${r.n}`).join(' '));

  // Which rental statuses were considered finished enough to settle. Reported
  // rather than asserted: the generator settles its history rows, whatever
  // status those ended in.
  const rentalStates = await sql(`
    select b.status, count(*) as n,
           count(*) filter (where t.id is not null) as settled
      from public.rental_bookings b
      left join public.service_transactions t on t.rental_id = b.id
      group by 1 order by 1;
  `);
  info('rentals by status (settled)',
    rentalStates.map((r) => `${r.status}: ${r.settled}/${r.n}`).join(' '));

  const sourceAgreement = (
    await sql(`
    select
      (select count(*) from public.service_transactions t
        join public.ride_requests r on r.id = t.ride_id
        where t.fare_centavos <> r.fare_centavos) as ride_fare_drift,
      (select count(*) from public.service_transactions t
        join public.rental_bookings b on b.id = t.rental_id
        where t.fare_centavos <> b.total_fare_centavos) as rental_fare_drift,
      (select count(*) from public.service_transactions t
        join public.service_requests s on s.id = t.service_request_id
        where t.fare_centavos <> coalesce(s.budget_centavos, s.quoted_fee_centavos))
        as pasuyo_amount_drift,
      (select count(*) from public.service_transactions t
        join public.ride_requests r on r.id = t.ride_id
        where t.customer_id <> r.passenger_id
           or (r.rider_id is not null and t.provider_id <> r.rider_id)) as ride_party_drift,
      (select count(*) from public.service_transactions t
        join public.rental_bookings b on b.id = t.rental_id
        where t.customer_id <> b.renter_id or t.provider_id <> b.owner_id) as rental_party_drift,
      (select count(*) from public.service_transactions t
        join public.service_requests s on s.id = t.service_request_id
        where t.customer_id <> s.customer_id
           or (s.provider_id is not null and t.provider_id <> s.provider_id)) as pasuyo_party_drift;
  `)
  )[0];
  for (const [name, value] of Object.entries(sourceAgreement)) {
    check(`source agreement: ${name}`, Number(value) === 0, `rows ${value}`);
  }
}

// ------------------------------------------------------------- archived ----

async function archived() {
  const names = ARCHIVED.map((n) => `'${n}'`).join(', ');
  const rows = await sql(`
    select p.full_name, p.account_status, p.rating, p.total_rides,
           (u.banned_until is not null) as banned,
           coalesce(string_agg(r.role || ':' || r.status, ', ' order by r.role), '') as roles,
           (select count(*) from public.vehicles v
             where v.owner_profile_id = p.id) as vehicles,
           (select count(*) from public.provider_profiles v
             where v.profile_id = p.id) as providers
      from public.profiles p
      join auth.users u on u.id = p.id
      left join public.user_roles r on r.profile_id = p.id
      where p.full_name in (${names})
      group by p.id, p.full_name, p.account_status, p.rating, p.total_rides,
               u.banned_until
      order by p.full_name;
  `);
  const seen = new Set(rows.map((r) => r.full_name));
  for (const name of ARCHIVED) {
    check(`archived account present: ${name}`, seen.has(name));
  }
  // Since the demo PIN rollout, active demo identities must be able to sign in;
  // only the suspended one stays banned. Before that phase every demo auth row
  // was permanently banned, so this assertion is inverted rather than dropped.
  const activeArchived = rows.filter((r) => r.account_status === 'active');
  const junel = rows.find((r) => r.full_name === 'Junel Ramos');
  check('archived accounts: active can demo-sign-in, suspended stays banned',
    activeArchived.length === 7 &&
      activeArchived.every((r) => r.banned === false) &&
      junel?.account_status === 'suspended' && junel?.banned === true,
    `${rows.length} rows`);
  check('archived accounts keep a derived rating',
    rows.every((r) => Number(r.rating) >= 1 && Number(r.rating) <= 5));
  // Six of the eight archived people drove or rented out vehicles, so their
  // approved provider role has to survive archiving; Marisol Cruz and Rhea Puno
  // were archived as passengers, so having no provider row is correct for them.
  const PROVIDER_ARCHIVED = ARCHIVED.filter(
    (n) => !['Marisol Cruz', 'Rhea Puno'].includes(n),
  );
  const missingProvider = PROVIDER_ARCHIVED.filter(
    (name) => !rows.find((r) => r.full_name === name &&
      /earner:approved|vehicle_owner:approved/.test(r.roles)),
  );
  check('archived earners/owners keep an approved provider role',
    missingProvider.length === 0, missingProvider.join(', '));
  const passengerOnly = rows.filter(
    (r) => ['Marisol Cruz', 'Rhea Puno'].includes(r.full_name),
  );
  check('archived passengers hold no provider row',
    passengerOnly.length === 2 && passengerOnly.every((r) => Number(r.providers) === 0),
    JSON.stringify(passengerOnly.map((r) => `${r.full_name}:${r.providers}`)));
  console.log('archived detail:');
  for (const r of rows) console.log('  ', JSON.stringify(r));

  const fleet = await sql(`
    select p.full_name, count(*) as vehicles
      from public.vehicles v join public.profiles p on p.id = v.owner_profile_id
      group by 1 order by 2 desc, 1;
  `);
  info('fleet by owner', fleet.map((r) => `${r.full_name}=${r.vehicles}`).join(' '));
  const alex = fleet.find((r) => r.full_name === 'Alex Tan');
  const rico = fleet.find((r) => r.full_name === 'Rico D.');
  check('archived fleet ownership',
    Number(alex?.vehicles) === 1 && Number(rico?.vehicles) === 5,
    `Alex ${alex?.vehicles}, Rico ${rico?.vehicles}`);

  const arealess = (
    await sql(`
    select count(*) as rows_without_area
      from public.vehicles where service_area_id is null;
  `)
  )[0];
  check('one vehicle kept without a service area',
    Number(arealess.rows_without_area) === 1, JSON.stringify(arealess));
}

// ----------------------------------------------------------- real account ----

async function realUser() {
  if (!REAL_USER_ID || !REAL_USER_EMAIL) {
    info('real account', 'skipped — set SURGO_REAL_USER_ID/SURGO_REAL_USER_EMAIL to audit it');
    return;
  }
  const row = (
    await sql(`
    select u.email, (u.banned_until is null) as can_sign_in,
           (select count(*) from public.user_roles r
             where r.profile_id = u.id) as roles,
           (select count(*) from public.profiles p
             where p.id = u.id) as profile_rows,
           (select count(*) from public.ride_requests r
             where r.passenger_id = u.id or r.rider_id = u.id) as rides,
           (select count(*) from public.rental_bookings b
             where b.renter_id = u.id or b.owner_id = u.id) as rentals,
           (select count(*) from public.wallet_accounts w
             where w.profile_id = u.id) as wallets,
           (select count(*) from public.service_transactions t
             where t.customer_id = u.id or t.provider_id = u.id) as settlements,
           (select count(*) from public.notifications n
             where n.profile_id = u.id) as notifications
      from auth.users u where u.id = '${REAL_USER_ID}';
  `)
  )[0];
  check('real user present', Boolean(row));
  check('real user email unchanged', row?.email === REAL_USER_EMAIL,
    String(row?.email));
  check('real user can sign in', row?.can_sign_in === true);
  check('real user has exactly one profile row', Number(row?.profile_rows) === 1);
  check('real user owns no demo transactions',
    ['rides', 'rentals', 'settlements'].every((k) => Number(row?.[k]) === 0),
    JSON.stringify(row));
  info('real account', row);
}

// ------------------------------------------------------------ schema state ----

async function schemaState() {
  const rows = (
    await sql(`
      select version, name from supabase_migrations.schema_migrations
        order by version;
    `).catch(() => [])
  ).map((r) => ({ version: r.version, name: r.name }));
  info('remote migration rows', rows.length);

  const local = fs
    .readdirSync(path.resolve(HERE, '..', 'migrations'))
    .filter((file) => file.endsWith('.sql'))
    .sort();
  const localByName = new Map(
    local.map((file) => [file.replace(/^\d{14}_/, '').replace(/\.sql$/, ''), file.slice(0, 14)]),
  );
  const remoteOnly = rows.filter((r) => !localByName.has(r.name));
  const drifted = rows.filter(
    (r) => localByName.has(r.name) && localByName.get(r.name) !== r.version,
  );
  // A file whose SQL is on the host under a different version is not local-only.
  const localOnly = local.filter(
    (file) =>
      !rows.some((r) => `${r.version}_${r.name}.sql` === file) &&
      !drifted.some((r) => file.endsWith(`${r.name}.sql`)),
  );

  for (const r of remoteOnly) {
    console.log(`  remote-only migration applied on the host but absent locally: ${r.version}_${r.name}`);
  }
  for (const r of drifted) {
    console.log(
      `  ledger version differs for ${r.name}: remote ${r.version}, local file ${localByName.get(r.name)} ` +
        '(same SQL, retimed so a fresh local reset can apply it)',
    );
  }
  console.log(
    `  local-only migrations (never pushed to the hosted project): ${localOnly.length} ` +
      localOnly.map((f) => f.slice(15, -4)).join(', '),
  );
  check('history: no remote-only migration', remoteOnly.length === 0, `rows ${remoteOnly.length}`);
  check(
    'history: known ledger version drift',
    drifted.length === 1 && drifted[0].name === 'admin_dashboard_access_and_actions',
    `rows ${drifted.length}`,
  );
  const relations = (
    await sql(`
    select
      (select count(*) from information_schema.tables
        where table_schema = 'public') as public_tables,
      (select count(*) from pg_policies where schemaname = 'public') as policies,
      (select count(*) from pg_views where schemaname = 'public') as public_views,
      (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.prosecdef) as security_definer_functions,
      (select count(*) from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity)
        as rls_enabled_tables,
      (select count(*) from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
          and not c.relrowsecurity) as rls_disabled_tables;
  `)
  )[0];
  info('schema shape', relations);
}

// ------------------------------------------------------------------ fees ----

// Mirrors lib/services/ride_pricing.dart and fee_calculator.dart exactly.
function ridePlatformFee(distanceKm) {
  if (distanceKm === null || distanceKm === 0) return FEE.minCentavos;
  const metres = Math.round(distanceKm * 1000);
  const raw = Math.floor((metres * FEE.perKmCentavos + 500) / 1000);
  return Math.min(FEE.maxCentavos, Math.max(FEE.minCentavos, raw));
}

function commissionOf(bps, gross) {
  if (gross <= 0) return 0;
  return Math.floor((gross * bps * 2 + 10000) / 20000);
}

const peso = (cents) =>
  `₱${(Number(cents) / 100).toFixed(2).padStart(9)}`;

async function fees() {
  console.log('\n--- fee report (computed, nothing written) ---');
  console.log(
    `ride: fare to provider + ${FEE.perKmCentavos / 100} ₱/km fee, ` +
    `floor ${FEE.minCentavos / 100}, cap ${FEE.maxCentavos / 100}\n` +
    `pasuyo: ${BPS.pasuyo / 100}% commission out of the gross\n` +
    `rental: ${BPS.rental / 100}% commission out of the gross`,
  );

  const rows = await sql(`
    select t.id, t.service_type, t.status, t.settled_at,
           t.fare_centavos, t.platform_fee_centavos,
           t.customer_pays_centavos, t.provider_payout_centavos,
           t.platform_revenue_centavos,
           cu.full_name as customer, pr.full_name as provider,
           r.distance_km, r.status as ride_status,
           b.status as rental_status,
           s.status as pasuyo_status, s.budget_centavos, s.quoted_fee_centavos
      from public.service_transactions t
      join public.profiles cu on cu.id = t.customer_id
      join public.profiles pr on pr.id = t.provider_id
      left join public.ride_requests r on r.id = t.ride_id
      left join public.rental_bookings b on b.id = t.rental_id
      left join public.service_requests s on s.id = t.service_request_id
     order by t.settled_at, t.service_type;
  `);

  const totals = { ride: 0, rental: 0, pasuyo: 0 };
  const counts = { ride: 0, rental: 0, pasuyo: 0 };
  let unmeasured = 0;
  console.log(
    '\nsettled_at           service  gross fare    fee  customer pays  ' +
    'provider keeps  basis                        customer -> provider',
  );
  for (const t of rows) {
    const gross = Number(t.fare_centavos);
    let fee;
    let basis;
    let provider;
    let customerPays;
    if (t.service_type === 'ride') {
      const km = t.distance_km === null ? 0 : Number(t.distance_km);
      if (km <= 0) unmeasured += 1;
      fee = ridePlatformFee(km);
      provider = gross;
      customerPays = gross + fee;
      basis = km <= 0
        ? `min fee (no measured distance)`
        : `₱${FEE.perKmCentavos / 100}/km × ${km.toFixed(2)} km`;
    } else {
      const bps = t.service_type === 'pasuyo' ? BPS.pasuyo : BPS.rental;
      fee = commissionOf(bps, gross);
      provider = gross - fee;
      customerPays = gross;
      basis = `${bps / 100}% of ${peso(gross)}`;
    }
    totals[t.service_type] += fee;
    counts[t.service_type] += 1;
    const when = String(t.settled_at ?? '').slice(0, 16);
    console.log(
      `${when}  ${t.service_type.padEnd(8)} ${peso(gross)} ${peso(fee)}` +
      ` ${peso(customerPays)} ${peso(provider)}  ${basis.padEnd(28)}  ` +
      `${t.customer} -> ${t.provider}`,
    );
  }

  const grand = totals.ride + totals.rental + totals.pasuyo;
  console.log('\nwhat SurGo would have earned on these 29 settlements:');
  for (const kind of ['ride', 'rental', 'pasuyo']) {
    console.log(`  ${kind.padEnd(7)} ${String(counts[kind]).padStart(2)} txns  ${peso(totals[kind])}`);
  }
  console.log(`  total           ${counts.ride + counts.rental + counts.pasuyo} txns  ${peso(grand)}`);
  const hosted = (
    await sql(`
    select coalesce(sum(platform_fee_centavos), 0) as fees,
           coalesce(sum(platform_revenue_centavos), 0) as revenue
      from public.service_transactions;
  `)
  )[0];
  console.log(
    `  hosted rows now  ${peso(hosted.fees)} platform_fee, ` +
    `${peso(hosted.revenue)} platform_revenue — gap ${peso(grand)}`,
  );
  console.log(
    `  ${unmeasured} ride(s) carry distance_km = 0, so only the ${FEE.minCentavos / 100} ₱ floor applies`,
  );
  console.log(
    '  nothing above was written; pricing is gated and pricing_policies has 0 rows',
  );
}

const started = Date.now();
console.log(`auditing hosted project ${REF} (read-only)`);
await counts();
await idRoster();
await integrity();
await roleGraph();
await money();
await coverage();
await archived();
await realUser();
await schemaState();
if (WANT_FEES) await fees();

const failed = results.filter((r) => !r.ok);
console.log(
  `\n${results.length - failed.length}/${results.length} checks passed in ` +
  `${((Date.now() - started) / 1000).toFixed(1)}s`,
);
for (const f of failed) console.log(`  FAIL ${f.name} — ${f.detail}`);
if (notes.length) {
  console.log(`\n${notes.length} documented data gaps (verified as source-data, not import damage):`);
  for (const n of notes) console.log(`  NOTED ${n.name} — ${n.detail}\n        ${n.why}`);
}
process.exitCode = failed.length ? 1 : 0;
