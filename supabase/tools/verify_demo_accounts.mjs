// Verifies every provisioned demo account against the live project.
//
// Sign-in goes through the demo-login Edge Function with the account's
// Philippine phone number and PIN. For active accounts the tool then performs
// PostgREST reads as that account to prove the row-level policies keep its
// personal data private. Suspended accounts (Junel Ramos) must refuse even the
// correct PIN and must stay suspended.
//
// This tool changes no demo data: it signs in, reads rows, and logs out. The
// single wrong-PIN probe exercises the lockout counter, and the following
// correct sign-in clears it. It never prints a PIN or an access token, and
// needs no service-role key.
//
//   node supabase/tools/verify_demo_accounts.mjs \
//     --credentials "$USERPROFILE/surgo-demo-credentials/demo-pins-<stamp>.json"
//
// Run it only after the approved provisioning pass. The PIN file is the one
// provision_demo_accounts.mjs wrote outside the repository.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { REF } from './db_admin.mjs';
import {
  SYNTHETIC_DOMAIN,
  UUID,
  isInsideRepo,
  isSyncedFolder,
  normalizePhone,
  toLocalPhone,
} from './demo_provision_plan.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');

const PROJECT_URL = `https://${REF}.supabase.co`;
const PUBLISHABLE_KEY =
  process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_WszPDYOAKw3dYZ1QAElSXA_mpW1rckw';

const OPEN_RIDE_STATUSES = new Set(['searching', 'awaiting_acceptance']);
const RIDER_CAPABLE = new Set(['rider']);

function credentialsPath(argv) {
  const flag = argv.indexOf('--credentials');
  const explicit = flag >= 0 ? argv[flag + 1] : process.env.SURGO_DEMO_CREDENTIALS_FILE;
  if (!explicit) {
    throw new Error(
      'Pass --credentials <file> (the PIN file provision_demo_accounts.mjs wrote outside the repo).',
    );
  }
  const resolved = path.resolve(explicit);
  if (isInsideRepo(repoRoot, resolved)) {
    throw new Error(`refusing to read credentials from inside the repository: ${resolved}`);
  }
  if (isSyncedFolder(resolved)) {
    throw new Error(`refusing to read plaintext PINs from a synced folder: ${resolved}`);
  }
  return resolved;
}

async function demoLogin(phone, pin) {
  const res = await fetch(`${PROJECT_URL}/functions/v1/demo-login`, {
    method: 'POST',
    headers: { apikey: PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ phone, pin }),
  });
  const body = await res.json().catch(() => ({}));
  return { status: res.status, error: body?.error, session: body?.session };
}

async function signIn(phone, pin) {
  const result = await demoLogin(phone, pin);
  if (result.status !== 200) {
    throw new Error(
      `demo-login HTTP ${result.status}${result.error ? ` (${result.error})` : ''}`,
    );
  }
  const session = result.session;
  if (!session?.access_token || !session.user?.id) {
    throw new Error('demo-login returned no session');
  }
  return session;
}

async function signOut(token) {
  await fetch(`${PROJECT_URL}/auth/v1/logout`, {
    method: 'POST',
    headers: { apikey: PUBLISHABLE_KEY, Authorization: `Bearer ${token}` },
  }).catch(() => {});
}

async function rows(token, table, query = 'select=id') {
  const res = await fetch(
    `${PROJECT_URL}/rest/v1/${table}?${query}`,
    {
      headers: {
        apikey: PUBLISHABLE_KEY,
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
      },
    },
  );
  if (res.status === 401 || res.status === 403) return { forbidden: true, rows: [] };
  if (!res.ok) throw new Error(`${table}: HTTP ${res.status} ${(await res.text()).slice(0, 120)}`);
  return { forbidden: false, rows: await res.json() };
}

async function rpc(token, name, args = {}) {
  const res = await fetch(`${PROJECT_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: PUBLISHABLE_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (res.status === 401 || res.status === 403) return { forbidden: true };
  if (!res.ok) return { forbidden: true, status: res.status, detail: (await res.text()).slice(0, 120) };
  const body = await res.json().catch(() => null);
  return { forbidden: false, value: body };
}

const approvedOf = (roleLabels) =>
  new Set(roleLabels.map((r) => String(r).toLowerCase()));
const isRiderCapable = (roles) => [...roles].some((r) => RIDER_CAPABLE.has(r));
const isEarnerCapable = (roles) => roles.has('earner') || roles.has('rider');

function credentialFields(account, index = 0) {
  const label = `PIN row ${index + 1}`;
  if (typeof account?.user_id !== 'string' || !UUID.test(account.user_id)) {
    throw new Error(`${label} has a malformed user id`);
  }
  const e164 = normalizePhone(account.phone_e164 ?? account.phone ?? account.phone_local);
  if (!e164) throw new Error(`${label} has an invalid phone number`);
  if (
    typeof account.email !== 'string' ||
    !account.email.toLowerCase().endsWith(`@${SYNTHETIC_DOMAIN}`)
  ) {
    throw new Error(`${label} does not use a reserved @${SYNTHETIC_DOMAIN} email`);
  }
  if (!/^\d{6}$/.test(account.pin ?? '')) {
    throw new Error(`${label} has no six-digit PIN`);
  }
  const local = toLocalPhone(e164);
  return {
    name: account.name ?? e164,
    user_id: account.user_id,
    email: account.email,
    phone: e164,
    phoneLocal: account.phone_local ?? local,
    pin: account.pin,
    roleLabels: account.role_labels ?? [],
    expectedStatus: account.account_status ?? 'active',
  };
}

async function verifySuspended(account) {
  const failures = [];
  const warnings = [];

  // A wrong PIN must still be a generic 401; the correct PIN must reach the
  // suspension refusal. Together they prove the PIN is valid and the status,
  // not the credentials, is what blocks sign-in.
  const wrong = await demoLogin(
    account.phone,
    account.pin === '000000' ? '000001' : '000000',
  );
  if (wrong.status !== 401) {
    failures.push(
      `wrong PIN on a suspended account returned ${wrong.status}, expected 401`,
    );
  }

  for (const phone of [account.phone, account.phoneLocal]) {
    const result = await demoLogin(phone, account.pin);
    if (result.status !== 403 || result.error !== 'account_unavailable') {
      failures.push(
        `${phone} returned ${result.status}${result.error ? ` (${result.error})` : ''}, ` +
          'expected the suspended-account refusal',
      );
    }
  }

  return { failures, warnings, suspended: true };
}

async function verifyAccount(account, all, options = {}) {
  const failures = [];
  const warnings = [];
  const fail = (message) => failures.push(message);
  const warn = (message) => warnings.push(message);

  if (!account.phone || !account.email || !account.user_id) {
    return { failures: ['credentials row is missing phone, email or user_id'], warnings };
  }
  if (!/^\d{6}$/.test(account.pin ?? '')) {
    return { failures: ['credentials row has no six-digit PIN'], warnings };
  }
  if (account.expectedStatus === 'suspended') {
    return verifySuspended(account);
  }

  if (options.testWrongPin) {
    // Never probe with the account's own PIN; the generator avoids trivial
    // values, but this keeps the assertion correct for any credentials file.
    const wrongPin = account.pin === '000000' ? '000001' : '000000';
    const wrong = await demoLogin(account.phone, wrongPin);
    if (wrong.status !== 401) {
      fail(`wrong PIN returned ${wrong.status}, expected 401`);
    }
    if (wrong.error !== 'invalid_credentials') {
      fail(`wrong PIN error was "${wrong.error}", expected a generic credential error`);
    }
  }

  let session;
  try {
    session = await signIn(account.phone, account.pin);
  } catch (error) {
    return { failures: [`sign-in failed: ${error.message}`], warnings };
  }

  let token = session.access_token;
  try {
    if (session.user.id !== account.user_id) {
      fail(`signed in as ${session.user.id}, expected ${account.user_id}`);
    }
    if (session.user.email?.toLowerCase() !== account.email.toLowerCase()) {
      fail('session email does not match the credentials row');
    }
    // GoTrue returns the session phone without the leading "+"; compare the
    // subscriber number, not the spelling.
    if (normalizePhone(session.user.phone) !== account.phone) {
      fail(`session phone is ${session.user.phone ?? '(none)'}, expected ${account.phone}`);
    }
    if (session.user.user_metadata?.surgo_onboarded !== true) {
      fail('surgo_onboarded metadata is missing; the app would send this account to onboarding');
    }
    // surgo_demo is trusted only in app_metadata, which the account holder
    // cannot write. A user_metadata copy is stale output from an older build.
    if (session.user.app_metadata?.surgo_demo !== true) {
      fail('app_metadata.surgo_demo is missing; the client cannot recognize this demo account');
    }
    if (session.user.user_metadata?.surgo_demo != null) {
      warn('user_metadata.surgo_demo is still present; the demo flag should live only in app_metadata');
    }

    const me = await rows(
      token, 'profiles', `select=id,full_name,email,phone,account_status&id=eq.${account.user_id}`,
    );
    if (me.rows.length !== 1) {
      fail(`own profile not readable (rows: ${me.rows.length})`);
    } else {
      const profile = me.rows[0];
      if (profile.id !== account.user_id) fail('own profile id does not match the auth user id');
      if (String(profile.email ?? '').toLowerCase() !== account.email.toLowerCase()) {
        fail(`profile email is ${profile.email ?? '(none)'}, expected ${account.email}`);
      }
      if (normalizePhone(profile.phone) !== account.phone) {
        fail(`profile phone is ${profile.phone ?? '(none)'}, expected ${account.phone}`);
      }
      if (profile.full_name !== account.name) {
        warn(`profile name "${profile.full_name}" differs from "${account.name}"`);
      }
      if (profile.account_status !== 'active') {
        warn(`profile account_status is ${profile.account_status}`);
      }
    }

    const myRoles = await rows(
      token, 'user_roles', `select=role,status&profile_id=eq.${account.user_id}&status=eq.approved`,
    );
    const roles = approvedOf((myRoles.rows ?? []).map((r) => r.role));
    const expected = approvedOf(account.roleLabels);
    if ([...expected].some((r) => !roles.has(r))) {
      warn(
        `approved roles changed since provisioning (expected: ${[...expected].join(', ') || 'none'}; ` +
          `now: ${[...roles].join(', ') || 'none'})`,
      );
    }
    if (roles.has('admin')) fail('demo account unexpectedly has the admin role');

    // Another demo person's private rows must never be readable. Profiles,
    // roles, wallets, notifications and device tokens are own-only policies.
    const other = all.find((a) => a.user_id !== account.user_id);
    if (other) {
      const otherProfile = await rows(token, 'profiles', `select=id&id=eq.${other.user_id}`);
      if (otherProfile.rows.length) fail(`can read another demo profile (${other.name})`);
      const otherRoles = await rows(token, 'user_roles', `select=role&profile_id=eq.${other.user_id}`);
      if (otherRoles.rows.length) fail(`can read another demo account's roles (${other.name})`);
      const otherWallets = await rows(token, 'wallet_accounts', `select=profile_id&profile_id=eq.${other.user_id}`);
      if (otherWallets.rows.length) fail(`can read another demo wallet (${other.name})`);
      const otherNotifications = await rows(token, 'notifications', `select=profile_id&profile_id=eq.${other.user_id}`);
      if (otherNotifications.rows.length) fail(`can read another demo account's notifications (${other.name})`);
      const otherDevices = await rows(token, 'device_tokens', `select=profile_id&profile_id=eq.${other.user_id}`);
      if (otherDevices.rows.length) fail(`can read another demo account's device tokens (${other.name})`);
    }

    const wallets = await rows(token, 'wallet_accounts', 'select=id,profile_id');
    if (wallets.rows.some((w) => w.profile_id !== account.user_id)) {
      fail('wallet read returned an account owned by someone else');
    }
    const walletIds = new Set(wallets.rows.map((w) => w.id));
    const walletTx = await rows(token, 'wallet_transactions', 'select=wallet_account_id');
    if (walletTx.rows.some((t) => !walletIds.has(t.wallet_account_id))) {
      fail('wallet transaction read returned a wallet owned by someone else');
    }

    const notes = await rows(token, 'notifications', 'select=profile_id');
    if (notes.rows.some((n) => n.profile_id !== account.user_id)) {
      fail('notification read returned another account\'s row');
    }
    const devices = await rows(token, 'device_tokens', 'select=profile_id');
    if (devices.rows.some((d) => d.profile_id !== account.user_id)) {
      fail('device token read returned another account\'s row');
    }

    // Listed vehicles are public; only non-active rows are owner-private.
    const vehicles = await rows(token, 'vehicles', 'select=id,owner_profile_id,status');
    if (vehicles.rows.some((v) => v.status !== 'active' && v.owner_profile_id !== account.user_id)) {
      fail('vehicle read returned a non-active vehicle owned by someone else');
    }
    const ownVehicleIds = new Set(
      vehicles.rows.filter((v) => v.owner_profile_id === account.user_id).map((v) => v.id),
    );
    const docs = await rows(token, 'vehicle_documents', 'select=vehicle_id');
    if (docs.rows.some((d) => !ownVehicleIds.has(d.vehicle_id))) {
      fail('vehicle document read returned a document for another owner');
    }

    const rides = await rows(
      token, 'ride_requests', 'select=id,passenger_id,rider_id,status',
    );
    for (const ride of rides.rows) {
      const participant = ride.passenger_id === account.user_id || ride.rider_id === account.user_id;
      const sharedOpen = OPEN_RIDE_STATUSES.has(ride.status) && isRiderCapable(roles);
      if (!participant && !sharedOpen) {
        fail(`ride ${ride.id} (${ride.status}) is visible without participation`);
        break;
      }
    }

    const rentals = await rows(token, 'rental_bookings', 'select=id,renter_id,owner_id');
    if (rentals.rows.some(
      (b) => b.renter_id !== account.user_id && b.owner_id !== account.user_id,
    )) {
      fail('rental read returned a booking without participation');
    }

    const errands = await rows(
      token, 'service_requests', 'select=id,customer_id,provider_id,status',
    );
    for (const request of errands.rows) {
      const participant =
        request.customer_id === account.user_id || request.provider_id === account.user_id;
      const sharedAvailable = request.status === 'available' && isEarnerCapable(roles);
      if (!participant && !sharedAvailable) {
        fail(`service request ${request.id} (${request.status}) is visible without participation`);
        break;
      }
    }

    const transactions = await rows(
      token, 'service_transactions', 'select=customer_id,provider_id',
    );
    if (transactions.rows.some(
      (t) => t.customer_id !== account.user_id && t.provider_id !== account.user_id,
    )) {
      fail('service transaction read returned a payment without participation');
    }

    const meAdmin = await rpc(token, 'is_admin');
    if (meAdmin.forbidden === false && meAdmin.value === true) {
      fail('is_admin() returned true for a demo account');
    }
    const audit = await rows(token, 'admin_audit_logs', 'select=id&limit=1');
    if (!audit.forbidden && audit.rows.length) {
      fail('admin audit log is readable by a demo account');
    }
    const overview = await rpc(token, 'admin_overview');
    if (!overview.forbidden) fail('admin_overview() is callable by a demo account');

    await signOut(token);
    token = null;

    // The 09XXXXXXXXX form must normalize to the same account.
    let again;
    try {
      again = await signIn(account.phoneLocal, account.pin);
    } catch (error) {
      fail(`09-form sign-in failed: ${error.message}`);
      return { failures, warnings, roles: [...roles].sort() };
    }
    if (again.user.id !== account.user_id) {
      fail('the 09-form sign-in resolved a different auth user');
    }
    await signOut(again.access_token);

    return { failures, warnings, roles: [...roles].sort() };
  } catch (error) {
    return { failures: [error.message], warnings };
  } finally {
    if (token) await signOut(token);
  }
}

const argv = process.argv.slice(2);

try {
  const file = credentialsPath(argv);
  const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
  const rawAccounts = payload.accounts;
  if (!Array.isArray(rawAccounts) || rawAccounts.length !== 19) {
    throw new Error(`expected 19 PIN rows, found ${rawAccounts?.length ?? 0}`);
  }

  const accounts = rawAccounts.map((row, index) => credentialFields(row, index));
  if (new Set(accounts.map((a) => a.user_id)).size !== accounts.length) {
    throw new Error('PIN file contains duplicate user ids');
  }
  if (new Set(accounts.map((a) => a.phone)).size !== accounts.length) {
    throw new Error('PIN file contains duplicate phone numbers');
  }

  console.log(`Verifying ${accounts.length} demo accounts (read-only)…\n`);
  let failed = 0;
  let wrongPinTested = false;
  // GoTrue rate-limits session verification per IP. A full run makes three
  // requests for the first account and two for each of the rest, so pacing
  // keeps a 19-account check under the limit without skipping any assertion.
  const paceMs = Number(process.env.SURGO_VERIFY_PACE_MS ?? 0);
  let firstAccount = true;
  for (const account of accounts) {
    if (paceMs > 0 && !firstAccount) {
      await new Promise((resolve) => setTimeout(resolve, paceMs));
    }
    firstAccount = false;
    const result = await verifyAccount(account, accounts, {
      testWrongPin: !wrongPinTested,
    });
    // The probe only runs on an active account; suspended accounts use their
    // own wrong-PIN check inside verifySuspended.
    if (!result.suspended) wrongPinTested = true;
    if (result.failures.length) {
      failed += 1;
      console.log(`FAIL  ${account.name}`);
      for (const failure of result.failures) console.log(`        ${failure}`);
    } else if (result.suspended) {
      console.log(`PASS  ${account.name}  (${account.phoneLocal})  suspended: correct PIN refused`);
    } else {
      console.log(
        `PASS  ${account.name}  (${account.phoneLocal})  ` +
          `roles: ${result.roles.join(', ') || '(none)'}  both phone forms`,
      );
    }
    for (const warning of result.warnings) console.log(`        note: ${warning}`);
  }

  console.log(
    failed
      ? `\n${failed} of ${accounts.length} accounts failed verification.`
      : `\nAll ${accounts.length} accounts passed verification.`,
  );
  if (failed) process.exitCode = 1;
} catch (error) {
  console.error(`ABORT: ${error.message}`);
  process.exitCode = 1;
}
