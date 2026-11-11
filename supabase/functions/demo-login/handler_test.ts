import assert from 'node:assert/strict';
import test from 'node:test';

import { handleDemoLogin } from './handler.ts';
import { hashPin } from './pin.ts';

const CONFIG = {
  supabaseUrl: 'https://project.test',
  serviceRoleKey: 'service-role-key',
  publishableKey: 'sb_publishable_test',
};
const NOW = Date.parse('2026-11-11T00:00:00Z');
const USER_ID = '6e8dbe00-d9da-bfe0-71bc-0922bcaf5a79';
const EMAIL = 'nena.villareal@surgo-demo.test';
const SESSION = {
  access_token: 'access-token',
  refresh_token: 'refresh-token',
  token_type: 'bearer',
  expires_in: 3600,
  expires_at: Math.floor(NOW / 1000) + 3600,
  user: { id: USER_ID },
};

interface Call {
  url: string;
  body: string;
  headers: Headers;
}

type Route = (url: string) => Response | Promise<Response>;

function recorder(route: Route): { calls: Call[]; fetchImpl: typeof fetch } {
  const calls: Call[] = [];
  const fetchImpl = (async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === 'string'
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    calls.push({
      url,
      body: typeof init?.body === 'string' ? init.body : '',
      headers: new Headers(init?.headers),
    });
    return route(url);
  }) as typeof fetch;
  return { calls, fetchImpl };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function reserveRow(
  pin: string,
  overrides: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  return {
    user_id: USER_ID,
    email: EMAIL,
    pin_hash: await hashPin(pin, 100_000),
    failed_attempts: 1,
    locked_until: null,
    account_status: 'active',
    was_locked: false,
    ...overrides,
  };
}

function demoRoute(
  row: Record<string, unknown> | Record<string, unknown>[] | null,
  options: {
    linkStatus?: number;
    verifyStatus?: number;
    reserveStatus?: number;
  } = {},
): Route {
  return (url) => {
    if (url.endsWith('/rpc/demo_login_reserve_attempt')) {
      return json(
        row === null ? [] : Array.isArray(row) ? row : [row],
        options.reserveStatus ?? 200,
      );
    }
    if (url.endsWith('/rpc/demo_login_record_success')) {
      return new Response(null, { status: 204 });
    }
    if (url.endsWith('/auth/v1/admin/generate_link')) {
      return options.linkStatus
        ? json({ error: 'failed' }, options.linkStatus)
        : json({ properties: { hashed_token: 'hash-1' } });
    }
    if (url.endsWith('/auth/v1/verify')) {
      return options.verifyStatus
        ? json({ error: 'failed' }, options.verifyStatus)
        : json(SESSION);
    }
    return json({ error: 'unexpected' }, 500);
  };
}

function post(body: unknown): Request {
  return new Request('https://function.test/demo-login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

const bodyOf = (calls: Call[], suffix: string): Record<string, unknown> => {
  const call = calls.find((c) => c.url.endsWith(suffix));
  assert.ok(call, `expected a call to ${suffix}`);
  return JSON.parse(call.body);
};

const headerOf = (calls: Call[], suffix: string, name: string): string | null => {
  const call = calls.find((c) => c.url.endsWith(suffix));
  assert.ok(call, `expected a call to ${suffix}`);
  return call.headers.get(name);
};

test('a verified PIN mints and returns a Supabase session', async () => {
  const row = await reserveRow('246810');
  const { calls, fetchImpl } = recorder(demoRoute(row));

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const body = await response.json();
  assert.equal(body.session.access_token, 'access-token');
  assert.equal(body.session.refresh_token, 'refresh-token');

  assert.deepEqual(bodyOf(calls, '/rpc/demo_login_reserve_attempt'), {
    p_phone: '+639170000007',
  });
  assert.deepEqual(bodyOf(calls, '/rpc/demo_login_record_success'), {
    p_user_id: USER_ID,
  });
  assert.deepEqual(bodyOf(calls, '/auth/v1/admin/generate_link'), {
    type: 'magiclink',
    email: EMAIL,
  });
  assert.deepEqual(bodyOf(calls, '/auth/v1/verify'), {
    type: 'magiclink',
    token_hash: 'hash-1',
  });
  // Admin operations sign with the service key; the exchange does not.
  assert.equal(
    headerOf(calls, '/auth/v1/admin/generate_link', 'apikey'),
    CONFIG.serviceRoleKey,
  );
  assert.equal(
    headerOf(calls, '/auth/v1/verify', 'apikey'),
    CONFIG.publishableKey,
  );
  assert.notEqual(
    headerOf(calls, '/auth/v1/verify', 'apikey'),
    CONFIG.serviceRoleKey,
  );
});

test('accepts the +639 form and normalizes before reservation', async () => {
  const row = await reserveRow('246810');
  const { calls, fetchImpl } = recorder(demoRoute(row));

  const response = await handleDemoLogin(
    post({ phone: '+63 917 000 0007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 200);
  assert.deepEqual(bodyOf(calls, '/rpc/demo_login_reserve_attempt'), {
    p_phone: '+639170000007',
  });
});

test('a wrong PIN is a generic 401 after the attempt was reserved', async () => {
  const row = await reserveRow('246810');
  const { calls, fetchImpl } = recorder(demoRoute(row));

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '111111' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 401);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(await response.json(), { error: 'invalid_credentials' });
  // The reservation itself consumed the attempt, so no counter write follows.
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/demo_login_reserve_attempt')));
  assert.ok(!calls.some((c) => c.url.endsWith('/rpc/demo_login_record_success')));
  assert.ok(!calls.some((c) => c.url.endsWith('/auth/v1/admin/generate_link')));
});

test('an unknown phone is a generic 401 with no session work', async () => {
  const { calls, fetchImpl } = recorder(demoRoute(null));

  const response = await handleDemoLogin(
    post({ phone: '09170000099', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'invalid_credentials' });
  assert.ok(!calls.some((c) => c.url.endsWith('/rpc/demo_login_record_success')));
  assert.ok(!calls.some((c) => c.url.endsWith('/auth/v1/admin/generate_link')));
});

test('a live lock is refused without checking the PIN', async () => {
  const row = await reserveRow('246810', {
    failed_attempts: 5,
    locked_until: new Date(NOW + 90_000).toISOString(),
    was_locked: true,
  });
  const { calls, fetchImpl } = recorder(demoRoute(row));

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 429);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(await response.json(), {
    error: 'locked',
    retry_after_seconds: 90,
  });
  assert.ok(!calls.some((c) => c.url.endsWith('/rpc/demo_login_record_success')));
  assert.ok(!calls.some((c) => c.url.endsWith('/generate_link')));
});

test('the reservation that sets the lock still verifies its own PIN', async () => {
  const row = await reserveRow('246810', {
    failed_attempts: 5,
    locked_until: new Date(NOW + 15 * 60_000).toISOString(),
    was_locked: false,
  });
  const { fetchImpl } = recorder(demoRoute(row));

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 200);
});

test('a suspended account with the right PIN is refused generically', async () => {
  const row = await reserveRow('246810', { account_status: 'suspended' });
  const { calls, fetchImpl } = recorder(demoRoute(row));

  const response = await handleDemoLogin(
    post({ phone: '09170000011', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: 'account_unavailable' });
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/demo_login_record_success')));
  assert.ok(!calls.some((c) => c.url.endsWith('/generate_link')));
});

test('a failed reservation returns 502 without touching the session', async () => {
  const row = await reserveRow('246810');
  const { calls, fetchImpl } = recorder(
    demoRoute(row, { reserveStatus: 500 }),
  );

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'login_unavailable' });
  assert.ok(!calls.some((c) => c.url.endsWith('/generate_link')));
});

test('a failed session mint returns 502 without leaking details', async () => {
  const row = await reserveRow('246810');
  const { fetchImpl } = recorder(demoRoute(row, { linkStatus: 500 }));

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'login_unavailable' });
});

test('a failed token exchange returns 502', async () => {
  const row = await reserveRow('246810');
  const { fetchImpl } = recorder(demoRoute(row, { verifyStatus: 400 }));

  const response = await handleDemoLogin(
    post({ phone: '09170000007', pin: '246810' }),
    { ...CONFIG, fetchImpl, now: () => NOW },
  );

  assert.equal(response.status, 502);
});

test('malformed requests are rejected before any reservation', async () => {
  for (const body of [
    { phone: '09170000007', pin: '12ab' },
    { phone: '09170000007', pin: 246810 },
    { phone: '12345', pin: '246810' },
    { pin: '246810' },
    {},
  ]) {
    const { calls, fetchImpl } = recorder(demoRoute(null));
    const response = await handleDemoLogin(post(body), {
      ...CONFIG,
      fetchImpl,
      now: () => NOW,
    });
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.equal(calls.length, 0, JSON.stringify(body));
  }
});

test('the method contract and CORS preflight are handled', async () => {
  const { fetchImpl } = recorder(demoRoute(null));

  const options = await handleDemoLogin(
    new Request('https://function.test/demo-login', { method: 'OPTIONS' }),
    { ...CONFIG, fetchImpl },
  );
  assert.equal(options.status, 204);
  assert.equal(options.headers.get('Cache-Control'), 'no-store');
  assert.equal(options.headers.get('Access-Control-Allow-Origin'), '*');
  assert.match(
    options.headers.get('Access-Control-Allow-Headers') ?? '',
    /authorization/,
  );

  const get = await handleDemoLogin(
    new Request('https://function.test/demo-login', { method: 'GET' }),
    { ...CONFIG, fetchImpl },
  );
  assert.equal(get.status, 405);
});

test('a missing server configuration fails closed', async () => {
  const bodies = [
    { supabaseUrl: '', serviceRoleKey: '', publishableKey: '' },
    { ...CONFIG, serviceRoleKey: '' },
    { ...CONFIG, publishableKey: '' },
  ];
  for (const config of bodies) {
    const response = await handleDemoLogin(
      post({ phone: '09170000007', pin: '246810' }),
      config,
    );
    assert.equal(response.status, 500, JSON.stringify(config));
  }
});
