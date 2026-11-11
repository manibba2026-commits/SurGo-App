// Supabase Edge Function: demo-account sign-in by PH mobile + PIN.
//
// Flow: normalize the phone → atomically reserve one PIN attempt with the
// service role → verify the PIN with PBKDF2 → mint a real Supabase session
// through an admin magic-link that is verified server-side.
//
// The reservation RPC is the lockout gate: it consumes the attempt before the
// PIN is checked, so parallel requests cannot exceed five verifications per
// 15-minute window. A request that arrives while the account is already locked
// reports was_locked and is refused without consuming or extending an attempt.
//
// No email or SMS is sent. No password exists. The service key, PIN hash and
// session stay on the server; the client receives only the session it owns.

import { normalizePhilippineNumber } from './phone.ts';
import { DUMMY_PIN_HASH, verifyPin } from './pin.ts';

export interface DemoLoginConfig {
  supabaseUrl: string;
  serviceRoleKey: string;
  /** Publishable (anon) key. Only the token exchange needs it. */
  publishableKey: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

interface ReserveRow {
  user_id: string;
  email: string | null;
  pin_hash: string;
  failed_attempts: number;
  locked_until: string | null;
  account_status: string;
  was_locked: boolean;
}

const MAX_BODY_BYTES = 4 * 1024;
const LOCKOUT_RETRY_FLOOR_SECONDS = 1;

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers':
    'authorization, apikey, content-type, x-client-info',
};

// Authentication responses carry a session; no intermediary may cache one.
const NO_STORE = { 'Cache-Control': 'no-store' };

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...NO_STORE,
      ...CORS_HEADERS,
    },
  });
}

function serviceHeaders(key: string): Record<string, string> {
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  };
}

async function callRpc(
  fetchImpl: typeof fetch,
  config: DemoLoginConfig,
  name: string,
  args: Record<string, unknown>,
): Promise<Response> {
  return fetchImpl(`${config.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: serviceHeaders(config.serviceRoleKey),
    body: JSON.stringify(args),
  });
}

async function mintSession(
  fetchImpl: typeof fetch,
  config: DemoLoginConfig,
  email: string,
): Promise<{ ok: true; session: unknown } | { ok: false }> {
  const linkResponse = await fetchImpl(
    `${config.supabaseUrl}/auth/v1/admin/generate_link`,
    {
      method: 'POST',
      headers: serviceHeaders(config.serviceRoleKey),
      body: JSON.stringify({ type: 'magiclink', email }),
    },
  );
  if (!linkResponse.ok) return { ok: false };

  const link = await linkResponse.json().catch(() => null) as
    | { properties?: { hashed_token?: unknown }; hashed_token?: unknown }
    | null;
  const tokenHash = link?.properties?.hashed_token ?? link?.hashed_token;
  if (typeof tokenHash !== 'string' || tokenHash.length === 0) {
    return { ok: false };
  }

  // The token exchange is a normal client operation, so it uses the
  // publishable key rather than the service key.
  const verifyResponse = await fetchImpl(`${config.supabaseUrl}/auth/v1/verify`, {
    method: 'POST',
    headers: {
      apikey: config.publishableKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ type: 'magiclink', token_hash: tokenHash }),
  });
  if (!verifyResponse.ok) return { ok: false };

  const session = await verifyResponse.json().catch(() => null) as
    | { access_token?: unknown; refresh_token?: unknown }
    | null;
  if (
    typeof session?.access_token !== 'string' ||
    typeof session.refresh_token !== 'string'
  ) {
    return { ok: false };
  }
  return { ok: true, session };
}

/**
 * Handles one demo sign-in. Errors are deliberately generic: the response
 * never says whether a phone exists, only that the credentials did not match.
 */
export async function handleDemoLogin(
  request: Request,
  config: DemoLoginConfig,
): Promise<Response> {
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: { ...NO_STORE, ...CORS_HEADERS },
    });
  }
  if (request.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }
  if (!config.supabaseUrl || !config.serviceRoleKey || !config.publishableKey) {
    return json({ error: 'not_configured' }, 500);
  }

  const raw = await request.text();
  if (!raw) return json({ error: 'invalid_request' }, 400);
  if (raw.length > MAX_BODY_BYTES) {
    return json({ error: 'invalid_request' }, 413);
  }

  let body: { phone?: unknown; pin?: unknown };
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'invalid_request' }, 400);
  }

  const phone = normalizePhilippineNumber(body.phone);
  const pin = body.pin;
  if (!phone || typeof pin !== 'string' || !/^\d{6}$/.test(pin)) {
    return json({ error: 'invalid_request' }, 400);
  }

  const fetchImpl = config.fetchImpl ?? fetch;
  const nowMs = (config.now ?? Date.now)();

  let reserveResponse: Response;
  try {
    reserveResponse = await callRpc(
      fetchImpl,
      config,
      'demo_login_reserve_attempt',
      { p_phone: phone },
    );
  } catch {
    console.error('demo-login: reservation request failed');
    return json({ error: 'login_unavailable' }, 502);
  }
  if (!reserveResponse.ok) {
    console.error('demo-login: reservation rejected', {
      status: reserveResponse.status,
    });
    return json({ error: 'login_unavailable' }, 502);
  }

  const rows = await reserveResponse.json().catch(() => null);
  const row: ReserveRow | undefined = Array.isArray(rows) ? rows[0] : undefined;

  if (!row) {
    // Burn comparable time so an unknown phone is not faster than a wrong PIN.
    await verifyPin(pin, DUMMY_PIN_HASH).catch(() => false);
    return json({ error: 'invalid_credentials' }, 401);
  }

  // Only a lock that already existed before this request refuses early. The
  // reservation that sets the lock still lets its own PIN be verified.
  if (row.was_locked) {
    const lockedUntil = row.locked_until ? Date.parse(row.locked_until) : NaN;
    const retry = Number.isFinite(lockedUntil)
      ? Math.max(
        LOCKOUT_RETRY_FLOOR_SECONDS,
        Math.ceil((lockedUntil - nowMs) / 1000),
      )
      : LOCKOUT_RETRY_FLOOR_SECONDS;
    return json({ error: 'locked', retry_after_seconds: retry }, 429);
  }

  // The attempt is already recorded; verification only decides the response.
  const verified = await verifyPin(pin, row.pin_hash).catch(() => false);
  if (!verified) {
    return json({ error: 'invalid_credentials' }, 401);
  }

  // A correct PIN clears the counter even for a suspended account; the status
  // itself is never modified here.
  try {
    await callRpc(fetchImpl, config, 'demo_login_record_success', {
      p_user_id: row.user_id,
    });
  } catch {
    console.error('demo-login: success counter update failed');
  }

  if (row.account_status !== 'active') {
    return json({ error: 'account_unavailable' }, 403);
  }
  if (!row.email) {
    console.error('demo-login: demo account has no email for session mint');
    return json({ error: 'login_unavailable' }, 502);
  }

  let minted: { ok: true; session: unknown } | { ok: false };
  try {
    minted = await mintSession(fetchImpl, config, row.email);
  } catch {
    minted = { ok: false };
  }
  if (!minted.ok) {
    console.error('demo-login: session mint failed');
    return json({ error: 'login_unavailable' }, 502);
  }

  return json({ session: minted.session }, 200);
}
