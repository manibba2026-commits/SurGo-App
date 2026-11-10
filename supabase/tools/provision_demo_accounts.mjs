// Provisions the 19 fictional demo people for phone + PIN sign-in, in place.
//
// It never creates a user: every target is one of the deterministic profile
// ids supabase/demo-data.sql already seeded, so profiles, roles, wallets,
// rides and notifications keep their associations.
//
//   node supabase/tools/provision_demo_accounts.mjs                 # plan (read-only)
//   SURGO_DEMO_PROVISION=confirm-19-demo-pins \
//   SUPABASE_SERVICE_ROLE_KEY=... \
//     node supabase/tools/provision_demo_accounts.mjs --apply --verify-login
//
// Safety rules baked into this tool:
//   * Plan is the default. Nothing is written without --apply *and* the exact
//     confirmation token above.
//   * No account is ever created or deleted. Missing target ids abort the run.
//   * No email password is generated. Each account gets its own random 6-digit
//     PIN, hashed with PBKDF2-SHA256 (210,000 rounds) and stored only as a hash
//     in private.demo_access. The plaintext PIN is written only to a file
//     outside the repository, never to stdout, the log, or a tracked file.
//   * The service-role key is read from the environment and is never printed.
//   * profiles.account_status is never touched, so a suspended demo person
//     (Junel Ramos) stays suspended.
//   * Reads use the Management API channel the other tools already share. The
//     identity-repair and profile-sync statements are idempotent, so a rerun
//     converges instead of duplicating rows. Rerunning rotates every PIN.
//   * --verify-login signs in through the deployed demo-login function and
//     checks the returned user id before the account is reported usable.
//
// The 19 ids are derived exactly as gen_demo_data.mjs derives them
// (md5('surgo:demo:profile:<slug>')), so this tool and the seed cannot drift.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { REF, sql } from './db_admin.mjs';
import {
  EMAIL,
  UUID,
  demoPeople,
  generateDemoPins,
  isInsideRepo,
  normalizePhone,
  toLocalPhone,
} from './demo_provision_plan.mjs';
import { hashDemoPin, verifyDemoPin } from './demo_pin.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const usersJson = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'assets', 'db', 'users.json'), 'utf8'),
);

const CONFIRM_ENV = 'SURGO_DEMO_PROVISION';
const CONFIRM_VALUE = 'confirm-19-demo-pins';
const MIGRATION_FILE = '20261111140000_demo_pin_access.sql';
const EDGE_FUNCTION = 'demo-login';

// Public values: the project ref is public and this publishable key is already
// shipped in the app and in lib/admin/.env.example. The service-role key is
// not here and never will be.
const PROJECT_URL = `https://${REF}.supabase.co`;
const PUBLISHABLE_KEY =
  process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_WszPDYOAKw3dYZ1QAElSXA_mpW1rckw';

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;

function assertUuid(value) {
  if (!UUID.test(value)) throw new Error(`refusing malformed id: ${value}`);
  return value;
}
function assertEmail(value) {
  if (!EMAIL.test(value)) throw new Error(`refusing malformed email: ${value}`);
  return value;
}
function assertPhone(value) {
  const normalized = normalizePhone(value);
  if (!normalized) throw new Error(`refusing malformed phone: ${value}`);
  return normalized;
}

async function readHostedState(people) {
  const list = people.map((p) => quote(assertUuid(p.id))).join(', ');
  const rows = await sql(`
    select
      p.id::text as id,
      p.full_name,
      p.email as profile_email,
      u.email as auth_email,
      p.phone as profile_phone,
      u.phone as auth_phone,
      p.account_status::text as account_status,
      (u.banned_until is not null) as banned,
      (u.email_confirmed_at is not null) as email_confirmed,
      exists(
        select 1 from auth.identities i
        where i.user_id = p.id and i.provider = 'email'
      ) as has_email_identity,
      coalesce((
        select string_agg(r.role::text, ',' order by r.role::text)
        from public.user_roles r
        where r.profile_id = p.id and r.status = 'approved'
      ), '') as roles
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.id in (${list})
    order by p.full_name;
  `);
  return rows;
}

async function readEmailConflicts(people) {
  const emails = people.map((p) => quote(assertEmail(p.targetEmail))).join(', ');
  return sql(`
    select id::text as id, email
    from auth.users
    where lower(email) in (${emails})
  `);
}

async function readPhoneConflicts(people) {
  // Compare normalized values in JS: a stored "+63 917 ..." and a planned
  // "+63917..." are the same subscriber even though SQL `in` would miss it.
  const rows = await sql(`
    select 'auth' as source, id::text as id, phone
      from auth.users
     where phone is not null
    union all
    select 'profile', id::text, phone
      from public.profiles
     where phone is not null
  `);
  const targets = new Set(people.map((p) => p.phone));
  const byId = new Map();
  for (const row of rows) {
    if (!targets.has(normalizePhone(row.phone))) continue;
    const key = row.id;
    if (!byId.has(key)) byId.set(key, { id: row.id, phone: row.phone });
  }
  return [...byId.values()];
}

async function readDatabaseShape() {
  const [row] = await sql(`
    select
      to_regclass('private.demo_access') is not null as pin_table,
      exists(
        select 1
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'demo_login_lookup'
      ) as login_rpc
  `);
  return { pinTable: row?.pin_table === true, loginRpc: row?.login_rpc === true };
}

async function readDemoAccessIds(people) {
  const list = people.map((p) => quote(assertUuid(p.id))).join(', ');
  const rows = await sql(`
    select user_id::text as id, pin_hash
    from private.demo_access
    where user_id in (${list})
  `);
  return new Map(rows.map((row) => [row.id, row.pin_hash]));
}

function formatChange(value, fallback = '(none)') {
  return value == null || value === '' ? fallback : value;
}

function plan(people, state, conflicts, shape, pinIds) {
  const byId = new Map(state.map((row) => [row.id, row]));
  const conflictByEmail = new Map(
    conflicts.emails.map((row) => [String(row.email).toLowerCase(), row.id]),
  );

  const missing = people.filter((p) => !byId.has(p.id));
  if (missing.length) {
    console.error(
      `ABORT: ${missing.length} demo profile(s) are not in the hosted project:\n` +
        missing.map((p) => `  ${p.name}  ${p.id}`).join('\n'),
    );
    process.exitCode = 1;
    return null;
  }

  const wrongEmailOwner = people.filter((p) => {
    const owner = conflictByEmail.get(p.targetEmail);
    return owner && owner !== p.id;
  });
  const wrongPhoneOwner = people.filter((p) =>
    conflicts.phones.some(
      (row) => row.id !== p.id && normalizePhone(row.phone) === p.phone,
    ),
  );
  if (wrongEmailOwner.length || wrongPhoneOwner.length) {
    console.error('ABORT: a target identifier already belongs to another user:');
    for (const p of wrongEmailOwner) {
      console.error(`  email ${p.targetEmail} -> ${p.id}`);
    }
    for (const p of wrongPhoneOwner) {
      console.error(`  phone ${p.phone} -> ${p.id}`);
    }
    process.exitCode = 1;
    return null;
  }

  const assignedPhones = people.filter((p) => p.phoneAssigned).length;
  const preservedPhones = people.length - assignedPhones;
  const summary = {
    total: people.length,
    synthetic: people.filter((p) => p.syntheticEmail).length,
    banned: state.filter((row) => row.banned).length,
    withoutConfirmation: state.filter((row) => !row.email_confirmed).length,
    withoutIdentity: state.filter((row) => !row.has_email_identity).length,
    withPin: pinIds.size,
    assignedPhones,
    preservedPhones,
    suspended: state.filter((row) => row.account_status === 'suspended').length,
  };

  console.log('SurGo demo account provisioning plan (read-only)\n');
  for (const person of people) {
    const row = byId.get(person.id);
    const changes = [
      row.auth_email?.toLowerCase() !== person.targetEmail
        ? `email ${formatChange(row.auth_email)} -> ${person.targetEmail}${person.syntheticEmail ? ' (synth)' : ''}`
        : 'email unchanged',
      `phone ${toLocalPhone(person.phone)} (${person.phone})${person.phoneAssigned ? ' assigned' : ' preserved'}`,
      row.banned ? 'unban' : 'not banned',
      row.email_confirmed ? 'confirmed' : 'confirm email',
      row.has_email_identity ? 'identity ok' : 'add email identity',
      pinIds.has(person.id) ? 'PIN will rotate' : 'set PIN',
      row.account_status === 'suspended' ? 'SUSPENDED (preserved)' : 'active',
    ];
    console.log(
      `${person.name}\n  ${person.id}  roles: ${row.roles || '(none)'}\n  ${changes.join(' · ')}`,
    );
  }

  console.log(
    `\n${summary.total} accounts · ${summary.synthetic} synthetic emails · ` +
      `${summary.preservedPhones} preserved phones · ${summary.assignedPhones} assigned demo phones · ` +
      `${summary.banned} banned · ${summary.withoutIdentity} without an email identity · ` +
      `${summary.withoutConfirmation} unconfirmed · ${summary.withPin} with a demo PIN`,
  );
  if (summary.suspended) {
    console.log(`${summary.suspended} suspended profile(s) will stay suspended.`);
  }
  if (!shape.pinTable) {
    console.log(
      `\nWARNING: private.demo_access is not installed on the hosted project yet. ` +
        `Apply supabase/migrations/${MIGRATION_FILE} before --apply.`,
    );
  }
  console.log(
    `\nNo changes were made. To apply after approval:\n` +
      `  ${CONFIRM_ENV}=${CONFIRM_VALUE} SUPABASE_SERVICE_ROLE_KEY=<key> \\\n` +
      `    node supabase/tools/provision_demo_accounts.mjs --apply --verify-login\n` +
      `Each PIN is written once to a file outside the repository; never commit or share it.`,
  );
  return summary;
}

async function adminUpdateUser(person) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const res = await fetch(`${PROJECT_URL}/auth/v1/admin/users/${person.id}`, {
    method: 'PUT',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email: person.targetEmail,
      email_confirm: true,
      phone: person.phone,
      phone_confirm: true,
      ban_duration: 'none',
      user_metadata: {
        full_name: person.name,
        first_name: person.slug,
        surgo_onboarded: true,
        // Marks the row as fictional demo data and is what set_demo_access
        // checks before accepting a PIN. It is not a credential.
        surgo_demo: true,
      },
    }),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(
      `admin update failed (HTTP ${res.status}): ${text.slice(0, 300)}`,
    );
  }
}

// Seeded auth rows were inserted with SQL, so they carry no identity row.
// Repairing it keeps the auth user consistent for admin tooling and the
// dashboard; it grants no password or email login by itself.
async function repairEmailIdentity(person) {
  await sql(`
    insert into auth.identities
      (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    select
      u.id::text,
      u.id,
      jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
      'email',
      now(), now(), now()
    from auth.users u
    where u.id = ${quote(assertUuid(person.id))}
      and u.email = ${quote(assertEmail(person.targetEmail))}
      and not exists (
        select 1 from auth.identities i
        where i.user_id = u.id and i.provider = 'email'
      );
  `);
}

async function syncProfileEmail(person) {
  await sql(`
    update public.profiles
       set email = ${quote(assertEmail(person.targetEmail))},
           updated_at = now()
     where id = ${quote(assertUuid(person.id))}
       and coalesce(lower(email), '') <> ${quote(person.targetEmail)};
  `);
}

async function syncProfilePhone(person) {
  await sql(`
    update public.profiles
       set phone = ${quote(assertPhone(person.phone))},
           updated_at = now()
     where id = ${quote(assertUuid(person.id))}
       and coalesce(phone, '') <> ${quote(person.phone)};
  `);
}

async function setDemoAccess(person, pin) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const res = await fetch(`${PROJECT_URL}/rest/v1/rpc/set_demo_access`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_user_id: person.id,
      p_pin_hash: hashDemoPin(pin),
    }),
  });
  if (!res.ok) {
    // Do not echo the response: it may quote the request body.
    throw new Error(`set_demo_access failed (HTTP ${res.status})`);
  }
}

async function verifyDemoLogin(person, pin) {
  const res = await fetch(`${PROJECT_URL}/functions/v1/${EDGE_FUNCTION}`, {
    method: 'POST',
    headers: {
      apikey: PUBLISHABLE_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ phone: person.phone, pin }),
  });
  if (!res.ok) {
    return { ok: false, detail: `HTTP ${res.status}` };
  }
  const body = await res.json().catch(() => null);
  if (body?.session?.user?.id !== person.id) {
    return { ok: false, detail: 'session belongs to a different user' };
  }
  return { ok: true };
}

function credentialsPath(argv) {
  const flag = argv.indexOf('--out');
  const explicit = flag >= 0 ? argv[flag + 1] : process.env.SURGO_DEMO_CREDENTIALS_FILE;
  if (explicit) return path.resolve(explicit);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').replace('Z', '');
  return path.join(
    os.homedir(),
    'surgo-demo-credentials',
    `demo-pins-${stamp}.json`,
  );
}

function assertOutsideRepo(file) {
  if (isInsideRepo(repoRoot, file)) {
    throw new Error(
      `refusing to write PINs inside the repository: ${file}\n` +
        'Choose a path outside the repo with --out or SURGO_DEMO_CREDENTIALS_FILE.',
    );
  }
  if (fs.existsSync(file)) {
    throw new Error(`refusing to overwrite an existing PIN file: ${file}`);
  }
}

function writePinFile(file, accounts) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const payload = {
    generated_at: new Date().toISOString(),
    project_ref: REF,
    note:
      'Demo-only SurGo accounts. Sign in with the phone (E.164 or 09 form) and ' +
      'the per-account PIN. Keep this file outside the repository and any ' +
      'shared drive. No email password is stored because none exists.',
    accounts,
  };
  fs.writeFileSync(file, `${JSON.stringify(payload, null, 2)}\n`, {
    mode: 0o600,
    flag: 'wx',
  });
}

async function apply(people, outFile, verifyLogin) {
  if (process.env[CONFIRM_ENV] !== CONFIRM_VALUE) {
    throw new Error(
      `refusing to modify the hosted project. Set ${CONFIRM_ENV}=${CONFIRM_VALUE} and rerun with --apply.`,
    );
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error(
      'SUPABASE_SERVICE_ROLE_KEY is required for --apply. It is read from the environment only.',
    );
  }
  assertOutsideRepo(outFile);

  const shape = await readDatabaseShape();
  if (!shape.pinTable || !shape.loginRpc) {
    throw new Error(
      `migration 20261111140000_demo_pin_access.sql is not installed. ` +
        'Apply it before provisioning. Nothing was changed.',
    );
  }

  const state = await readHostedState(people);
  if (state.length !== people.length) {
    throw new Error(
      `expected ${people.length} hosted demo profiles, found ${state.length}. Nothing was changed.`,
    );
  }
  const emails = await readEmailConflicts(people);
  const phones = await readPhoneConflicts(people);
  const conflictByEmail = new Map(
    emails.map((row) => [String(row.email).toLowerCase(), row.id]),
  );
  for (const person of people) {
    const emailOwner = conflictByEmail.get(person.targetEmail);
    if (emailOwner && emailOwner !== person.id) {
      throw new Error(
        `${person.targetEmail} already belongs to auth user ${emailOwner}. Nothing was changed.`,
      );
    }
    const phoneOwner = phones.find(
      (row) => row.id !== person.id && normalizePhone(row.phone) === person.phone,
    );
    if (phoneOwner) {
      throw new Error(
        `${person.phone} already belongs to auth user ${phoneOwner.id}. Nothing was changed.`,
      );
    }
  }
  if (new Set(people.map((p) => p.phone)).size !== people.length) {
    throw new Error('two demo people map to the same phone. Nothing was changed.');
  }

  const pins = generateDemoPins(people);
  const existingPins = await readDemoAccessIds(people);
  const stateById = new Map(state.map((row) => [row.id, row]));
  const accounts = [];
  const failures = [];
  const warnings = [];

  for (const person of people) {
    const pin = pins.get(person.id);
    try {
      await adminUpdateUser(person);
      await repairEmailIdentity(person);
      await syncProfileEmail(person);
      await syncProfilePhone(person);
      await setDemoAccess(person, pin);

      const stored = await readDemoAccessIds([person]);
      const hash = stored.get(person.id);
      if (!hash || !verifyDemoPin(pin, hash)) {
        throw new Error('stored PIN hash did not verify after write');
      }

      let loginVerified = null;
      if (verifyLogin) {
        const check = await verifyDemoLogin(person, pin);
        loginVerified = check.ok;
        if (!check.ok) {
          // The PIN is already valid in the database; keep it in the file but
          // surface the deployment problem instead of throwing the PIN away.
          warnings.push({
            name: person.name,
            id: person.id,
            error: `demo-login verification failed: ${check.detail}`,
          });
          console.error(
            `WARNING ${person.name}: PIN set, but demo-login verification failed (${check.detail})`,
          );
        }
      }

      accounts.push({
        name: person.name,
        role_labels: (stateById.get(person.id)?.roles || '')
          .split(',')
          .filter(Boolean),
        phone_e164: person.phone,
        phone_local: toLocalPhone(person.phone),
        pin,
        user_id: person.id,
        email: person.targetEmail,
        synthetic_email: person.syntheticEmail,
        phone_assigned: person.phoneAssigned,
        account_status: stateById.get(person.id)?.account_status ?? 'active',
        login_verified: loginVerified,
        pin_rotated: existingPins.has(person.id),
      });
      console.log(
        `provisioned  ${person.name}  ${toLocalPhone(person.phone)}  ` +
          `${person.targetEmail}${person.syntheticEmail ? ' (synthetic)' : ''}  ` +
          `PIN ${existingPins.has(person.id) ? 'rotated' : 'set'}` +
          `${verifyLogin ? '; demo-login verified' : ''}`,
      );
    } catch (e) {
      failures.push({ name: person.name, id: person.id, error: e.message });
      console.error(`FAILED  ${person.name}: ${e.message}`);
    }
  }

  if (accounts.length) {
    writePinFile(outFile, accounts);
    console.log(`\nWrote ${accounts.length} phone/PIN record(s) to: ${outFile}`);
    console.log('Keep that file private. It is outside the repository by design.');
  } else {
    console.error('\nNo account was provisioned, so no PIN file was written.');
  }
  if (warnings.length) {
    console.error(
      `\n${warnings.length} account(s) were provisioned but failed demo-login verification.`,
    );
    process.exitCode = 1;
  }
  if (failures.length) {
    console.error(`\n${failures.length} account(s) failed. They are not in the file.`);
    process.exitCode = 1;
  }
}

const argv = process.argv.slice(2);
const people = demoPeople(usersJson);

if (people.length !== 19) {
  console.error(`ABORT: expected 19 demo people, derived ${people.length}.`);
  process.exit(1);
}
if (new Set(people.map((p) => p.phone)).size !== people.length) {
  console.error('ABORT: the demo phone assignment is not unique.');
  process.exit(1);
}

try {
  if (!argv.includes('--apply')) {
    const state = await readHostedState(people);
    const emails = await readEmailConflicts(people);
    const phones = await readPhoneConflicts(people);
    const shape = await readDatabaseShape();
    const pinIds = shape.pinTable
      ? await readDemoAccessIds(people)
      : new Map();
    plan(people, state, { emails, phones }, shape, pinIds);
  } else {
    await apply(people, credentialsPath(argv), argv.includes('--verify-login'));
  }
} catch (e) {
  console.error(`ABORT: ${e.message}`);
  process.exitCode = 1;
}
