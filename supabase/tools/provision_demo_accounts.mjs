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
//   SURGO_DEMO_UNLOCK=confirm-demo-unlock \
//   SUPABASE_SERVICE_ROLE_KEY=... \
//     node supabase/tools/provision_demo_accounts.mjs --unlock \
//       --credentials <file written by --apply>
//
// Safety rules baked into this tool:
//   * Plan is the default. Nothing is written without --apply *and* the exact
//     confirmation token above. --unlock has its own token.
//   * No account is ever created or deleted. Missing target ids abort the run.
//   * Order per person: update contact/metadata while still banned, establish
//     the email identity, write and verify the PIN hash, persist and read back
//     the private credential file, then unban. Any failure re-bans the account.
//   * No email password is generated. Each account gets its own random 6-digit
//     PIN, hashed with PBKDF2-SHA256 (210,000 rounds) and stored only as a hash
//     in private.demo_access. The plaintext PIN is written only to a file
//     outside the repository, never to stdout, the log, or a tracked file.
//   * Each account's address is a reserved .test address, so recovery and
//     magic-link mail cannot reach a real inbox.
//   * surgo_demo is written to app_metadata (service-role only) and stripped
//     from the user-writable user_metadata.
//   * The service-role key is read from the environment and is never printed.
//   * profiles.account_status is never touched, so a suspended demo person
//     (Junel Ramos) stays suspended and banned.
//   * Reads use the Management API channel the other tools already share. The
//     identity-repair and profile-sync statements are idempotent, so a rerun
//     converges instead of duplicating rows. Rerunning rotates every PIN.
//   * --verify-login signs in through the deployed demo-login function after
//     the unban and checks the returned user id.

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
  isSyncedFolder,
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
const UNLOCK_ENV = 'SURGO_DEMO_UNLOCK';
const UNLOCK_VALUE = 'confirm-demo-unlock';
const MIGRATION_FILE = '20261111140000_demo_pin_access.sql';
const EDGE_FUNCTION = 'demo-login';
const BAN_DURATION = '876000h';

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

function serviceHeaders() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error('SUPABASE_SERVICE_ROLE_KEY is required');
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  };
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
      (u.banned_until is not null and u.banned_until > now()) as banned,
      (u.email_confirmed_at is not null) as email_confirmed,
      (u.raw_app_meta_data ->> 'surgo_demo') = 'true' as app_demo,
      (u.raw_user_meta_data ->> 'surgo_demo') = 'true' as user_demo,
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
           and p.proname = 'demo_login_reserve_attempt'
      ) as reserve_rpc,
      exists(
        select 1
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'demo_login_clear_lockout'
      ) as unlock_rpc
  `);
  return {
    pinTable: row?.pin_table === true,
    reserveRpc: row?.reserve_rpc === true,
    unlockRpc: row?.unlock_rpc === true,
  };
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

  const summary = {
    total: people.length,
    synthetic: people.filter((p) => p.syntheticEmail).length,
    banned: state.filter((row) => row.banned).length,
    withoutConfirmation: state.filter((row) => !row.email_confirmed).length,
    withoutIdentity: state.filter((row) => !row.has_email_identity).length,
    withAppFlag: state.filter((row) => row.app_demo).length,
    withUserFlag: state.filter((row) => row.user_demo).length,
    withPin: pinIds.size,
    suspended: state.filter((row) => row.account_status === 'suspended').length,
  };

  console.log('SurGo demo account provisioning plan (read-only)\n');
  for (const person of people) {
    const row = byId.get(person.id);
    const suspended = row.account_status === 'suspended';
    const changes = [
      row.auth_email?.toLowerCase() !== person.targetEmail
        ? `email ${formatChange(row.auth_email)} -> ${person.targetEmail} (synthetic)`
        : 'synthetic email ok',
      `phone ${toLocalPhone(person.phone)} (${person.phone}) assigned`,
      suspended ? 'STAY BANNED/SUSPENDED' : 'unban last',
      row.email_confirmed ? 'email confirmed' : 'confirm email',
      row.has_email_identity ? 'identity ok' : 'add email identity',
      row.app_demo ? 'app_metadata demo flag ok' : 'set app_metadata demo flag',
      row.user_demo ? 'strip user_metadata flag' : 'no user_metadata flag',
      pinIds.has(person.id) ? 'PIN will rotate' : 'set PIN',
    ];
    console.log(
      `${person.name}\n  ${person.id}  roles: ${row.roles || '(none)'}\n  ${changes.join(' · ')}`,
    );
  }

  console.log(
    `\n${summary.total} accounts · ${summary.synthetic} synthetic emails · ` +
      `${summary.withAppFlag} with the trusted demo flag · ${summary.withUserFlag} with the old user flag · ` +
      `${summary.banned} banned · ${summary.withoutIdentity} without an email identity · ` +
      `${summary.withoutConfirmation} unconfirmed · ${summary.withPin} with a demo PIN`,
  );
  if (summary.suspended) {
    console.log(`${summary.suspended} suspended profile(s) will stay suspended.`);
  }
  if (!shape.pinTable || !shape.reserveRpc) {
    console.log(
      `\nWARNING: the demo access schema or reservation RPC is not installed yet. ` +
        `Apply supabase/migrations/${MIGRATION_FILE} before --apply.`,
    );
  }
  console.log(
    `\nNo changes were made. To apply after approval:\n` +
      `  ${CONFIRM_ENV}=${CONFIRM_VALUE} SUPABASE_SERVICE_ROLE_KEY=<key> \\\n` +
      `    node supabase/tools/provision_demo_accounts.mjs --apply --verify-login\n` +
      `Each PIN is written once to a file outside the repository; never commit or share it.\n\n` +
      `To clear a locked demo account without rotating its PIN:\n` +
      `  ${UNLOCK_ENV}=${UNLOCK_VALUE} SUPABASE_SERVICE_ROLE_KEY=<key> \\\n` +
      `    node supabase/tools/provision_demo_accounts.mjs --unlock --credentials <file>`,
  );
  return summary;
}

// Step 1: contact and descriptive metadata. The ban is deliberately left in
// place; only the final unban call may lift it.
async function adminUpdateUser(person) {
  const res = await fetch(`${PROJECT_URL}/auth/v1/admin/users/${person.id}`, {
    method: 'PUT',
    headers: serviceHeaders(),
    body: JSON.stringify({
      email: person.targetEmail,
      email_confirm: true,
      phone: person.phone,
      phone_confirm: true,
      user_metadata: {
        full_name: person.name,
        first_name: person.slug,
        surgo_onboarded: true,
      },
    }),
  });
  await res.text();
  if (!res.ok) {
    // The body can quote the request; report only the status.
    throw new Error(`admin update failed (HTTP ${res.status})`);
  }
}

// surgo_demo must be in raw_app_meta_data, which only the service role can
// write. The admin API merges user metadata, so the old user-writable copy is
// removed explicitly.
async function markDemoFlags(person) {
  const rows = await sql(`
    update auth.users u
       set raw_app_meta_data =
             coalesce(u.raw_app_meta_data, '{}'::jsonb)
             || jsonb_build_object('surgo_demo', true),
           raw_user_meta_data =
             coalesce(u.raw_user_meta_data, '{}'::jsonb) - 'surgo_demo',
           updated_at = now()
     where u.id = ${quote(assertUuid(person.id))}
    returning u.id::text as id;
  `);
  if (!Array.isArray(rows) || rows.length !== 1) {
    throw new Error('app_metadata demo flag was not written');
  }
}

async function readAdminUser(person) {
  const res = await fetch(`${PROJECT_URL}/auth/v1/admin/users/${person.id}`, {
    headers: serviceHeaders(),
  });
  if (!res.ok) {
    throw new Error(`admin read failed (HTTP ${res.status})`);
  }
  const body = await res.json();
  const bannedUntil = body?.banned_until
    ? Date.parse(body.banned_until)
    : NaN;
  return {
    banned: Number.isFinite(bannedUntil) && bannedUntil > Date.now(),
    email: body?.email ?? null,
    phone: body?.phone ?? null,
    appDemo: body?.app_metadata?.surgo_demo === true,
    userDemo: body?.user_metadata?.surgo_demo === true,
  };
}

async function adminBan(person) {
  const res = await fetch(`${PROJECT_URL}/auth/v1/admin/users/${person.id}`, {
    method: 'PUT',
    headers: serviceHeaders(),
    body: JSON.stringify({ ban_duration: BAN_DURATION }),
  });
  if (!res.ok) throw new Error(`ban failed (HTTP ${res.status})`);
}

async function adminUnban(person) {
  const res = await fetch(`${PROJECT_URL}/auth/v1/admin/users/${person.id}`, {
    method: 'PUT',
    headers: serviceHeaders(),
    body: JSON.stringify({ ban_duration: 'none' }),
  });
  if (!res.ok) throw new Error(`unban failed (HTTP ${res.status})`);
}

// The seed rows were inserted with SQL, not through GoTrue, so they can carry
// values GoTrue's queries cannot read: a NULL instance_id (it lists users by
// the zero UUID), NULL token columns, or an 'infinity' ban. The admin API then
// answers 404 or 500 before any update lands. This repair is idempotent and
// preserves the ban; only the unban call at the end lifts it.
async function repairAuthRows(people) {
  const ids = people.map((p) => quote(assertUuid(p.id))).join(', ');
  const rows = await sql(`
    update auth.users u
       set instance_id = coalesce(
             u.instance_id,
             '00000000-0000-0000-0000-000000000000'::uuid
           ),
           confirmation_token = coalesce(u.confirmation_token, ''),
           recovery_token = coalesce(u.recovery_token, ''),
           email_change_token_new = coalesce(u.email_change_token_new, ''),
           email_change_token_current = coalesce(u.email_change_token_current, ''),
           phone_change_token = coalesce(u.phone_change_token, ''),
           reauthentication_token = coalesce(u.reauthentication_token, ''),
           banned_until = case
             when u.banned_until = 'infinity'::timestamptz
               then now() + interval '876000 hours'
             else u.banned_until
           end,
           updated_at = now()
     where u.id in (${ids})
    returning u.id::text as id;
  `);
  if (!Array.isArray(rows) || rows.length !== people.length) {
    throw new Error('auth row compatibility repair did not touch every demo account');
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
  const res = await fetch(`${PROJECT_URL}/rest/v1/rpc/set_demo_access`, {
    method: 'POST',
    headers: serviceHeaders(),
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
  let res;
  try {
    res = await fetch(`${PROJECT_URL}/functions/v1/${EDGE_FUNCTION}`, {
      method: 'POST',
      headers: {
        apikey: PUBLISHABLE_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ phone: person.phone, pin }),
    });
  } catch {
    return { ok: false, detail: 'network error' };
  }
  if (!res.ok) {
    return { ok: false, detail: `HTTP ${res.status}` };
  }
  const body = await res.json().catch(() => null);
  if (body?.session?.user?.id !== person.id) {
    return { ok: false, detail: 'session belongs to a different user' };
  }
  return { ok: true };
}

function defaultCredentialsPath() {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').replace('Z', '');
  return path.join(
    os.homedir(),
    'surgo-demo-credentials',
    `demo-pins-${stamp}.json`,
  );
}

function applyCredentialsPath(argv) {
  const flag = argv.indexOf('--out');
  const explicit = flag >= 0 ? argv[flag + 1] : process.env.SURGO_DEMO_CREDENTIALS_FILE;
  return explicit ? path.resolve(explicit) : defaultCredentialsPath();
}

function unlockCredentialsPath(argv) {
  const flag = argv.indexOf('--credentials');
  const explicit = flag >= 0 ? argv[flag + 1] : process.env.SURGO_DEMO_CREDENTIALS_FILE;
  if (!explicit) {
    throw new Error(
      'Pass --credentials <file> (the PIN file provision_demo_accounts.mjs wrote outside the repo).',
    );
  }
  return path.resolve(explicit);
}

function assertCredentialPath(file) {
  if (isInsideRepo(repoRoot, file)) {
    throw new Error(
      `refusing to use a credential file inside the repository: ${file}\n` +
        'Choose a path outside the repo with --out/--credentials or SURGO_DEMO_CREDENTIALS_FILE.',
    );
  }
  if (isSyncedFolder(file)) {
    throw new Error(
      `refusing to use a synced folder for plaintext PINs: ${file}\n` +
        'Choose a local path that is not inside OneDrive, Dropbox, Google Drive, iCloud or Box.',
    );
  }
}

function checkPrivatePermissions(file) {
  if (process.platform === 'win32') return;
  const mode = fs.statSync(file).mode & 0o777;
  if (mode & 0o077) {
    throw new Error(
      `credential file is readable by others (mode ${mode.toString(8)}): ${file}`,
    );
  }
}

function createCredentialFile(file, startedAt) {
  assertCredentialPath(file);
  if (fs.existsSync(file)) {
    throw new Error(`refusing to overwrite an existing PIN file: ${file}`);
  }
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, credentialJson(startedAt, []), {
    mode: 0o600,
    flag: 'wx',
  });
}

function credentialJson(startedAt, accounts) {
  return `${JSON.stringify(
    {
      generated_at: startedAt,
      project_ref: REF,
      note:
        'Demo-only SurGo accounts. Sign in with the phone (E.164 or 09 form) and ' +
        'the per-account PIN. Keep this file outside the repository and any ' +
        'shared or synced drive. No email password is stored because none exists.',
      accounts,
    },
    null,
    2,
  )}\n`;
}

// Rewrites the file atomically after every account so a crash never leaves a
// provisioned PIN that exists only in memory. The read-back is the proof that
// the unban that follows can be recovered.
function persistCredentials(file, startedAt, accounts) {
  const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmp, credentialJson(startedAt, accounts), {
    mode: 0o600,
    flag: 'wx',
  });
  fs.renameSync(tmp, file);
  checkPrivatePermissions(file);
  const readBack = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (JSON.stringify(readBack.accounts) !== JSON.stringify(accounts)) {
    throw new Error(`credential file read-back did not match: ${file}`);
  }
}

function readCredentialFile(file) {
  assertCredentialPath(file);
  checkPrivatePermissions(file);
  const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
  const rows = payload?.accounts;
  if (!Array.isArray(rows) || rows.length !== 19) {
    throw new Error(`expected 19 PIN rows, found ${rows?.length ?? 0}`);
  }
  const accounts = rows.map((row, index) => {
    if (typeof row?.user_id !== 'string' || !UUID.test(row.user_id)) {
      throw new Error(`PIN row ${index + 1} has a malformed user id`);
    }
    const phone = normalizePhone(row.phone_e164 ?? row.phone ?? row.phone_local);
    if (!phone) throw new Error(`PIN row ${index + 1} has an invalid phone number`);
    if (!/^\d{6}$/.test(row.pin ?? '')) {
      throw new Error(`PIN row ${index + 1} has no six-digit PIN`);
    }
    if (typeof row.email !== 'string' || !row.email.endsWith('@surgo-demo.test')) {
      throw new Error(`PIN row ${index + 1} does not use a reserved demo email`);
    }
    return {
      name: row.name ?? phone,
      userId: row.user_id,
      phone,
      email: row.email,
      pin: row.pin,
    };
  });
  if (new Set(accounts.map((a) => a.userId)).size !== accounts.length) {
    throw new Error('PIN file contains duplicate user ids');
  }
  if (new Set(accounts.map((a) => a.phone)).size !== accounts.length) {
    throw new Error('PIN file contains duplicate phone numbers');
  }
  return accounts;
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
  assertCredentialPath(outFile);

  const shape = await readDatabaseShape();
  if (!shape.pinTable || !shape.reserveRpc) {
    throw new Error(
      `migration ${MIGRATION_FILE} is not installed. ` +
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

  // GoTrue answers 404/500 for the raw seed rows, so make them readable before
  // the first admin API call. No credential file exists yet at this point.
  await repairAuthRows(people);

  const pins = generateDemoPins(people);
  const existingPins = await readDemoAccessIds(people);
  const stateById = new Map(state.map((row) => [row.id, row]));
  const startedAt = new Date().toISOString();
  createCredentialFile(outFile, startedAt);

  const accounts = [];
  const failures = [];
  const warnings = [];

  for (const person of people) {
    const pin = pins.get(person.id);
    const status = stateById.get(person.id)?.account_status ?? 'active';
    const suspended = status === 'suspended';
    let entry = null;
    let persisted = false;
    try {
      // 1. Contact and descriptive metadata while the ban is still in place.
      // The ban is (re)asserted first so a previous partial run cannot leave
      // the account usable during provisioning.
      await adminBan(person);
      await adminUpdateUser(person);
      await markDemoFlags(person);
      const admin = await readAdminUser(person);
      if (!admin.banned) {
        await adminBan(person);
        throw new Error('account was not banned after the metadata update; re-banned');
      }
      if (!admin.appDemo) throw new Error('app_metadata demo flag is missing');
      if (String(admin.email ?? '').toLowerCase() !== person.targetEmail) {
        throw new Error('auth email was not updated to the synthetic address');
      }
      if (normalizePhone(admin.phone ?? '') !== person.phone) {
        throw new Error('auth phone was not updated to the assigned demo number');
      }

      // 2. Identity and mirrored profile contact.
      await repairEmailIdentity(person);
      await syncProfileEmail(person);
      await syncProfilePhone(person);

      // 3. PIN hash, then verification of the stored hash.
      await setDemoAccess(person, pin);
      const stored = await readDemoAccessIds([person]);
      const hash = stored.get(person.id);
      if (!hash || !verifyDemoPin(pin, hash)) {
        throw new Error('stored PIN hash did not verify after write');
      }

      // 4. Persist the plaintext PIN before the account becomes usable.
      entry = {
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
        account_status: status,
      };
      accounts.push(entry);
      persistCredentials(outFile, startedAt, accounts);
      persisted = true;

      // 5. Unban last. A suspended person stays banned and suspended.
      if (suspended) {
        console.log(
          `prepared   ${person.name}  ${toLocalPhone(person.phone)}  ` +
            'stays banned (suspended profile)',
        );
      } else {
        await adminUnban(person);
        console.log(
          `provisioned  ${person.name}  ${toLocalPhone(person.phone)}  ` +
            `${person.targetEmail} (synthetic)  ` +
            `PIN ${existingPins.has(person.id) ? 'rotated' : 'set'}`,
        );
      }

      if (verifyLogin) {
        if (suspended) {
          entry.login_verified = null;
        } else {
          const check = await verifyDemoLogin(person, pin);
          if (!check.ok) {
            // The PIN is already valid in the database; keep it in the file but
            // surface the deployment problem instead of throwing the PIN away.
            warnings.push({
              name: person.name,
              id: person.id,
              error: `demo-login verification failed: ${check.detail}`,
            });
            entry.login_verified = false;
            console.error(
              `WARNING ${person.name}: PIN set, but demo-login verification failed (${check.detail})`,
            );
          } else {
            entry.login_verified = true;
            console.log(`verified   ${person.name}  demo-login returned the expected user`);
          }
        }
        persistCredentials(outFile, startedAt, accounts);
      }
    } catch (e) {
      failures.push({ name: person.name, id: person.id, error: e.message });
      console.error(`FAILED  ${person.name}: ${e.message}`);
      if (entry && !persisted) {
        const index = accounts.indexOf(entry);
        if (index >= 0) accounts.splice(index, 1);
      }
      // A half-provisioned account must not be left usable.
      try {
        await adminBan(person);
      } catch (banError) {
        console.error(
          `WARNING ${person.name}: re-ban also failed (${banError.message}); ban it manually before any retry`,
        );
      }
    }
  }

  if (accounts.length) {
    console.log(`\nWrote ${accounts.length} phone/PIN record(s) to: ${outFile}`);
    console.log('Keep that file private. It is outside the repository by design.');
  } else {
    fs.rmSync(outFile, { force: true });
    console.error('\nNo account was provisioned, so no PIN file was kept.');
  }
  if (warnings.length) {
    console.error(
      `\n${warnings.length} account(s) were provisioned but failed demo-login verification.`,
    );
    process.exitCode = 1;
  }
  if (failures.length) {
    console.error(`\n${failures.length} account(s) failed and were re-banned.`);
    process.exitCode = 1;
  }
}

async function unlock(credentialsFile) {
  if (process.env[UNLOCK_ENV] !== UNLOCK_VALUE) {
    throw new Error(
      `refusing to change hosted lockouts. Set ${UNLOCK_ENV}=${UNLOCK_VALUE} and rerun with --unlock.`,
    );
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error(
      'SUPABASE_SERVICE_ROLE_KEY is required for --unlock. It is read from the environment only.',
    );
  }
  const shape = await readDatabaseShape();
  if (!shape.pinTable || !shape.unlockRpc) {
    throw new Error(
      `migration ${MIGRATION_FILE} is not installed. Nothing was changed.`,
    );
  }

  const accounts = readCredentialFile(credentialsFile);
  let failed = 0;
  for (const account of accounts) {
    const res = await fetch(
      `${PROJECT_URL}/rest/v1/rpc/demo_login_clear_lockout`,
      {
        method: 'POST',
        headers: serviceHeaders(),
        body: JSON.stringify({ p_user_id: account.userId }),
      },
    );
    if (!res.ok) {
      failed += 1;
      console.log(`FAIL     ${account.name}  (HTTP ${res.status})`);
      continue;
    }
    const cleared = await res.json().catch(() => null);
    console.log(`${cleared === true ? 'UNLOCKED' : 'NO LOCK '}  ${account.name}`);
  }
  console.log(
    `\n${accounts.length - failed} of ${accounts.length} lockout record(s) handled. ` +
      'Each PIN is unchanged.',
  );
  if (failed) process.exitCode = 1;
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
  if (argv.includes('--unlock')) {
    await unlock(unlockCredentialsPath(argv));
  } else if (!argv.includes('--apply')) {
    const state = await readHostedState(people);
    const emails = await readEmailConflicts(people);
    const phones = await readPhoneConflicts(people);
    const shape = await readDatabaseShape();
    const pinIds = shape.pinTable
      ? await readDemoAccessIds(people)
      : new Map();
    plan(people, state, { emails, phones }, shape, pinIds);
  } else {
    await apply(people, applyCredentialsPath(argv), argv.includes('--verify-login'));
  }
} catch (e) {
  console.error(`ABORT: ${e.message}`);
  process.exitCode = 1;
}
