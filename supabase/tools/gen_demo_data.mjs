// Generates supabase/demo-data.sql from assets/db/*.json.
//
// The output is a single idempotent file applied through the Supabase MCP
// execute_sql tool (service role). It is NOT a tracked migration and is NOT
// part of supabase/tests — the 8 SQL tests must stay at zero demo rows.
//
// Mapping rules (see also supabase/README.md):
//   * One profile per PERSON, not per JSON role row (P001/R001/VOW-77213 are
//     the same human). Emails/phones are unique in public.profiles.
//   * Deterministic ids: md5('surgo:demo:<kind>:<key>') for business rows,
//     md5('surgo:demo:profile:<slug>') for people. Geography ids reuse the
//     exact seed.sql formulas so FKs resolve without lookups.
//   * Demo auth.users rows carry no password and banned_until = 'infinity';
//     the handle_new_auth_user trigger creates the profile + approved
//     passenger role, and this file upserts over it. The real admin user is
//     never referenced.
//   * Cash only. Non-cash JSON methods are preserved in note fields.
//   * platform_fee_centavos is always 0 and no pricing_policies row is
//     created: pricing stays dormant until the pricing phase is approved.
//   * Lifecycle timestamps that the schema requires but the JSON lacks
//     (accepted_at, started_at, ...) are derived from real JSON timestamps by
//     fixed offsets. No other facts are invented.

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { DEMO_PHONES } from './demo_provision_plan.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const supabaseDir = path.resolve(here, '..');
const assetsDir = path.resolve(supabaseDir, '..', 'assets', 'db');

const read = (name) =>
  JSON.parse(fs.readFileSync(path.join(assetsDir, name), 'utf8'));

const users = read('users.json');
const accounts = read('accounts.json').accounts;
const vehiclesJson = read('vehicles.json');
const ridesJson = read('rides.json');
const rentalsJson = read('rentals.json');
const pasuyoJson = read('pasuyo.json');
const walletsJson = read('wallets.json');
const applicationsJson = read('applications.json').applications;

// Fixed clock so relative labels ("2 min ago") always resolve identically.
const ANCHOR = Date.parse('2026-11-06T12:00:00.000Z');

const hexUuid = (hex) =>
  `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;

const md5 = (s) => createHash('md5').update(s).digest('hex');
const demoId = (kind, key) => hexUuid(md5(`surgo:demo:${kind}:${key}`));
const profileId = (slug) => hexUuid(md5(`surgo:demo:profile:${slug}`));

const SERVICE_AREA = hexUuid(md5('surgo:service-area:tandag-city'));
const barangayId = (name) =>
  hexUuid(md5(`surgo:barangay:tandag-city:${name.toLowerCase()}`));
const purokId = (barangay, purok) =>
  hexUuid(
    md5(
      `surgo:purok:tandag-city:${barangay.toLowerCase()}:${purok.toLowerCase()}`,
    ),
  );

// Which (barangay, purok) pairs the geography seed actually contains.
const seedSql = fs.readFileSync(path.join(supabaseDir, 'seed.sql'), 'utf8');
const seededPuroks = new Set();
for (const m of seedSql.matchAll(
  /lower\('surgo:purok:tandag-city:' \|\| lower\('([^']+)'\) \|\| ':' \|\| lower\('([^']+)'\)/g,
)) {
  seededPuroks.add(`${m[1].toLowerCase()}|${m[2].toLowerCase()}`);
}
const seededBarangays = new Set();
for (const m of seedSql.matchAll(
  /md5\('surgo:barangay:tandag-city:' \|\| lower\('([^']+)'\)/g,
)) {
  seededBarangays.add(m[1].toLowerCase());
}

// ---------- helpers ----------

const q = (v) => {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (Array.isArray(v)) return `'{${v.map((x) => `"${x}"`).join(', ')}}'`;
  return `'${String(v).replace(/'/g, "''")}'`;
};

const iso = (ms) => new Date(ms).toISOString().replace('Z', '+00:00');

const ago = (ms) => {
  const mins = Math.round((ANCHOR - ms) / 60000);
  if (mins <= 0) return 0;
  if (mins < 60) return `${mins} min`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs} hr`;
  const days = Math.floor(hrs / 24);
  return `${days} day${days > 1 ? 's' : ''}`;
};

// "2 min ago" / "Just now" / "Yesterday" / "3 days ago" / "1 week ago"
const parseRelative = (label) => {
  const s = String(label ?? '').trim().toLowerCase();
  if (!s || s === 'just now') return ANCHOR;
  if (s === 'yesterday') return ANCHOR - 26 * 3600_000;
  let m = s.match(/^(\d+)\s*min/);
  if (m) return ANCHOR - m[1] * 60_000;
  m = s.match(/^(\d+)\s*hr/);
  if (m) return ANCHOR - m[1] * 3600_000;
  m = s.match(/^(\d+)\s*week/);
  if (m) return ANCHOR - m[1] * 7 * 86400_000;
  m = s.match(/^(\d+)\s*day/);
  if (m) return ANCHOR - m[1] * 86400_000;
  const parsed = Date.parse(s);
  if (!Number.isNaN(parsed)) return parsed;
  return ANCHOR;
};

// Either an ISO string (with optional " · label" suffix) or a relative label.
const parseTime = (v) => {
  const s = String(v ?? '').trim();
  const m = s.match(/^\d{4}-\d{2}-\d{2}T[\d:.]+Z?/);
  if (m) return Date.parse(m[0].endsWith('Z') ? m[0] : `${m[0]}Z`);
  return parseRelative(s);
};

const titleToTitleCase = (t) =>
  t
    .toLowerCase()
    .replace(/(^|[\s(/-])\w/g, (c) => c.toUpperCase());

// "Purok 3, San Isidro" -> { barangay, purok } when barangay is seeded.
function resolveBarangay(rawName) {
  if (!rawName) return null;
  const name = rawName.trim();
  const lower = name.toLowerCase();
  for (const seeded of seededBarangays) {
    if (lower === seeded) return seeded;
  }
  if (lower === 'poblacion' || lower === 'downtown') return 'bagong lungsod (poblacion)';
  // Longest seeded name contained in the label ("San Agustin Sur" etc).
  let best = null;
  for (const seeded of seededBarangays) {
    if (lower.includes(seeded) && (!best || seeded.length > best.length)) {
      best = seeded;
    }
  }
  return best;
}

// Canonical barangay label as it exists in seed.sql (case-sensitive for md5).
const seedLabels = new Map();
for (const m of seedSql.matchAll(
  /md5\('surgo:barangay:tandag-city:' \|\| lower\('([^']+)'\)::uuid,[^,]*,\s*'([^']+)'/g,
)) {
  seedLabels.set(m[1].toLowerCase(), m[2]);
}
for (const m of seedSql.matchAll(
  /lower\('surgo:purok:tandag-city:' \|\| lower\('([^']+)'\)/g,
)) {
  if (!seedLabels.has(m[1].toLowerCase())) {
    seedLabels.set(m[1].toLowerCase(), titleToTitleCase(m[1]));
  }
}
seedLabels.set('bagong lungsod (poblacion)', 'Bagong Lungsod (Poblacion)');
seedLabels.set('bongtod poblacion (east west)', 'Bongtod Poblacion (East West)');
seedLabels.set('dagocdoc (poblacion)', 'Dagocdoc (Poblacion)');

const barangayLabel = (lower) =>
  seedLabels.get(lower) ?? titleToTitleCase(lower);

// Returns SQL value: uuid text (seed formula) or null when not seeded.
const fkBarangay = (rawName) => {
  const lower = resolveBarangay(rawName);
  return lower ? barangayId(seedLabels.get(lower) ?? titleToTitleCase(lower)) : null;
};

const fkPurok = (rawBarangay, rawPurok) => {
  const lower = resolveBarangay(rawBarangay);
  if (!lower || !rawPurok) return null;
  const label = seedLabels.get(lower) ?? titleToTitleCase(lower);
  const purok = String(rawPurok).trim();
  return seededPuroks.has(`${lower}|${purok.toLowerCase()}`)
    ? purokId(label, purok)
    : null;
};

const cashNote = (method, note) => {
  const base = note ? note : '';
  if (!method || /^cash$/i.test(method.trim())) return base || null;
  const tag = `Originally ${method.trim()}; pilot settlement is cash.`;
  return base ? `${base} ${tag}` : tag;
};

const clampRating = (r) => (r < 1 ? 1 : r);
const money = (cents) => Math.round(cents);

const M = 60_000, H = 3600_000, D = 86400_000;

// ---------- people ----------

const slugify = (name) =>
  name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

const byId = {};
for (const p of users.passengers) byId[p.id] = { kind: 'passenger', ...p };
for (const e of users.earners) byId[e.id] = { kind: 'earner', ...e };
for (const o of users.owners) byId[o.id] = { kind: 'owner', ...o };

// person = one human, keyed by email. Role rows map onto it.
const personByEmail = new Map();
const personByRoleId = new Map();
function personFor(email, name, phone) {
  if (!personByEmail.has(email)) {
    personByEmail.set(email, {
      slug: slugify(name),
      name,
      email,
      phone,
      roles: {},
      ratings: {},
    });
  }
  return personByEmail.get(email);
}

for (const [id, row] of Object.entries(byId)) {
  const p = personFor(row.email, row.name, row.phone);
  p.roles[row.kind] = { id, ...row };
  if (row.kind === 'passenger') p.rating = row.rating;
  if (row.kind === 'earner') p.rating = row.rating;
}
// Jr Derigay: passenger rating 4.9 vs earner 4.95 — keep the earner figure,
// it matches the provider profile the app highlights. (Documented rule.)
for (const p of personByEmail.values()) {
  const rec = p.roles.earner ?? p.roles.passenger ?? p.roles.owner;
  p.rating = rec.rating;
  p.total =
    (p.roles.earner?.totalTrips ?? 0) + (p.roles.passenger?.totalRides ?? 0);
  p.memberSince = Math.min(
    ...[p.roles.earner, p.roles.passenger, p.roles.owner]
      .filter(Boolean)
      .map((r) => r.memberSince),
  );
}

const ARCHIVED = [
  'Junel Ramos', 'Jomar Lim', 'Kd Sotto', 'Marlon Uy',
  'Marisol Cruz', 'Rhea Puno', 'Alex Tan', 'Rico D.',
];
const archivedBySlug = {};
for (const name of ARCHIVED) {
  const slug = slugify(name);
  archivedBySlug[slug] = { slug, name, archived: true, roles: {} };
}

const personRef = (roleId) => {
  const row = byId[roleId];
  return personByEmail.get(row.email);
};
const refByName = (name) =>
  [...personByEmail.values()].find((p) => p.name === name) ??
  archivedBySlug[slugify(name)];

const allPeople = [...personByEmail.values(), ...Object.values(archivedBySlug)];

// Demo sign-in is phone + PIN, and demo-presence/demo-activity match people by
// phone. Always emit the provisioned E.164 number, never the display-formatted
// number in users.json, so regenerating this file cannot break demo sign-in.
const SUSPENDED = new Set(['junel-ramos']);
for (const p of allPeople) {
  p.id = profileId(p.slug);
  p.phone = DEMO_PHONES[p.slug];
  if (!p.phone) throw new Error(`no demo phone assigned to ${p.slug}`);
  p.accountStatus = SUSPENDED.has(p.slug) ? 'suspended' : 'active';
}

// ---------- derived driver stats (archived earners, from JSON history) ----------

const driverStats = {};
for (const h of ridesJson.history) {
  if (h.status !== 'Completed' || h.driverName === '—') continue;
  const p = refByName(h.driverName);
  if (!p) continue;
  const s = (driverStats[p.slug] ??= { trips: 0, stars: 0, sum: 0 });
  s.trips += 1;
  s.stars += 1;
  s.sum += h.rating;
}
const ownerRentalCount = {};
for (const v of vehiclesJson.owned) {
  const owner =
    v.id === 'RV001'
      ? archivedBySlug['alex-tan']
      : ['RV002', 'RV003', 'RV008', 'RV013', 'RV014'].includes(v.id)
        ? archivedBySlug['rico-d']
        : personRef('P001');
  const s = (ownerRentalCount[owner.slug] ??= { rentals: 0, sum: 0, n: 0 });
  s.rentals += v.totalRentals;
  s.sum += clampRating(v.rating);
  s.n += 1;
}

// ---------- SQL assembly ----------

const inserts = {
  users: [], profiles: [], roles: [], providers: [], vehicles: [],
  vehicleDocuments: [], applications: [], verificationDocs: [],
  rides: [], rentals: [], serviceRequests: [], serviceItems: [],
  transactions: [], walletAccounts: [], walletTransactions: [],
  notifications: [],
};

const now = iso(ANCHOR);

// 1) auth.users stubs. The real user is never touched.
for (const p of allPeople) {
  const email = p.email ?? null;
  const phone = p.phone ?? null;
  const meta = JSON.stringify({ full_name: p.name, first_name: p.slug });
  inserts.users.push(
    `insert into auth.users (id, aud, role, email, phone, raw_app_meta_data,\n` +
      `  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous, banned_until)\n` +
      `values (${q(p.id)}, 'authenticated', 'authenticated', ${q(email)}, ${q(phone)},\n` +
      `  '{"provider":"email","providers":["email"]}'::jsonb, ${q(meta)}::jsonb,\n` +
      `  ${q(p.createdAt ?? now)}, ${q(now)}, false, false, 'infinity'::timestamptz)\n` +
      `on conflict (id) do nothing;`,
  );
}

// 2) profiles (upsert over whatever handle_new_auth_user created).
for (const p of allPeople) {
  const created = p.memberSince
    ? iso(Date.parse(`${p.memberSince}-01-01T00:00:00Z`))
    : now;
  let rating = 5.0, total = 0;
  if (!p.archived) {
    rating = clampRating(p.rating);
    total = p.roles.passenger?.totalRides ?? p.roles.earner?.totalTrips ?? 0;
    if (p.roles.earner) total = p.roles.earner.totalTrips;
  } else if (driverStats[p.slug]) {
    const s = driverStats[p.slug];
    rating = s.sum / s.stars;
    total = s.trips;
  } else if (ownerRentalCount[p.slug]) {
    const s = ownerRentalCount[p.slug];
    rating = s.sum / s.n;
    total = s.rentals;
  }
  inserts.profiles.push(
    `insert into public.profiles\n` +
      `  (id, full_name, first_name, email, phone, account_status, rating, total_rides, created_at, updated_at)\n` +
      `values (${q(p.id)}, ${q(p.name)}, ${q(p.name.split(' ')[0])}, ${q(p.email ?? null)}, ${q(p.phone)},\n` +
      `  '${p.accountStatus}', ${q(rating.toFixed(2))}, ${q(total)}, ${q(created)}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  full_name = excluded.full_name, first_name = excluded.first_name,\n` +
      `  email = excluded.email, phone = excluded.phone,\n` +
      `  rating = excluded.rating, total_rides = excluded.total_rides,\n` +
      `  created_at = excluded.created_at;`,
  );
}

// 3) user_roles from accounts.json capabilities + archived owner grants.
const ROLE = {
  passenger: 'passenger', earner: 'earner', rider: 'rider',
  vehicleOwner: 'vehicle_owner',
};
function roleRow(person, role, status, approvedAt) {
  inserts.roles.push(
    `insert into public.user_roles (id, profile_id, role, status, approved_at, created_at, updated_at)\n` +
      `values (${q(demoId('user-role', `${person.slug}:${role}`))}, ${q(person.id)}, '${role}', '${status}',\n` +
      `  ${q(approvedAt)}, ${q(now)}, ${q(now)})\n` +
      `on conflict (profile_id, role) do update set\n` +
      `  status = excluded.status, approved_at = excluded.approved_at;`,
  );
}
for (const acc of accounts) {
  const p = personByEmail.get(acc.email);
  const approvedAt = iso(Date.parse('2026-01-15T00:00:00Z') + 0);
  for (const cap of acc.capabilities.approved) {
    roleRow(p, ROLE[cap], 'approved', approvedAt);
  }
  for (const cap of acc.capabilities.eligible) {
    roleRow(p, ROLE[cap], 'pending', null);
  }
}
// Archived people: drivers are approved earners, fleet owners approved
// vehicle_owners (their vehicles/bookings FK-depend on it); the rest are
// passengers only (from the auth trigger).
for (const slug of ['junel-ramos', 'jomar-lim', 'kd-sotto', 'marlon-uy']) {
  roleRow(archivedBySlug[slug], 'earner', 'approved', iso(Date.parse('2026-01-15T00:00:00Z')));
}
for (const slug of ['alex-tan', 'rico-d']) {
  roleRow(archivedBySlug[slug], 'vehicle_owner', 'approved', iso(Date.parse('2026-01-15T00:00:00Z')));
}

// 4) provider_profiles (15: 6 roster earners + 4 archived drivers + 5 owners).
function providerRow(person, type, { rating, trips, capabilities }) {
  inserts.providers.push(
    `insert into public.provider_profiles\n` +
      `  (id, profile_id, provider_type, service_area_id, capabilities, is_available, rating, total_trips, created_at, updated_at)\n` +
      `values (${q(demoId('provider', person.slug))}, ${q(person.id)}, '${type}', ${q(SERVICE_AREA)},\n` +
      `  ${q(capabilities)}, ${q(type === 'earner')}, ${q(rating.toFixed(2))}, ${q(trips)},\n` +
      `  ${q(now)}, ${q(now)})\n` +
      `on conflict (profile_id) do update set\n` +
      `  provider_type = excluded.provider_type, capabilities = excluded.capabilities,\n` +
      `  is_available = excluded.is_available, rating = excluded.rating,\n` +
      `  total_trips = excluded.total_trips;`,
  );
}
for (const e of users.earners) {
  providerRow(personRef(e.id), 'earner', {
    rating: clampRating(e.rating), trips: e.totalTrips,
    capabilities: e.capabilities,
  });
}
for (const slug of ['junel-ramos', 'jomar-lim', 'kd-sotto', 'marlon-uy']) {
  const s = driverStats[slug] ?? { trips: 0, sum: 0, stars: 0 };
  providerRow(archivedBySlug[slug], 'earner', {
    rating: s.stars ? s.sum / s.stars : 5.0, trips: s.trips,
    capabilities: ['rides'],
  });
}
// Owner-type providers: vehicleOwner-approved accounts that are not earners,
// plus the two archived fleet owners. (Jr and Isabella already have a row as
// earners — profile_id is unique — and their fleet is still theirs.)
function ownerProvider(person, { rating, rentals }) {
  providerRow(person, 'vehicle_owner', {
    rating: clampRating(rating ?? 5.0), trips: rentals ?? 0, capabilities: [],
  });
}
for (const acc of accounts) {
  const p = personByEmail.get(acc.email);
  if (!acc.capabilities.approved.includes('vehicleOwner')) continue;
  if (p.roles.earner) continue; // already an earner provider row
  ownerProvider(p, {
    rating: p.roles.owner?.rating, rentals: p.roles.owner?.totalRentals,
  });
}
for (const slug of ['alex-tan', 'rico-d']) {
  const s = ownerRentalCount[slug];
  ownerProvider(archivedBySlug[slug], {
    rating: s.sum / s.n, rentals: s.rentals,
  });
}

// 5) vehicles. Listed|Rented -> active, Maintenance -> inactive.
const V_STATUS = { Listed: 'active', Rented: 'active', Maintenance: 'inactive' };
function vehicleOwner(personKey) {
  if (personKey === 'alex-tan') return archivedBySlug['alex-tan'];
  if (personKey === 'rico-d') return archivedBySlug['rico-d'];
  return personRef('P001');
}
for (const v of vehiclesJson.owned) {
  const owner =
    v.id === 'RV001'
      ? vehicleOwner('alex-tan')
      : ['RV002', 'RV003', 'RV008', 'RV013', 'RV014'].includes(v.id)
        ? vehicleOwner('rico-d')
        : vehicleOwner('jr');
  const area = v.id === 'RV005' ? null : SERVICE_AREA; // duplicate plate NGD 6612
  inserts.vehicles.push(
    `insert into public.vehicles\n` +
      `  (id, owner_profile_id, service_area_id, name, vehicle_type, category, plate_number,\n` +
      `   price_per_day_centavos, status, rating, total_rentals, created_at, updated_at)\n` +
      `values (${q(demoId('vehicle', v.id))}, ${q(owner.id)}, ${q(area)}, ${q(v.name)}, ${q(v.type)},\n` +
      `  ${q(v.category)}, ${q(v.plate)}, ${q(money(v.pricePerDay))}, '${V_STATUS[v.status]}',\n` +
      `  ${q(clampRating(v.rating).toFixed(2))}, ${q(v.totalRentals)}, ${q(now)}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  owner_profile_id = excluded.owner_profile_id, service_area_id = excluded.service_area_id,\n` +
      `  name = excluded.name, vehicle_type = excluded.vehicle_type, category = excluded.category,\n` +
      `  plate_number = excluded.plate_number,\n` +
      `  price_per_day_centavos = excluded.price_per_day_centavos, status = excluded.status,\n` +
      `  rating = excluded.rating, total_rentals = excluded.total_rentals;`,
  );
}
const vehicleIdByName = {};
for (const v of vehiclesJson.owned) vehicleIdByName[v.name] = demoId('vehicle', v.id);

// 6) vehicle_documents: the five verified papers ride on RV005, Jr's one
// listed (active, in-area) tricycle-class bike — the fleet's demo vehicle.
const RV005 = demoId('vehicle', 'RV005');
const docExpiry = {
  doc1: '2028-01-14', doc2: '2027-03-30', doc3: '2026-12-05',
  doc4: '2027-08-12', doc5: '2027-02-01',
};
for (const d of vehiclesJson.documents) {
  const expires = docExpiry[d.id];
  const issued = new Date(Date.parse(`${expires}T00:00:00Z`) - 365 * D)
    .toISOString()
    .slice(0, 10);
  inserts.vehicleDocuments.push(
    `insert into public.vehicle_documents\n` +
      `  (id, vehicle_id, document_type, document_number, issued_at, expires_at,\n` +
      `   status, reviewed_at, created_at, updated_at)\n` +
      `values (${q(demoId('vehicle-doc', d.id))}, ${q(RV005)}, ${q(d.title)}, ${q(d.number)},\n` +
      `  ${q(issued)}, ${q(expires)}, 'approved', ${q('2026-09-01T09:00:00+00:00')}, ${q(now)}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  vehicle_id = excluded.vehicle_id, document_type = excluded.document_type,\n` +
      `  document_number = excluded.document_number, issued_at = excluded.issued_at,\n` +
      `  expires_at = excluded.expires_at, status = excluded.status,\n` +
      `  reviewed_at = excluded.reviewed_at;`,
  );
}

// 7) verification applications + documents from applications.json.
const CAP_BY_ID = { orcr: 'orcr', insurance: 'insurance', permit: 'permit', dl: 'dl' };
for (const app of applicationsJson) {
  const acc = accounts.find((a) => a.id === app.accountId);
  const person = personByEmail.get(acc.email);
  const statusMap = {
    approved: 'approved', needsResubmission: 'needs_resubmission', draft: 'draft',
  };
  const dbStatus = statusMap[app.status];
  const decided = app.status === 'approved' ? parseTime(app.reviewedAt) : null;
  inserts.applications.push(
    `insert into public.verification_applications\n` +
      `  (id, profile_id, capability_type, status, submitted_at, reviewed_at, decided_at,\n` +
      `   rejection_reason, created_at, updated_at)\n` +
      `values (${q(demoId('verification-app', app.id))}, ${q(person.id)},\n` +
      `  '${ROLE[app.capability]}', '${dbStatus}',\n` +
      `  ${app.submittedAt ? q(iso(parseTime(app.submittedAt))) : 'null'},\n` +
      `  ${app.reviewedAt ? q(iso(parseTime(app.reviewedAt))) : 'null'},\n` +
      `  ${decided ? q(iso(decided)) : 'null'},\n` +
      `  ${q(app.status === 'needsResubmission' ? app.reviewerNote : null)},\n` +
      `  ${q(now)}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  profile_id = excluded.profile_id, capability_type = excluded.capability_type,\n` +
      `  status = excluded.status, submitted_at = excluded.submitted_at,\n` +
      `  reviewed_at = excluded.reviewed_at, decided_at = excluded.decided_at,\n` +
      `  rejection_reason = excluded.rejection_reason;`,
  );
  for (const d of app.documents) {
    let docStatus = 'pending', reviewed = null, reason = null;
    if (app.status === 'approved' && d.uploaded) {
      docStatus = 'approved';
      reviewed = iso(parseTime(app.reviewedAt));
    } else if (app.status === 'needsResubmission') {
      if (d.id === 'insurance' && d.uploaded) {
        docStatus = 'rejected';
        reviewed = iso(parseTime(app.reviewedAt));
        reason = 'Motor insurance policy is expired.';
      }
    }
    inserts.verificationDocs.push(
      `insert into public.verification_documents\n` +
        `  (id, application_id, document_type, label, storage_path, is_required, status,\n` +
        `   reviewed_at, rejection_reason, created_at, updated_at)\n` +
        `values (${q(demoId('verification-doc', `${app.id}:${d.id}`))},\n` +
        `  ${q(demoId('verification-app', app.id))}, ${q(CAP_BY_ID[d.id] ?? d.id)}, ${q(d.label)},\n` +
        `  ${d.uploaded ? q(`demo-verification/${person.slug}/${d.id}.pdf`) : 'null'},\n` +
        `  ${q(d.required)}, '${docStatus}', ${q(reviewed)}, ${q(reason)}, ${q(now)}, ${q(now)})\n` +
        `on conflict (id) do update set\n` +
        `  application_id = excluded.application_id, document_type = excluded.document_type,\n` +
        `  label = excluded.label, storage_path = excluded.storage_path,\n` +
        `  is_required = excluded.is_required, status = excluded.status,\n` +
        `  reviewed_at = excluded.reviewed_at, rejection_reason = excluded.rejection_reason;`,
    );
  }
}

// 8) ride_requests: open pool + Jr's history.
const rideRows = [];
for (const r of ridesJson.requests) {
  const passenger = personRef(r.passengerId);
  const requested = parseRelative(r.requestedAt);
  rideRows.push(
    `insert into public.ride_requests\n` +
      `  (id, passenger_id, rider_id, service_area_id, status,\n` +
      `   pickup_address, pickup_barangay_id, pickup_purok_id,\n` +
      `   dropoff_address, dropoff_barangay_id, dropoff_purok_id,\n` +
      `   distance_km, eta_minutes, fare_centavos, platform_fee_centavos,\n` +
      `   payment_method, note, requested_at, created_at, updated_at)\n` +
      `values (${q(demoId('ride', r.id))}, ${q(passenger.id)}, null, ${q(SERVICE_AREA)},\n` +
      `  'awaiting_acceptance', ${q(r.pickup)}, ${q(fkBarangay(r.pickupBarangay))},\n` +
      `  ${q(fkPurok(r.pickupBarangay, r.pickupPurok))},\n` +
      `  ${q(r.dropoff)}, ${q(fkBarangay(r.dropoffBarangay))},\n` +
      `  ${q(fkPurok(r.dropoffBarangay, r.dropoffPurok))},\n` +
      `  ${q(r.distanceKm.toFixed(2))}, ${q(r.etaMinutes)}, ${q(money(r.fare))}, 0,\n` +
      `  'cash', ${q(cashNote(r.paymentMethod, r.note))},\n` +
      `  ${q(iso(requested))}, ${q(iso(requested))}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  passenger_id = excluded.passenger_id, status = excluded.status,\n` +
      `  pickup_address = excluded.pickup_address, pickup_barangay_id = excluded.pickup_barangay_id,\n` +
      `  pickup_purok_id = excluded.pickup_purok_id, dropoff_address = excluded.dropoff_address,\n` +
      `  dropoff_barangay_id = excluded.dropoff_barangay_id, dropoff_purok_id = excluded.dropoff_purok_id,\n` +
      `  distance_km = excluded.distance_km, eta_minutes = excluded.eta_minutes,\n` +
      `  fare_centavos = excluded.fare_centavos, platform_fee_centavos = excluded.platform_fee_centavos,\n` +
      `  payment_method = excluded.payment_method, note = excluded.note,\n` +
      `  requested_at = excluded.requested_at;`,
  );
}

// history route "A → B": pickup barangay parsed from the A side.
function historyPickup(route) {
  const from = route.split('→')[0].trim();
  const m = from.match(/^Purok\s+(\d+),\s*(.+)$/i);
  if (m) return { barangay: m[2], purok: `Purok ${m[1]}` };
  return { barangay: from, purok: null };
}
const CITY_PROPER = barangayId('Bagong Lungsod (Poblacion)');
const jr = personRef('P001');
const historyRides = {};
for (const h of ridesJson.history) {
  const completed = parseTime(h.completedAt);
  const hasDriver = h.status === 'Completed' && h.driverName !== '—';
  const rider = hasDriver ? refByName(h.driverName) : null;
  const from = historyPickup(h.route);
  const to = h.route.split('→')[1]?.trim() ?? h.route;
  const toBarangay = fkBarangay(to);
  historyRides[h.id] = { completed, fare: money(h.fare), passenger: jr, rider };
  rideRows.push(
    `insert into public.ride_requests\n` +
      `  (id, passenger_id, rider_id, service_area_id, status, pickup_address, pickup_barangay_id,\n` +
      `   dropoff_address, dropoff_barangay_id, distance_km, eta_minutes, fare_centavos,\n` +
      `   platform_fee_centavos, payment_method, requested_at, accepted_at, started_at,\n` +
      `   completed_at, cancelled_at, created_at, updated_at)\n` +
      `values (${q(demoId('ride', h.id))}, ${q(jr.id)}, ${q(rider?.id ?? null)}, ${q(SERVICE_AREA)},\n` +
      `  '${h.status === 'Completed' ? 'completed' : 'cancelled'}',\n` +
      `  ${q(h.route)}, ${q(fkBarangay(from.barangay) ?? CITY_PROPER)}, ${q(to)}, ${q(toBarangay)},\n` +
      `  0, 0, ${q(money(h.fare))}, 0, 'cash',\n` +
      `  ${q(iso(completed - 40 * M))},\n` +
      `  ${hasDriver ? q(iso(completed - 30 * M)) : 'null'},\n` +
      `  ${h.status === 'Completed' ? q(iso(completed - 15 * M)) : 'null'},\n` +
      `  ${h.status === 'Completed' ? q(iso(completed)) : 'null'},\n` +
      `  ${h.status === 'Cancelled' ? q(iso(completed)) : 'null'},\n` +
      `  ${q(iso(completed - 40 * M))}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  passenger_id = excluded.passenger_id, rider_id = excluded.rider_id,\n` +
      `  status = excluded.status, pickup_address = excluded.pickup_address,\n` +
      `  pickup_barangay_id = excluded.pickup_barangay_id, dropoff_address = excluded.dropoff_address,\n` +
      `  dropoff_barangay_id = excluded.dropoff_barangay_id, fare_centavos = excluded.fare_centavos,\n` +
      `  requested_at = excluded.requested_at, accepted_at = excluded.accepted_at,\n` +
      `  started_at = excluded.started_at, completed_at = excluded.completed_at,\n` +
      `  cancelled_at = excluded.cancelled_at;`,
  );
}
inserts.rides = rideRows;

// 9) rental_bookings: Jr's completed history + the fleet's booking requests.
const rentalRows = [];
const rentalHistory = {};
for (const h of rentalsJson.history) {
  const start = parseTime(h.startAt), end = parseTime(h.endAt);
  const vehicle = vehiclesJson.owned.find((v) => v.name === h.vehicleName);
  const vid = demoId('vehicle', vehicle.id);
  const owner =
    vehicle.id === 'RV001'
      ? archivedBySlug['alex-tan']
      : ['RV002', 'RV003', 'RV008', 'RV013', 'RV014'].includes(vehicle.id)
        ? archivedBySlug['rico-d']
        : jr;
  // FK requires owner_id to be the vehicle's real owner; the JSON ownerName is
  // display text only (rnh8 shows why: same car, two names across entries).
  rentalHistory[h.id] = { fare: money(h.totalFare), passenger: jr, owner, end };
  rentalRows.push(
    `insert into public.rental_bookings\n` +
      `  (id, renter_id, owner_id, vehicle_id, service_area_id, status, start_at, end_at,\n` +
      `   duration_hours, pickup_location, total_fare_centavos, platform_fee_centavos,\n` +
      `   payment_method, accepted_at, started_at, returned_at, completed_at, created_at, updated_at)\n` +
      `values (${q(demoId('rental', h.id))}, ${q(jr.id)}, ${q(owner.id)}, ${q(vid)}, ${q(SERVICE_AREA)},\n` +
      `  'completed', ${q(iso(start))}, ${q(iso(end))},\n` +
      `  ${q(Math.max(1, Math.round((end - start) / H)))}, ${q(h.vehicleName)},\n` +
      `  ${q(money(h.totalFare))}, 0, 'cash',\n` +
      `  ${q(iso(start - 2 * H))}, ${q(iso(start))}, ${q(iso(end))}, ${q(iso(end))},\n` +
      `  ${q(iso(start - 2 * H))}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  renter_id = excluded.renter_id, owner_id = excluded.owner_id,\n` +
      `  vehicle_id = excluded.vehicle_id, status = excluded.status,\n` +
      `  start_at = excluded.start_at, end_at = excluded.end_at,\n` +
      `  duration_hours = excluded.duration_hours, pickup_location = excluded.pickup_location,\n` +
      `  total_fare_centavos = excluded.total_fare_centavos,\n` +
      `  accepted_at = excluded.accepted_at, started_at = excluded.started_at,\n` +
      `  returned_at = excluded.returned_at, completed_at = excluded.completed_at;`,
  );
}
for (const b of vehiclesJson.bookingRequests) {
  const vehicle = vehiclesJson.owned.find((v) => v.id === b.vehicleId);
  const owner =
    b.vehicleId === 'RV001'
      ? archivedBySlug['alex-tan']
      : ['RV002', 'RV003', 'RV008', 'RV013', 'RV014'].includes(b.vehicleId)
        ? archivedBySlug['rico-d']
        : jr;
  const renter = refByName(b.renterName);
  const start = parseTime(b.startAt), end = parseTime(b.endAt);
  const status = b.status === 'Pending' ? 'requested' : 'accepted';
  rentalRows.push(
    `insert into public.rental_bookings\n` +
      `  (id, renter_id, owner_id, vehicle_id, service_area_id, status, start_at, end_at,\n` +
      `   duration_hours, pickup_location, total_fare_centavos, platform_fee_centavos,\n` +
      `   payment_method, accepted_at, created_at, updated_at)\n` +
      `values (${q(demoId('rental', b.id))}, ${q(renter.id)}, ${q(owner.id)},\n` +
      `  ${q(demoId('vehicle', b.vehicleId))}, ${q(SERVICE_AREA)}, '${status}',\n` +
      `  ${q(iso(start))}, ${q(iso(end))}, ${q(Math.max(1, Math.round((end - start) / H)))},\n` +
      `  ${q(vehicle.name)}, ${q(money(b.totalFare))}, 0, 'cash',\n` +
      `  ${status === 'accepted' ? q(iso(start - 2 * H)) : 'null'}, ${q(iso(start - 2 * H))}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  renter_id = excluded.renter_id, owner_id = excluded.owner_id,\n` +
      `  vehicle_id = excluded.vehicle_id, status = excluded.status,\n` +
      `  start_at = excluded.start_at, end_at = excluded.end_at,\n` +
      `  duration_hours = excluded.duration_hours, pickup_location = excluded.pickup_location,\n` +
      `  total_fare_centavos = excluded.total_fare_centavos, accepted_at = excluded.accepted_at;`,
  );
}
inserts.rentals = rentalRows;

// 10) Pasuyo service_requests (+items).
const PASUYO_STATUS = {
  posted: 'available', accepted: 'accepted', delivering: 'delivering',
  purchasing: 'at_pickup', completed: 'delivered', cancelled: 'cancelled',
};
const PASUYO_CATEGORY = {
  food: 'food_delivery', foodDelivery: 'food_delivery',
};
const pasuyoRows = [];
const pasuyoHistory = {};
for (const t of pasuyoJson.tasks) {
  const customer = personRef(t.customerId);
  const helper = t.helperId ? personRef(t.helperId) : null;
  const requested = parseTime(t.requestedAtIso ?? t.requestedAt);
  const status = PASUYO_STATUS[t.status];
  const accepted = ['accepted', 'at_pickup', 'delivering', 'delivered'].includes(status)
    ? iso(requested + 30 * M) : null;
  const pickedUp = ['delivering', 'delivered'].includes(status)
    ? iso(requested + 90 * M) : null;
  const delivered = status === 'delivered' ? iso(requested + 2 * H) : null;
  const cancelled = status === 'cancelled' ? iso(requested + 1 * H) : null;
  const category = PASUYO_CATEGORY[t.category] ?? t.category;
  if (status === 'delivered') {
    pasuyoHistory[t.id] = {
      fare: money(t.budget), passenger: customer, provider: helper, at: requested + 2 * H,
    };
  }
  pasuyoRows.push(
    `insert into public.service_requests\n` +
      `  (id, customer_id, provider_id, service_area_id, category, status, title, description,\n` +
      `   pickup_address, pickup_barangay_id, pickup_purok_id,\n` +
      `   dropoff_address, dropoff_barangay_id, dropoff_purok_id,\n` +
      `   budget_centavos, quoted_fee_centavos, platform_fee_centavos, payment_method,\n` +
      `   requested_at, accepted_at, picked_up_at, delivered_at, cancelled_at,\n` +
      `   created_at, updated_at)\n` +
      `values (${q(demoId('pasuyo', t.id))}, ${q(customer.id)}, ${q(helper?.id ?? null)},\n` +
      `  ${q(SERVICE_AREA)}, '${category}', '${status}', ${q(t.title)}, ${q(t.note || null)},\n` +
      `  ${q(t.pickup)}, ${q(fkBarangay(t.pickupBarangay))}, ${q(fkPurok(t.pickupBarangay, t.pickupPurok))},\n` +
      `  ${q(t.dropoff)}, ${q(fkBarangay(t.dropoffBarangay))}, ${q(fkPurok(t.dropoffBarangay, t.dropoffPurok))},\n` +
      `  ${q(money(t.budget))}, ${q(money(t.budget))}, 0, 'cash',\n` +
      `  ${q(iso(requested))}, ${q(accepted)}, ${q(pickedUp)}, ${q(delivered)}, ${q(cancelled)},\n` +
      `  ${q(iso(requested))}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  customer_id = excluded.customer_id, provider_id = excluded.provider_id,\n` +
      `  category = excluded.category, status = excluded.status, title = excluded.title,\n` +
      `  description = excluded.description, pickup_address = excluded.pickup_address,\n` +
      `  pickup_barangay_id = excluded.pickup_barangay_id, pickup_purok_id = excluded.pickup_purok_id,\n` +
      `  dropoff_address = excluded.dropoff_address, dropoff_barangay_id = excluded.dropoff_barangay_id,\n` +
      `  dropoff_purok_id = excluded.dropoff_purok_id, budget_centavos = excluded.budget_centavos,\n` +
      `  quoted_fee_centavos = excluded.quoted_fee_centavos, requested_at = excluded.requested_at,\n` +
      `  accepted_at = excluded.accepted_at, picked_up_at = excluded.picked_up_at,\n` +
      `  delivered_at = excluded.delivered_at, cancelled_at = excluded.cancelled_at;`,
  );
  for (let i = 0; i < t.items.length; i += 1) {
    const raw = t.items[i];
    let m = raw.match(/^(\d+)x\s+(.*)$/);
    const name = m ? m[2] : raw;
    const qty = m ? Number(m[1]) : 1;
    inserts.serviceItems.push(
      `insert into public.service_request_items\n` +
        `  (id, service_request_id, name, quantity, created_at, updated_at)\n` +
        `values (${q(demoId('pasuyo-item', `${t.id}:${i}`))}, ${q(demoId('pasuyo', t.id))},\n` +
        `  ${q(name)}, ${q(qty)}, ${q(iso(requested))}, ${q(now)})\n` +
        `on conflict (id) do update set\n` +
        `  service_request_id = excluded.service_request_id, name = excluded.name,\n` +
        `  quantity = excluded.quantity;`,
    );
  }
}
inserts.serviceRequests = pasuyoRows;

// 11) service_transactions: one zero-fee settlement per completed ride,
// rental and delivered Pasuyo. fare = provider_payout, fee = revenue = 0.
function txRow(kind, key, serviceCol, serviceId, customer, provider, fare, settled) {
  inserts.transactions.push(
    `insert into public.service_transactions\n` +
      `  (id, service_type, ${serviceCol}, customer_id, provider_id, currency,\n` +
      `   fare_centavos, platform_fee_centavos, customer_pays_centavos,\n` +
      `   provider_payout_centavos, platform_revenue_centavos, payment_method,\n` +
      `   status, settled_at, created_at, updated_at)\n` +
      `values (${q(demoId('service-tx', `${kind}:${key}`))}, '${kind}', ${q(serviceId)},\n` +
      `  ${q(customer.id)}, ${q(provider.id)}, 'PHP',\n` +
      `  ${q(fare)}, 0, ${q(fare)}, ${q(fare)}, 0, 'cash',\n` +
      `  'completed', ${q(iso(settled))}, ${q(iso(settled))}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  customer_id = excluded.customer_id, provider_id = excluded.provider_id,\n` +
      `  fare_centavos = excluded.fare_centavos, settled_at = excluded.settled_at;`,
  );
}
for (const h of ridesJson.history) {
  if (h.status !== 'Completed' || h.driverName === '—') continue;
  const r = historyRides[h.id];
  txRow('ride', h.id, 'ride_id', demoId('ride', h.id), r.passenger, r.rider, r.fare, r.completed);
}
for (const [id, r] of Object.entries(rentalHistory)) {
  txRow('rental', id, 'rental_id', demoId('rental', id), r.passenger, r.owner, r.fare, r.end);
}
for (const [id, t] of Object.entries(pasuyoHistory)) {
  txRow('pasuyo', id, 'service_request_id', demoId('pasuyo', id), t.passenger, t.provider, t.fare, t.at);
}

// 12) wallets + reconciliation.
const ROLE_WALLET = { passenger: 'passenger', earner: 'earner', owner: 'provider' };
const TX_TYPE = {
  topup: 'top_up', credit: 'earning', payout: 'payout', debit: 'adjustment',
};
for (const w of walletsJson.wallets) {
  const person = personRef(w.userId);
  const accType = ROLE_WALLET[w.role];
  const walletKey = `${person.slug}:${accType}`;
  const walletId = demoId('wallet', walletKey);
  const txs = w.transactions
    .map((t) => ({ ...t, at: parseTime(t.createdAt) }))
    .sort((a, b) => a.at - b.at);
  const signed = txs.map((t) =>
    t.type === 'payout' || t.type === 'debit' ? -money(t.amount) : money(t.amount),
  );
  const net = signed.reduce((s, v) => s + v, 0);
  let running = 0, minCum = 0;
  for (const v of signed) { running += v; minCum = Math.min(minCum, running); }
  const balance = money(w.balance);
  const opening = Math.max(0, balance - net, -minCum);
  const finalAdj = balance - (opening + net);

  inserts.walletAccounts.push(
    `insert into public.wallet_accounts\n` +
      `  (id, profile_id, account_type, currency, balance_centavos, is_active, created_at, updated_at)\n` +
      `values (${q(walletId)}, ${q(person.id)}, '${accType}', 'PHP', ${q(balance)}, true,\n` +
      `  ${q(now)}, ${q(now)})\n` +
      `on conflict (id) do update set\n` +
      `  profile_id = excluded.profile_id, account_type = excluded.account_type,\n` +
      `  balance_centavos = excluded.balance_centavos;`,
  );

  const ledger = [];
  if (opening > 0) {
    ledger.push({
      key: 'opening', type: 'adjustment', direction: 'credit', amount: opening,
      at: txs.length ? txs[0].at - 1 : ANCHOR - D,
      description: 'Demo opening balance (seed import reconciliation).',
    });
  }
  txs.forEach((t, i) => {
    ledger.push({
      key: t.id, type: TX_TYPE[t.type],
      direction: t.type === 'payout' || t.type === 'debit' ? 'debit' : 'credit',
      amount: money(t.amount), at: t.at, description: t.title,
    });
  });
  if (finalAdj !== 0) {
    ledger.push({
      key: 'final', type: 'adjustment',
      direction: finalAdj > 0 ? 'credit' : 'debit',
      amount: Math.abs(finalAdj),
      at: ANCHOR,
      description: 'Demo reconciliation adjustment (seed import).',
    });
  }
  let bal = 0;
  for (const row of ledger) {
    bal += row.direction === 'credit' ? row.amount : -row.amount;
    inserts.walletTransactions.push(
      `insert into public.wallet_transactions\n` +
        `  (id, wallet_account_id, transaction_type, direction, amount_centavos,\n` +
        `   balance_after_centavos, description, created_at)\n` +
        `values (${q(demoId('wallet-tx', `${walletKey}:${row.key}`))}, ${q(walletId)},\n` +
        `  '${row.type}', '${row.direction}', ${q(row.amount)}, ${q(bal)},\n` +
        `  ${q(row.description)}, ${q(iso(row.at))})\n` +
        `on conflict (id) do update set\n` +
        `  wallet_account_id = excluded.wallet_account_id,\n` +
        `  transaction_type = excluded.transaction_type, direction = excluded.direction,\n` +
        `  amount_centavos = excluded.amount_centavos,\n` +
        `  balance_after_centavos = excluded.balance_after_centavos,\n` +
        `  description = excluded.description, created_at = excluded.created_at;`,
    );
  }
  if (bal !== balance) {
    throw new Error(
      `wallet ${walletKey} does not reconcile: ledger ${bal} vs ${balance}`,
    );
  }
}

// 13) notifications, keyed by person (P and R lists merge onto one profile).
for (const [roleId, list] of Object.entries(users.notifications)) {
  const person = personRef(roleId);
  for (const n of list) {
    const created = parseRelative(n.time);
    inserts.notifications.push(
      `insert into public.notifications\n` +
        `  (id, profile_id, notification_type, title, body, data, read_at, created_at)\n` +
        `values (${q(demoId('notification', n.id))}, ${q(person.id)}, '${n.type}',\n` +
        `  ${q(n.title)}, ${q(n.body)}, ${q(JSON.stringify({ seed_id: n.id }))}::jsonb,\n` +
        `  ${n.read ? q(iso(created + 2 * H)) : 'null'}, ${q(iso(created))})\n` +
        `on conflict (id) do update set\n` +
        `  profile_id = excluded.profile_id, notification_type = excluded.notification_type,\n` +
        `  title = excluded.title, body = excluded.body, data = excluded.data,\n` +
        `  read_at = excluded.read_at, created_at = excluded.created_at;`,
    );
  }
}

// ---------- emit ----------

const sections = [
  ['-- Demo auth.users stubs (no passwords, login permanently banned)', inserts.users],
  ['-- Profiles (one row per person; upsert over the auth trigger rows)', inserts.profiles],
  ['-- user_roles from accounts.json capabilities', inserts.roles],
  ['-- provider_profiles (10 earners + 5 vehicle owners)', inserts.providers],
  ['-- vehicles (Listed/Rented -> active, Maintenance -> inactive)', inserts.vehicles],
  ['-- vehicle_documents (Jr RV005 papers)', inserts.vehicleDocuments],
  ['-- verification applications + documents', inserts.applications, inserts.verificationDocs],
  ['-- ride_requests (open pool + history)', inserts.rides],
  ['-- rental_bookings (history + fleet booking requests)', inserts.rentals],
  ['-- Pasuyo service_requests + items', inserts.serviceRequests, inserts.serviceItems],
  ['-- service_transactions (zero platform fee settlements)', inserts.transactions],
  ['-- wallet_accounts', inserts.walletAccounts],
  ['-- wallet_transactions (reconciled ledgers)', inserts.walletTransactions],
  ['-- notifications', inserts.notifications],
];

const header = `-- SurGo DEMO DATA — generated by supabase/tools/gen_demo_data.mjs. DO NOT EDIT BY HAND.
--
-- Source: assets/db/*.json, mapped to the existing Postgres schema.
-- Applied through the Supabase MCP execute_sql tool (service role). This file
-- is NOT a migration, is NOT part of supabase/tests, and must never be
-- db-pushed. It is idempotent: every statement upserts on a deterministic
-- md5('surgo:demo:...')::uuid primary key.
--
-- Guarantees: no pricing_policies rows, platform fees are 0, cash only
-- (original non-cash methods preserved in notes), the real auth user is not
-- referenced, and demo auth.users rows cannot sign in (banned_until infinity).
--
-- Intentionally unmapped from JSON: config.json (pricing is gated),
-- paymentMethods, emergencyContacts, favorites, accountSettings, savedPlaces,
-- earnings.json aggregates (derivable from the wallet ledger), and the rides
-- history star ratings (ride_ratings needs rater/ratee pairing the seed does
-- not carry).


begin;

`;

const body = sections
  .map(([title, ...lists]) => {
    const t = title.replace(/^--\s*/, '');
    return `\n-- ${'='.repeat(76)}\n-- ${t}\n-- ${'='.repeat(76)}\n\n` +
      lists.flat().join('\n\n') + '\n';
  })
  .join('');

const out = `${header}${body}\ncommit;\n`;
const outPath = path.join(supabaseDir, 'demo-data.sql');
fs.writeFileSync(outPath, out);

const counts = {
  profiles: inserts.profiles.length,
  providers: inserts.providers.length,
  vehicles: inserts.vehicles.length,
  vehicle_documents: inserts.vehicleDocuments.length,
  applications: inserts.applications.length,
  verification_documents: inserts.verificationDocs.length,
  ride_requests: inserts.rides.length,
  rental_bookings: inserts.rentals.length,
  service_requests: inserts.serviceRequests.length,
  service_request_items: inserts.serviceItems.length,
  service_transactions: inserts.transactions.length,
  wallet_accounts: inserts.walletAccounts.length,
  wallet_transactions: inserts.walletTransactions.length,
  notifications: inserts.notifications.length,
};
console.log(JSON.stringify(counts, null, 2));
console.log(`wrote ${outPath} (${out.length} bytes)`);
