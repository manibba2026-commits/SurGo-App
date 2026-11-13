export interface GeoapifyHandlerConfig {
  apiKey: string;
  // The callback must verify the token remotely, never just decode its subject.
  authenticate: (token: string, signal: AbortSignal) => Promise<string | null>;
  fetchImpl?: typeof fetch;
  now?: () => number;
  authTimeoutMs?: number;
  upstreamTimeoutMs?: number;
}

interface MapPoint {
  latitude: number;
  longitude: number;
}

type Action =
  | { action: 'autocomplete'; text: string; limit: number }
  | { action: 'places'; categories: string[]; center: MapPoint; radius: number; limit: number }
  | { action: 'route'; start: MapPoint; end: MapPoint; mode: 'drive' | 'motorcycle' | 'walk' }
  | { action: 'reverse'; point: MapPoint };

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Expose-Headers': 'Retry-After',
};
const MAX_REQUEST_BYTES = 4 * 1024;
const MAX_UPSTREAM_BYTES = 1024 * 1024;
const WINDOW_MS = 60_000;
const MAX_USERS = 1024;
const CATEGORIES = new Set([
  'healthcare.pharmacy',
  'commercial.supermarket',
  'catering.restaurant',
  'service.financial.atm',
  'public_transport',
]);
const ENDPOINTS = {
  autocomplete: 'https://api.geoapify.com/v1/geocode/autocomplete',
  places: 'https://api.geoapify.com/v2/places',
  route: 'https://api.geoapify.com/v1/routing',
  reverse: 'https://api.geoapify.com/v1/geocode/reverse',
};

class BodyTooLarge extends Error {}
class DeadlineExceeded extends Error {}

function json(body: Record<string, unknown>, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers },
  });
}

/** Bounds actual streamed bytes, not just a potentially dishonest Content-Length. */
export async function readBoundedJson(
  message: Request | Response,
  maxBytes: number,
  signal?: AbortSignal,
): Promise<unknown> {
  const declared = message.headers.get('content-length');
  if (declared !== null && Number(declared) > maxBytes) {
    void message.body?.cancel().catch(() => {});
    throw new BodyTooLarge();
  }
  if (!message.body) throw new Error('missing_body');
  const reader = message.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal?.addEventListener('abort', cancel, { once: true });
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let bytes = 0;
  let text = '';
  try {
    signal?.throwIfAborted();
    for (;;) {
      const { done, value } = await reader.read();
      signal?.throwIfAborted();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maxBytes) throw new BodyTooLarge();
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return JSON.parse(text);
  } catch (error) {
    cancel();
    throw error;
  } finally {
    signal?.removeEventListener('abort', cancel);
    reader.releaseLock();
  }
}

async function withDeadline<T>(operation: (signal: AbortSignal) => Promise<T>, timeoutMs: number): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const expired = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      reject(new DeadlineExceeded());
      controller.abort();
    }, timeoutMs);
  });
  try {
    // Racing also bounds injected implementations which ignore AbortSignal.
    return await Promise.race([Promise.resolve().then(() => operation(controller.signal)), expired]);
  } finally {
    clearTimeout(timer);
  }
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function onlyKeys(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}

function finite(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function integer(value: unknown, min: number, max: number): value is number {
  return finite(value) && Number.isInteger(value) && value >= min && value <= max;
}

function point(value: unknown): value is MapPoint {
  if (!record(value) || !onlyKeys(value, ['latitude', 'longitude'])) return false;
  // Philippine bounding box, not a claim of polygon-level boundary checking.
  return finite(value.latitude) && value.latitude >= 4.5 && value.latitude <= 21.5 &&
    finite(value.longitude) && value.longitude >= 116 && value.longitude <= 127;
}

function parseAction(body: unknown): Action | null {
  if (!record(body)) return null;
  if (body.action === 'autocomplete') {
    if (!onlyKeys(body, ['action', 'text', 'limit']) || typeof body.text !== 'string') return null;
    const text = body.text.trim();
    const length = Array.from(text).length;
    const limit = body.limit === undefined ? 5 : body.limit;
    if (length < 2 || length > 160 || /[\u0000-\u001f\u007f]/u.test(text) || !integer(limit, 1, 5)) return null;
    return { action: 'autocomplete', text, limit };
  }
  if (body.action === 'places') {
    if (!onlyKeys(body, ['action', 'categories', 'center', 'radius', 'limit'])) return null;
    const limit = body.limit === undefined ? 20 : body.limit;
    if (!Array.isArray(body.categories) || body.categories.length < 1 || body.categories.length > CATEGORIES.size ||
      !body.categories.every((category): category is string => typeof category === 'string' && CATEGORIES.has(category)) ||
      new Set(body.categories).size !== body.categories.length || !point(body.center) ||
      !integer(body.radius, 1, 5000) || !integer(limit, 1, 20)) return null;
    return { action: 'places', categories: body.categories, center: body.center, radius: body.radius, limit };
  }
  if (body.action === 'route') {
    if (!onlyKeys(body, ['action', 'start', 'end', 'mode']) || !point(body.start) || !point(body.end) ||
      (body.mode !== 'drive' && body.mode !== 'motorcycle' && body.mode !== 'walk')) return null;
    return { action: 'route', start: body.start, end: body.end, mode: body.mode };
  }
  if (body.action === 'reverse') {
    if (!onlyKeys(body, ['action', 'point']) || !point(body.point)) return null;
    return { action: 'reverse', point: body.point };
  }
  return null;
}

function providerUrl(action: Action, apiKey: string): URL {
  const url = new URL(ENDPOINTS[action.action]);
  const params = url.searchParams;
  params.set('apiKey', apiKey);
  if (action.action === 'autocomplete') {
    params.set('text', action.text);
    params.set('limit', String(action.limit));
    // Tandag service area: keep suggestions local instead of returning
    // nationwide matches for a short query.
    params.set('filter', 'rect:125.95,8.95,126.35,9.25');
    // Geoapify proximity/filter coordinates are longitude,latitude.
    params.set('bias', 'proximity:126.1985,9.0785');
    params.set('format', 'geojson');
  } else if (action.action === 'places') {
    params.set('categories', action.categories.join(','));
    params.set('filter', `circle:${action.center.longitude},${action.center.latitude},${action.radius}`);
    params.set('bias', `proximity:${action.center.longitude},${action.center.latitude}`);
    params.set('limit', String(action.limit));
  } else if (action.action === 'reverse') {
    params.set('lat', String(action.point.latitude));
    params.set('lon', String(action.point.longitude));
    params.set('limit', '1');
    params.set('format', 'geojson');
  } else {
    // Routing waypoints are the opposite order: latitude,longitude.
    params.set('waypoints', `${action.start.latitude},${action.start.longitude}|${action.end.latitude},${action.end.longitude}`);
    params.set('mode', action.mode);
    params.set('units', 'metric');
  }
  return url;
}

function coordinate(value: unknown): value is number[] {
  return Array.isArray(value) && value.length >= 2 && value.length <= 3 && value.every(finite) &&
    value[0] >= -180 && value[0] <= 180 && value[1] >= -90 && value[1] <= 90;
}

function safeText(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= 512 ? value.trim() : null;
}

function placeLabel(properties: Record<string, unknown>): string | null {
  const label = safeText(properties.formatted) ?? safeText(properties.name);
  if (label) return label;
  const lines = [properties.address_line1, properties.address_line2].map(safeText).filter(Boolean);
  if (lines.length) return safeText(lines.join(', '));
  const street = [properties.housenumber, properties.street].map(safeText).filter(Boolean).join(' ');
  return safeText([street, properties.city, properties.state, properties.country].map(safeText).filter(Boolean).join(', '));
}

function normalizePlaces(features: unknown[], limit: number, apiKey: string): Record<string, unknown> {
  const places: { id: string; label: string; latitude: number; longitude: number }[] = [];
  for (const feature of features) {
    if (!record(feature) || feature.type !== 'Feature' || !record(feature.geometry) ||
      feature.geometry.type !== 'Point' || !coordinate(feature.geometry.coordinates) || !record(feature.properties)) continue;
    const id = safeText(feature.properties.place_id);
    const label = placeLabel(feature.properties);
    // Never pass through the provider payload, even if a key is echoed in a field.
    if (!id || !label || id.includes(apiKey) || label.includes(apiKey)) continue;
    const [longitude, latitude] = feature.geometry.coordinates;
    places.push({ id, label, latitude, longitude });
    if (places.length === limit) break;
  }
  return { places };
}

function normalizeRoute(features: unknown[]): Record<string, unknown> {
  const feature = features[0];
  if (!record(feature) || feature.type !== 'Feature' || !record(feature.properties) || !record(feature.geometry)) {
    throw new Error('invalid_route');
  }
  const { distance, time } = feature.properties;
  if (!finite(distance) || distance < 0 || !finite(time) || time < 0) throw new Error('invalid_route');
  const geometry = feature.geometry;
  const segments: unknown = geometry.type === 'MultiLineString' ? geometry.coordinates :
    geometry.type === 'LineString' ? [geometry.coordinates] : null;
  if (!Array.isArray(segments) || segments.length === 0) throw new Error('invalid_route');
  const points: MapPoint[] = [];
  for (const segment of segments) {
    if (!Array.isArray(segment) || segment.length < 2 || !segment.every(coordinate)) throw new Error('invalid_route');
    for (const [longitude, latitude] of segment) points.push({ latitude, longitude });
  }
  return { points, distanceMeters: distance, durationSeconds: time };
}

/** Fixed server-configured Auth URL; no service-role key or local JWT decoding. */
export async function verifySupabaseUser(
  token: string,
  signal: AbortSignal,
  config: { supabaseUrl: string; anonKey: string; fetchImpl?: typeof fetch },
): Promise<string | null> {
  if (!config.supabaseUrl || !config.anonKey) return null;
  try {
    const base = new URL(config.supabaseUrl);
    if (!['https:', 'http:'].includes(base.protocol) || base.username || base.password) return null;
    const response = await (config.fetchImpl ?? fetch)(new URL('/auth/v1/user', base), {
      method: 'GET',
      headers: { Authorization: `Bearer ${token}`, apikey: config.anonKey, Accept: 'application/json' },
      redirect: 'error',
      signal,
    });
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      return null;
    }
    const user = await readBoundedJson(response, 64 * 1024, signal);
    return record(user) && safeText(user.id) ? safeText(user.id) : null;
  } catch {
    return null;
  }
}

/**
 * One in-instance, bounded TTL limiter per handler. Not durable or shared across
 * Edge workers/restarts; no DB quota is created. Capacity fails closed rather
 * than evicting active users and permitting quota bypass.
 */
export function createGeoapifyHandler(config: GeoapifyHandlerConfig): (request: Request) => Promise<Response> {
  const users = new Map<string, { count: number; expires: number }>();
  const now = config.now ?? Date.now;
  const authTimeoutMs = Math.min(config.authTimeoutMs ?? 3000, 3000);
  const upstreamTimeoutMs = Math.min(config.upstreamTimeoutMs ?? 5000, 5000);

  return async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
    if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, { Allow: 'POST, OPTIONS' });

    let action: Action | null;
    try {
      action = parseAction(await readBoundedJson(request, MAX_REQUEST_BYTES));
    } catch (error) {
      return json({ error: error instanceof BodyTooLarge ? 'payload_too_large' : 'invalid_input' }, error instanceof BodyTooLarge ? 413 : 400);
    }
    if (!action) return json({ error: 'invalid_input' }, 400);
    const bearer = /^Bearer ([^\s]+)$/i.exec(request.headers.get('authorization') ?? '');
    if (!bearer || bearer[1].length > 4096) return json({ error: 'unauthorized' }, 401);
    if (!config.apiKey) return json({ error: 'not_configured' }, 500);

    let verifiedId: string | null;
    try {
      verifiedId = await withDeadline((signal) => config.authenticate(bearer[1], signal), authTimeoutMs);
    } catch {
      return json({ error: 'unauthorized' }, 401);
    }
    const userId = safeText(verifiedId);
    if (!userId) return json({ error: 'unauthorized' }, 401);

    const timestamp = now();
    for (const [id, entry] of users) if (entry.expires <= timestamp) users.delete(id);
    const entry = users.get(userId);
    if (entry && entry.count >= 30) {
      return json({ error: 'rate_limited' }, 429, { 'Retry-After': String(Math.max(1, Math.ceil((entry.expires - timestamp) / 1000))) });
    }
    if (!entry && users.size >= MAX_USERS) {
      const expiry = Math.min(...Array.from(users.values(), (value) => value.expires));
      return json({ error: 'rate_limited' }, 429, { 'Retry-After': String(Math.max(1, Math.ceil((expiry - timestamp) / 1000))) });
    }
    if (entry) entry.count++;
    else users.set(userId, { count: 1, expires: timestamp + WINDOW_MS });

    try {
      const body = await withDeadline(async (signal) => {
        const response = await (config.fetchImpl ?? fetch)(providerUrl(action, config.apiKey), {
          method: 'GET', headers: { Accept: 'application/json' }, redirect: 'error', signal,
        });
        if (!response.ok) {
          void response.body?.cancel().catch(() => {});
          throw new Error('upstream_failed');
        }
        return readBoundedJson(response, MAX_UPSTREAM_BYTES, signal);
      }, upstreamTimeoutMs);
      if (!record(body) || body.type !== 'FeatureCollection' || !Array.isArray(body.features)) throw new Error('invalid_response');
      if (action.action === 'reverse') return json(normalizePlaces(body.features, 1, config.apiKey));
      if (action.action !== 'route') return json(normalizePlaces(body.features, action.limit, config.apiKey));
      if (body.features.length === 0) return json({ error: 'route_not_found' }, 404);
      return json(normalizeRoute(body.features));
    } catch (error) {
      return json({ error: error instanceof DeadlineExceeded ? 'upstream_timeout' : 'upstream_failed' }, error instanceof DeadlineExceeded ? 504 : 502);
    }
  };
}
