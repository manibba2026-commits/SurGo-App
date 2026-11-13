import assert from 'node:assert/strict';
import test from 'node:test';
import { setImmediate } from 'node:timers/promises';

import { createGeoapifyHandler, verifySupabaseUser, type GeoapifyHandlerConfig } from './handler.ts';

const API_KEY = 'geo_test_server_secret';
const TOKEN = 'signed.jwt.token';
const CENTER = { latitude: 9.0785, longitude: 126.1985 };
const END = { latitude: 9.1, longitude: 126.2 };
const AUTOCOMPLETE = { action: 'autocomplete', text: 'Tandag' };
const PLACES = { action: 'places', categories: ['healthcare.pharmacy'], center: CENTER, radius: 5000 };
const ROUTE = { action: 'route', start: CENTER, end: END, mode: 'drive' };
const REVERSE = { action: 'reverse', point: CENTER };

interface FetchCall {
  url: string;
  init: RequestInit;
}

function jsonResponse(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

function collection(features: unknown[] = []): Record<string, unknown> {
  return { type: 'FeatureCollection', features };
}

function place(properties: Record<string, unknown> = {}, coordinates: unknown = [126.1985, 9.0785]): Record<string, unknown> {
  return {
    type: 'Feature', geometry: { type: 'Point', coordinates },
    properties: { place_id: 'place_1', formatted: 'Tandag, Philippines', ...properties },
  };
}

function routeFeature(
  properties: Record<string, unknown> = {},
  geometry: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    type: 'Feature',
    properties: { distance: 1200.5, time: 180.25, ...properties },
    geometry: {
      type: 'MultiLineString',
      coordinates: [
        [[126.1985, 9.0785], [126.199, 9.08]],
        [[126.199, 9.08], [126.2, 9.1]],
      ],
      ...geometry,
    },
  };
}

function rawRequest(body: string, headers: HeadersInit = {}): Request {
  return new Request('https://local.test/functions/v1/geoapify', {
    method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json', ...headers }, body,
  });
}

function request(body: unknown = AUTOCOMPLETE, token = TOKEN): Request {
  return rawRequest(JSON.stringify(body), { Authorization: `Bearer ${token}` });
}

function setup(
  overrides: Partial<GeoapifyHandlerConfig> = {},
  response: () => Response = () => jsonResponse(collection([place()])),
) {
  const calls: FetchCall[] = [];
  const authCalls: { token: string; signal: AbortSignal }[] = [];
  const handler = createGeoapifyHandler({
    apiKey: API_KEY,
    authenticate: async (token, signal) => { authCalls.push({ token, signal }); return 'user_1'; },
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), init: init ?? {} });
      return response();
    }) as typeof fetch,
    ...overrides,
  });
  return { handler, calls, authCalls };
}

function assertCors(response: Response): void {
  assert.equal(response.headers.get('access-control-allow-origin'), '*');
  assert.equal(response.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  assert.equal(response.headers.get('access-control-allow-headers'), 'authorization, x-client-info, apikey, content-type');
  assert.equal(response.headers.get('access-control-expose-headers'), 'Retry-After');
}

test('OPTIONS works without configuration or authentication and makes no network call', async () => {
  const { handler, calls, authCalls } = setup({ apiKey: '' });
  const response = await handler(new Request('https://local.test/geoapify', { method: 'OPTIONS' }));
  assert.equal(response.status, 204);
  assert.equal(await response.text(), '');
  assertCors(response);
  assert.equal(calls.length, 0);
  assert.equal(authCalls.length, 0);
});

test('non-POST methods are denied before authentication/provider, with CORS and Allow', async () => {
  const { handler, calls, authCalls } = setup();
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE', 'HEAD']) {
    const response = await handler(new Request('https://local.test/geoapify', { method }));
    assert.equal(response.status, 405, method);
    assert.equal(response.headers.get('allow'), 'POST, OPTIONS');
    assertCors(response);
  }
  assert.equal(calls.length, 0);
  assert.equal(authCalls.length, 0);
});

test('autocomplete maps the fixed Tandag rectangle and proximity bias, normalizing only public fields', async () => {
  const { handler, calls, authCalls } = setup({}, () => jsonResponse(collection([
    place({ apiKey: API_KEY, internal: 'private', lat: 0, lon: 0 }),
  ])));
  const response = await handler(request({ ...AUTOCOMPLETE, text: '  Tandag & market  ', limit: 2 }));
  assert.equal(response.status, 200);
  assertCors(response);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { places: [
    { id: 'place_1', label: 'Tandag, Philippines', latitude: 9.0785, longitude: 126.1985 },
  ] });
  assert.equal(authCalls[0].token, TOKEN);
  assert.equal(calls.length, 1);
  const url = new URL(calls[0].url);
  assert.equal(url.origin + url.pathname, 'https://api.geoapify.com/v1/geocode/autocomplete');
  assert.deepEqual(Object.fromEntries(url.searchParams), {
    apiKey: API_KEY, text: 'Tandag & market', limit: '2', filter: 'rect:125.95,8.95,126.35,9.25',
    bias: 'proximity:126.1985,9.0785', format: 'geojson',
  });
  assert.equal(calls[0].init.method, 'GET');
  assert.equal(calls[0].init.redirect, 'error');
  assert.deepEqual(calls[0].init.headers, { Accept: 'application/json' });
  assert.ok(calls[0].init.signal instanceof AbortSignal);
  assert.ok(!calls[0].url.includes(TOKEN));
});

test('reverse geocoding sends the pinned point as lat/lon and returns at most one place', async () => {
  const { handler, calls } = setup({}, () => jsonResponse(collection([
    place({ place_id: 'reverse_1', formatted: 'Tandag City Public Market, Surigao del Sur' }),
    place({ place_id: 'reverse_2' }),
  ])));
  const response = await handler(request({ action: 'reverse', point: CENTER }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { places: [
    { id: 'reverse_1', label: 'Tandag City Public Market, Surigao del Sur', latitude: 9.0785, longitude: 126.1985 },
  ] });
  assert.equal(calls.length, 1);
  const url = new URL(calls[0].url);
  assert.equal(url.origin + url.pathname, 'https://api.geoapify.com/v1/geocode/reverse');
  assert.deepEqual(Object.fromEntries(url.searchParams), {
    apiKey: API_KEY, lat: '9.0785', lon: '126.1985', limit: '1', format: 'geojson',
  });
});

test('reverse geocoding with no matching place is a successful empty result', async () => {
  const { handler } = setup({}, () => jsonResponse(collection()));
  const response = await handler(request({ action: 'reverse', point: CENTER }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { places: [] });
});

test('autocomplete accepts exact text character and limit boundaries, including Unicode', async () => {
  const { handler, calls } = setup();
  for (const text of ['ab', 'x'.repeat(160), '𐐀'.repeat(160)]) {
    assert.equal((await handler(request({ action: 'autocomplete', text, limit: 1 }))).status, 200);
  }
  assert.equal(new URL(calls[0].url).searchParams.get('limit'), '1');
  assert.equal((await handler(request())).status, 200);
  assert.equal(new URL(calls[3].url).searchParams.get('limit'), '5');
});

test('places maps every allowed category and bounded radius with longitude/latitude circle', async () => {
  const { handler, calls } = setup();
  const categories = ['healthcare.pharmacy', 'commercial.supermarket', 'catering.restaurant', 'service.financial.atm', 'public_transport'];
  const response = await handler(request({ ...PLACES, categories, limit: 20 }));
  assert.equal(response.status, 200);
  const url = new URL(calls[0].url);
  assert.equal(url.origin + url.pathname, 'https://api.geoapify.com/v2/places');
  assert.deepEqual(Object.fromEntries(url.searchParams), {
    apiKey: API_KEY, categories: categories.join(','), filter: 'circle:126.1985,9.0785,5000',
    bias: 'proximity:126.1985,9.0785', limit: '20',
  });
  assert.equal((await handler(request({ ...PLACES, radius: 1, limit: 1 }))).status, 200);
  assert.equal((await handler(request(PLACES))).status, 200);
  assert.equal(new URL(calls[2].url).searchParams.get('limit'), '20');
});

test('PH bounding-box edges are accepted for centers and endpoints', async () => {
  const { handler } = setup({}, () => jsonResponse(collection([routeFeature()])));
  for (const center of [{ latitude: 4.5, longitude: 116 }, { latitude: 21.5, longitude: 127 }]) {
    assert.equal((await handler(request({ ...PLACES, center }))).status, 200);
    assert.equal((await handler(request({ ...ROUTE, start: center, end: center }))).status, 200);
  }
});

for (const mode of ['drive', 'motorcycle', 'walk']) {
  test(`route ${mode} uses latitude/longitude waypoints, metric units and flattened longitude/latitude GeoJSON`, async () => {
    const { handler, calls } = setup({}, () => jsonResponse(collection([routeFeature()])));
    const response = await handler(request({ ...ROUTE, mode }));
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      points: [
        { latitude: 9.0785, longitude: 126.1985 },
        { latitude: 9.08, longitude: 126.199 },
        { latitude: 9.08, longitude: 126.199 },
        { latitude: 9.1, longitude: 126.2 },
      ], distanceMeters: 1200.5, durationSeconds: 180.25,
    });
    const url = new URL(calls[0].url);
    assert.equal(url.origin + url.pathname, 'https://api.geoapify.com/v1/routing');
    assert.deepEqual(Object.fromEntries(url.searchParams), {
      apiKey: API_KEY, waypoints: '9.0785,126.1985|9.1,126.2', mode, units: 'metric',
    });
  });
}

const invalidInputs: [string, unknown][] = [
  ['null', null], ['array', []], ['primitive', 4], ['missing action', {}], ['unknown action', { action: 'proxy' }],
  ['client apiKey', { ...AUTOCOMPLETE, apiKey: 'client_key' }],
  ['client URL', { ...AUTOCOMPLETE, url: 'https://attacker.test' }],
  ['client query', { ...AUTOCOMPLETE, query: { filter: 'countrycode:us' } }],
  ['client filter', { ...AUTOCOMPLETE, filter: 'countrycode:us' }],
  ['client bias', { ...AUTOCOMPLETE, bias: 'proximity:0,0' }],
  ['short text', { ...AUTOCOMPLETE, text: ' a ' }],
  ['blank text', { ...AUTOCOMPLETE, text: '  ' }],
  ['long text', { ...AUTOCOMPLETE, text: 'x'.repeat(161) }],
  ['non-string text', { ...AUTOCOMPLETE, text: 42 }],
  ['control text', { ...AUTOCOMPLETE, text: 'Ta\u0000ndag' }],
  ['autocomplete limit too high', { ...AUTOCOMPLETE, limit: 6 }],
  ['zero limit', { ...AUTOCOMPLETE, limit: 0 }],
  ['fractional limit', { ...AUTOCOMPLETE, limit: 1.5 }],
  ['string limit', { ...AUTOCOMPLETE, limit: '5' }],
  ['null limit', { ...AUTOCOMPLETE, limit: null }],
  ['empty categories', { ...PLACES, categories: [] }],
  ['unknown category', { ...PLACES, categories: ['adult'] }],
  ['string categories', { ...PLACES, categories: 'healthcare.pharmacy' }],
  ['injected category', { ...PLACES, categories: ['healthcare.pharmacy,catering.restaurant'] }],
  ['duplicate categories', { ...PLACES, categories: ['healthcare.pharmacy', 'healthcare.pharmacy'] }],
  ['zero radius', { ...PLACES, radius: 0 }],
  ['excess radius', { ...PLACES, radius: 5001 }],
  ['fractional radius', { ...PLACES, radius: 1.5 }],
  ['missing radius', { action: 'places', categories: PLACES.categories, center: CENTER }],
  ['places limit too high', { ...PLACES, limit: 21 }],
  ['center outside PH north', { ...PLACES, center: { ...CENTER, latitude: 21.5001 } }],
  ['center outside PH south', { ...PLACES, center: { ...CENTER, latitude: 4.4999 } }],
  ['center outside PH east', { ...PLACES, center: { ...CENTER, longitude: 127.0001 } }],
  ['center outside PH west', { ...PLACES, center: { ...CENTER, longitude: 115.9999 } }],
  ['swapped input coordinates', { ...PLACES, center: { latitude: 126.1985, longitude: 9.0785 } }],
  ['NaN coordinate', { ...PLACES, center: { ...CENTER, latitude: NaN } }],
  ['infinite coordinate', { ...PLACES, center: { ...CENTER, longitude: Infinity } }],
  ['string coordinate', { ...PLACES, center: { ...CENTER, latitude: '9.0785' } }],
  ['unknown nested field', { ...PLACES, center: { ...CENTER, url: 'https://attacker.test' } }],
  ['missing route end', { action: 'route', start: CENTER, mode: 'drive' }],
  ['invalid route start', { ...ROUTE, start: { latitude: 0, longitude: 0 } }],
  ['invalid route end', { ...ROUTE, end: { ...END, longitude: 181 } }],
  ['invalid mode', { ...ROUTE, mode: 'bicycle' }],
  ['missing mode', { action: 'route', start: CENTER, end: END }],
  ['client units', { ...ROUTE, units: 'imperial' }],
  ['client waypoints', { ...ROUTE, waypoints: '0,0|1,1' }],
  ['missing reverse point', { action: 'reverse' }],
  ['reverse point outside PH', { action: 'reverse', point: { latitude: 0, longitude: 0 } }],
  ['reverse extra field', { ...REVERSE, limit: 1 }],
];
for (const [name, body] of invalidInputs) {
  test(`invalid input: ${name} is denied before authentication and provider`, async () => {
    const { handler, calls, authCalls } = setup();
    const response = await handler(request(body));
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: 'invalid_input' });
    assertCors(response);
    assert.equal(calls.length, 0);
    assert.equal(authCalls.length, 0);
  });
}

test('malformed/empty JSON and invalid UTF-8 are rejected without provider calls', async () => {
  const { handler, calls } = setup();
  for (const body of ['', '{', 'not-json']) assert.equal((await handler(rawRequest(body))).status, 400);
  const invalidUtf8 = new Request('https://local.test/geoapify', {
    method: 'POST', headers: { Authorization: `Bearer ${TOKEN}` }, body: new Uint8Array([0xff, 0xfe]),
  });
  assert.equal((await handler(invalidUtf8)).status, 400);
  assert.equal(calls.length, 0);
});

test('body cap is 4 KiB of actual bytes, not character count, and accepts the exact boundary', async () => {
  const { handler, calls, authCalls } = setup();
  const padded = JSON.stringify(AUTOCOMPLETE).padEnd(4096, ' ');
  assert.equal((await handler(rawRequest(padded))).status, 200);
  for (const body of [padded + ' ', JSON.stringify({ ...AUTOCOMPLETE, text: 'é'.repeat(2200) })]) {
    const response = await handler(rawRequest(body));
    assert.equal(response.status, 413);
    assert.deepEqual(await response.json(), { error: 'payload_too_large' });
  }
  assert.equal(calls.length, 1);
  assert.equal(authCalls.length, 1);
});

test('oversized declared body is denied without reading the stream', async () => {
  const { handler, calls, authCalls } = setup();
  const response = await handler(rawRequest('{}', { 'Content-Length': '4097' }));
  assert.equal(response.status, 413);
  assert.equal(calls.length, 0);
  assert.equal(authCalls.length, 0);
});

test('chunked oversized body with dishonest small Content-Length is bounded and cancelled', async () => {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new Uint8Array(2048)); controller.enqueue(new Uint8Array(2049)); },
    cancel() { cancelled = true; },
  });
  const req = new Request('https://local.test/geoapify', {
    method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Length': '1' },
    body: stream, duplex: 'half',
  } as RequestInit);
  const { handler, calls } = setup();
  assert.equal((await handler(req)).status, 413);
  assert.ok(cancelled);
  assert.equal(calls.length, 0);
});

test('missing/malformed Bearer credentials are denied before auth/provider', async () => {
  const { handler, calls, authCalls } = setup();
  for (const authorization of ['', 'Basic abc', 'Bearer', 'Bearer a b', `Bearer ${'x'.repeat(4097)}`]) {
    const response = await handler(rawRequest(JSON.stringify(AUTOCOMPLETE), { Authorization: authorization }));
    assert.equal(response.status, 401);
    assertCors(response);
  }
  assert.equal(calls.length, 0);
  assert.equal(authCalls.length, 0);
});

test('unverified, blank or throwing authentication denies provider and hides errors', async () => {
  const callbacks = [
    async () => null, async () => '', async () => '   ',
    async () => { throw new Error(`private ${API_KEY}`); },
  ];
  for (const authenticate of callbacks) {
    const { handler, calls } = setup({ authenticate });
    const response = await handler(request());
    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: 'unauthorized' });
    assert.equal(calls.length, 0);
  }
});

test('missing provider configuration is generic and performs no network requests', async () => {
  const { handler, calls, authCalls } = setup({ apiKey: '' });
  const response = await handler(request());
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: 'not_configured' });
  assert.equal(calls.length, 0);
  assert.equal(authCalls.length, 0);
});

test('authenticator calls the fixed Supabase auth endpoint with anon key and returns remotely verified id', async () => {
  const calls: FetchCall[] = [];
  const controller = new AbortController();
  const user = await verifySupabaseUser(TOKEN, controller.signal, {
    supabaseUrl: 'https://project.supabase.co/ignored?attacker=value', anonKey: 'anon_test_key',
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), init: init ?? {} });
      return jsonResponse({ id: 'remote_verified_user', email: 'private@example.test' });
    }) as typeof fetch,
  });
  assert.equal(user, 'remote_verified_user');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://project.supabase.co/auth/v1/user');
  assert.equal(calls[0].init.method, 'GET');
  assert.equal(calls[0].init.redirect, 'error');
  assert.equal(calls[0].init.signal, controller.signal);
  assert.deepEqual(calls[0].init.headers, {
    Authorization: `Bearer ${TOKEN}`, apikey: 'anon_test_key', Accept: 'application/json',
  });
});

test('forged JWT subject is not trusted when remote auth rejects', async () => {
  const forged = `eyJhbGciOiJub25lIn0.${Buffer.from(JSON.stringify({ sub: 'forged_user' })).toString('base64url')}.fake`;
  let remoteCalls = 0;
  const authenticate: GeoapifyHandlerConfig['authenticate'] = (token, signal) => verifySupabaseUser(token, signal, {
    supabaseUrl: 'https://project.supabase.co', anonKey: 'anon_test_key',
    fetchImpl: (async () => { remoteCalls++; return jsonResponse({ id: 'forged_user' }, 401); }) as typeof fetch,
  });
  const { handler, calls } = setup({ authenticate });
  assert.equal((await handler(request(AUTOCOMPLETE, forged))).status, 401);
  assert.equal(remoteCalls, 1);
  assert.equal(calls.length, 0);
});

test('remote auth rejects malformed/error/oversized bodies and missing verified id', async () => {
  const responses = [
    () => jsonResponse({ sub: 'not_a_verified_id' }),
    () => jsonResponse({ user: { id: 'nested' } }),
    () => jsonResponse({ id: 123 }),
    () => jsonResponse({ id: ' ' }),
    () => new Response('invalid-json'),
    () => jsonResponse({ id: 'untrusted' }, 403),
    () => jsonResponse({ id: 'untrusted' }, 500),
    () => new Response('x'.repeat(65537)),
    () => jsonResponse({ id: 'valid' }, 200, { 'Content-Length': '65537' }),
  ];
  for (const response of responses) {
    assert.equal(await verifySupabaseUser(TOKEN, new AbortController().signal, {
      supabaseUrl: 'https://project.supabase.co', anonKey: 'anon_test_key',
      fetchImpl: (async () => response()) as typeof fetch,
    }), null);
  }
  assert.equal(await verifySupabaseUser(TOKEN, new AbortController().signal, {
    supabaseUrl: 'https://project.supabase.co', anonKey: 'anon_test_key',
    fetchImpl: (async () => { throw new Error('network'); }) as typeof fetch,
  }), null);
});

test('missing/invalid server auth config fails closed before network', async () => {
  for (const config of [
    { supabaseUrl: '', anonKey: 'anon' }, { supabaseUrl: 'https://project.supabase.co', anonKey: '' },
    { supabaseUrl: 'not-a-url', anonKey: 'anon' }, { supabaseUrl: 'file:///private', anonKey: 'anon' },
    { supabaseUrl: 'https://user:password@project.supabase.co', anonKey: 'anon' },
  ]) {
    assert.equal(await verifySupabaseUser(TOKEN, new AbortController().signal, {
      ...config, fetchImpl: (async () => assert.fail('must not fetch')) as typeof fetch,
    }), null);
  }
});

test('search label fallbacks and Point validation do not invent ids or echo secrets', async () => {
  const features = [
    place({ place_id: null }), place({ formatted: null }), place({}, [NaN, 9]),
    place({}, [126, Infinity]), place({}, [181, 9]), place({}, [126, 91]), place({}, ['126', 9]),
    place({}, [126, 9, 'altitude']), place({}, [9, 126]),
    { ...place(), geometry: { type: 'LineString', coordinates: [[126, 9], [126, 10]] } },
    { ...place(), type: 'not_feature' },
    place({ formatted: API_KEY }), place({ place_id: API_KEY }),
    place({ place_id: 'formatted', formatted: 'Formatted', name: 'Name' }),
    place({ place_id: 'name', formatted: null, name: 'Name' }),
    place({ place_id: 'lines', formatted: null, address_line1: 'Street', address_line2: 'Tandag' }),
    place({ place_id: 'address', formatted: null, housenumber: '12', street: 'Main', city: 'Tandag' }),
    place({ place_id: 'altitude' }, [126.2, 9.1, 10]),
  ];
  const { handler } = setup({}, () => jsonResponse(collection(features)));
  const response = await handler(request());
  assert.deepEqual(await response.json(), { places: [
    { id: 'formatted', label: 'Formatted', latitude: 9.0785, longitude: 126.1985 },
    { id: 'name', label: 'Name', latitude: 9.0785, longitude: 126.1985 },
    { id: 'lines', label: 'Street, Tandag', latitude: 9.0785, longitude: 126.1985 },
    { id: 'address', label: '12 Main, Tandag', latitude: 9.0785, longitude: 126.1985 },
    { id: 'altitude', label: 'Tandag, Philippines', latitude: 9.1, longitude: 126.2 },
  ] });
});

test('normalized search output never exceeds the requested limit', async () => {
  const { handler } = setup({}, () => jsonResponse(collection(Array.from({ length: 25 }, (_, i) => place({ place_id: `id_${i}` })))));
  for (const [body, length] of [[AUTOCOMPLETE, 5], [{ ...PLACES, limit: 2 }, 2], [PLACES, 20]] as const) {
    const response = await handler(request(body));
    const result = await response.json();
    assert.equal(result.places.length, length);
    assert.equal(result.places[0].id, 'id_0');
  }
});

test('empty search results are successful; absent routes are explicit, never fabricated', async () => {
  const { handler } = setup({}, () => jsonResponse(collection()));
  for (const body of [AUTOCOMPLETE, PLACES]) {
    const response = await handler(request(body));
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { places: [] });
  }
  const response = await handler(request(ROUTE));
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: 'route_not_found' });
});

test('valid LineString and zero-valued provider statistics are preserved without guesses', async () => {
  const { handler } = setup({}, () => jsonResponse(collection([
    routeFeature({ distance: 0, time: 0 }, { type: 'LineString', coordinates: [[126, 9, 1], [126, 9, 2]] }),
  ])));
  const response = await handler(request(ROUTE));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    points: [{ latitude: 9, longitude: 126 }, { latitude: 9, longitude: 126 }], distanceMeters: 0, durationSeconds: 0,
  });
});

test('malformed routes reject missing/nonfinite/negative statistics and invalid coordinates, never partial routes', async () => {
  const features = [
    null, {}, routeFeature({ distance: null }), routeFeature({ time: undefined }),
    routeFeature({ distance: -1 }), routeFeature({ time: -1 }), routeFeature({ distance: Infinity }),
    routeFeature({ time: NaN }), routeFeature({ distance: '1200' }),
    routeFeature({}, { type: 'Point', coordinates: [126, 9] }),
    routeFeature({}, { coordinates: [] }), routeFeature({}, { coordinates: [[]] }),
    routeFeature({}, { coordinates: [[[126, 9]]] }),
    routeFeature({}, { coordinates: [[[126, 9], [126, NaN]]] }),
    routeFeature({}, { coordinates: [[[126, 9], [181, 9]]] }),
    routeFeature({}, { coordinates: [[[126, 9], [126, 91]]] }),
    routeFeature({}, { coordinates: [[[126, 9], ['126', 9]]] }),
    routeFeature({}, { coordinates: [[[126, 9], [126, 10]], [[126, 10], [9, 126]]] }),
  ];
  for (const feature of features) {
    const { handler } = setup({}, () => jsonResponse(collection([feature])));
    const response = await handler(request(ROUTE));
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: 'upstream_failed' });
  }
});

test('numeric JSON overflow is rejected as nonfinite in requests, search coordinates and route statistics', async () => {
  const input = setup();
  const badCenter = '{"action":"places","categories":["healthcare.pharmacy"],"center":{"latitude":1e400,"longitude":126},"radius":100}';
  assert.equal((await input.handler(rawRequest(badCenter))).status, 400);
  assert.equal(input.calls.length, 0);

  const search = setup({}, () => new Response('{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"place_id":"overflow","formatted":"Overflow"},"geometry":{"type":"Point","coordinates":[1e400,9]}}]}'));
  const searchResult = await search.handler(request());
  assert.equal(searchResult.status, 200);
  assert.deepEqual(await searchResult.json(), { places: [] });

  const route = setup({}, () => new Response('{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"distance":1e400,"time":10},"geometry":{"type":"MultiLineString","coordinates":[[[126,9],[126,10]]]}}]}'));
  assert.equal((await route.handler(request(ROUTE))).status, 502);
});

test('malformed upstream JSON and non-FeatureCollection results produce generic 502', async () => {
  for (const response of [
    () => new Response('private not-json'), () => jsonResponse(null),
    () => jsonResponse({ features: [] }), () => jsonResponse({ type: 'FeatureCollection', features: {} }),
  ]) {
    const { handler } = setup({}, response);
    const result = await handler(request());
    assert.equal(result.status, 502);
    assert.deepEqual(await result.json(), { error: 'upstream_failed' });
    assertCors(result);
  }
});

test('upstream errors including 429/redirects and network failures hide provider bodies and API key', async (t) => {
  const logs: unknown[][] = [];
  t.mock.method(console, 'log', (...args: unknown[]) => { logs.push(args); });
  t.mock.method(console, 'error', (...args: unknown[]) => { logs.push(args); });
  t.mock.method(console, 'warn', (...args: unknown[]) => { logs.push(args); });
  for (const status of [400, 401, 403, 429, 500, 503, 302]) {
    const { handler } = setup({}, () => new Response(`private provider body ${API_KEY} at ${CENTER.latitude}`, { status }));
    const response = await handler(request());
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: 'upstream_failed' });
  }
  const { handler } = setup({ fetchImpl: (async () => { throw new Error(`private URL ${API_KEY}`); }) as typeof fetch });
  const response = await handler(request());
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'upstream_failed' });
  assert.deepEqual(logs, []);
});

test('upstream parsing has a 1 MiB declared and streamed byte cap', async () => {
  for (const response of [
    () => new Response('x'.repeat(1024 * 1024 + 1)),
    () => jsonResponse(collection(), 200, { 'Content-Length': String(1024 * 1024 + 1) }),
  ]) {
    const { handler } = setup({}, response);
    const result = await handler(request());
    assert.equal(result.status, 502);
    assert.deepEqual(await result.json(), { error: 'upstream_failed' });
  }
  const padded = JSON.stringify(collection()).padEnd(1024 * 1024, ' ');
  const { handler } = setup({}, () => new Response(padded));
  assert.equal((await handler(request())).status, 200);
});

test('upstream streamed oversize cancels the stream, even with dishonest Content-Length', async () => {
  let cancelled = false;
  const { handler } = setup({}, () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(1024 * 1024)); controller.enqueue(new Uint8Array(1));
    },
    cancel() { cancelled = true; },
  }), { headers: { 'Content-Length': '1' } }));
  assert.equal((await handler(request())).status, 502);
  assert.ok(cancelled);
});

test('auth deadline aborts and denies provider even when the callback ignores the signal', async () => {
  let signal: AbortSignal | undefined;
  const { handler, calls } = setup({ authTimeoutMs: 5, authenticate: async (_, value) => {
    signal = value;
    return new Promise<string | null>(() => {});
  } });
  const response = await handler(request());
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'unauthorized' });
  assert.ok(signal?.aborted);
  assert.equal(calls.length, 0);
});

test('provider deadline produces generic 504 and aborts even when fetch ignores signal', async () => {
  let signal: AbortSignal | null | undefined;
  const { handler } = setup({ upstreamTimeoutMs: 5, fetchImpl: (async (_: RequestInfo | URL, init?: RequestInit) => {
    signal = init?.signal;
    return new Promise<Response>(() => {});
  }) as typeof fetch });
  const response = await handler(request());
  assert.equal(response.status, 504);
  assert.deepEqual(await response.json(), { error: 'upstream_timeout' });
  assert.ok(signal?.aborted);
  assertCors(response);
});

test('provider deadline includes response streaming/parsing and cancels a stalled body', async () => {
  let cancelled = false;
  const { handler } = setup({ upstreamTimeoutMs: 5 }, () => new Response(new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode('{"type":')); },
    cancel() { cancelled = true; },
  })));
  const response = await handler(request());
  assert.equal(response.status, 504);
  assert.ok(cancelled);
});

test('auth deadline includes bounded remote auth body consumption', async () => {
  let cancelled = false;
  const { handler, calls } = setup({
    authTimeoutMs: 5,
    authenticate: (token, signal) => verifySupabaseUser(token, signal, {
      supabaseUrl: 'https://project.supabase.co', anonKey: 'anon_test_key',
      fetchImpl: (async () => new Response(new ReadableStream<Uint8Array>({
        start(controller) { controller.enqueue(new TextEncoder().encode('{"id":')); },
        cancel() { cancelled = true; },
      }))) as typeof fetch,
    }),
  });
  assert.equal((await handler(request())).status, 401);
  assert.ok(cancelled);
  assert.equal(calls.length, 0);
});

test('auth and provider timeouts cannot be configured beyond 3 and 5 seconds', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let authSignal: AbortSignal | undefined;
  const auth = setup({ authTimeoutMs: 30_000, authenticate: async (_, signal) => {
    authSignal = signal; return new Promise<string | null>(() => {});
  } });
  const authResult = auth.handler(request());
  await setImmediate();
  t.mock.timers.tick(2999);
  assert.equal(authSignal?.aborted, false);
  t.mock.timers.tick(1);
  assert.equal((await authResult).status, 401);
  assert.ok(authSignal?.aborted);

  let providerSignal: AbortSignal | null | undefined;
  const provider = setup({ upstreamTimeoutMs: 30_000, fetchImpl: (async (_: RequestInfo | URL, init?: RequestInit) => {
    providerSignal = init?.signal; return new Promise<Response>(() => {});
  }) as typeof fetch });
  const providerResult = provider.handler(request());
  await setImmediate();
  t.mock.timers.tick(4999);
  assert.equal(providerSignal?.aborted, false);
  t.mock.timers.tick(1);
  assert.equal((await providerResult).status, 504);
  assert.ok(providerSignal?.aborted);
});

test('per-verified-user quota allows 30/minute, returns CORS/Retry-After on 31st and resets at TTL', async () => {
  let now = 0;
  const { handler, calls } = setup({ now: () => now });
  for (let i = 0; i < 30; i++) assert.equal((await handler(request(AUTOCOMPLETE, `rotated.token.${i}`))).status, 200);
  let response = await handler(request());
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '60');
  assert.deepEqual(await response.json(), { error: 'rate_limited' });
  assertCors(response);
  assert.equal(calls.length, 30);
  now = 1500;
  response = await handler(request());
  assert.equal(response.headers.get('retry-after'), '59');
  now = 60_000;
  assert.equal((await handler(request())).status, 200);
  assert.equal(calls.length, 31);
});

test('different remotely verified users have separate quotas, not arbitrary user headers', async () => {
  const { handler, calls } = setup({ authenticate: async (token) => token === 'user.two.token' ? 'user_2' : 'user_1' });
  for (let i = 0; i < 30; i++) assert.equal((await handler(request())).status, 200);
  const response = await handler(rawRequest(JSON.stringify(AUTOCOMPLETE), { 'x-user-id': 'user_2', apikey: 'client_key' }));
  assert.equal(response.status, 429);
  assert.equal((await handler(request(AUTOCOMPLETE, 'user.two.token'))).status, 200);
  assert.equal(calls.length, 31);
});

test('invalid and unauthenticated requests do not consume verified-user quota', async () => {
  let verified = false;
  const { handler } = setup({ authenticate: async () => verified ? 'user_1' : null });
  for (let i = 0; i < 35; i++) {
    assert.equal((await handler(request())).status, 401);
    assert.equal((await handler(request({ action: 'unknown' }))).status, 400);
  }
  verified = true;
  for (let i = 0; i < 30; i++) assert.equal((await handler(request())).status, 200);
  assert.equal((await handler(request())).status, 429);
});

test('upstream failures still consume quota; concurrent requests cannot exceed 30 provider calls', async () => {
  const { handler, calls } = setup({}, () => new Response('private', { status: 503 }));
  const responses = await Promise.all(Array.from({ length: 35 }, () => handler(request())));
  assert.equal(responses.filter((response) => response.status === 502).length, 30);
  assert.equal(responses.filter((response) => response.status === 429).length, 5);
  assert.equal(calls.length, 30);
});

test('bounded user map fails closed at capacity, preserves active quotas, and reclaims expired entries', async () => {
  let now = 0;
  const { handler, calls } = setup({ now: () => now, authenticate: async (token) => token });
  for (let i = 0; i < 1024; i++) assert.equal((await handler(request(AUTOCOMPLETE, `user.${i}.token`))).status, 200);
  const response = await handler(request(AUTOCOMPLETE, 'new.user.token'));
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '60');
  for (let i = 1; i < 30; i++) assert.equal((await handler(request(AUTOCOMPLETE, 'user.0.token'))).status, 200);
  assert.equal((await handler(request(AUTOCOMPLETE, 'user.0.token'))).status, 429);
  now = 60_000;
  assert.equal((await handler(request(AUTOCOMPLETE, 'new.user.token'))).status, 200);
  assert.equal(calls.length, 1024 + 29 + 1);
});

test('handler instances intentionally do not share or persist rate-limit state', async () => {
  const first = setup();
  const second = setup();
  for (let i = 0; i < 30; i++) assert.equal((await first.handler(request())).status, 200);
  assert.equal((await first.handler(request())).status, 429);
  assert.equal((await second.handler(request())).status, 200);
});
