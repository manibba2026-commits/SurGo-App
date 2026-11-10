// Pure helpers for provision_demo_accounts.mjs: the 19-person set, the demo
// phone assignment, PIN generation and the credential-path guard. Kept
// separate so a test can cover them without a network call or a hosted write.
//
// Demo sign-in is a Philippine mobile number plus a per-account PIN. No email
// password is ever generated: the addresses exist only to satisfy the auth row
// and the dashboard.

import { createHash, randomInt } from 'node:crypto';
import path from 'node:path';

// The 8 people without an email get one from this reserved .test domain so no
// mail is ever sent to a real address.
export const SYNTHETIC_DOMAIN = 'surgo-demo.test';

// Must match the archived list in gen_demo_data.mjs.
export const ARCHIVED = [
  'Junel Ramos', 'Jomar Lim', 'Kd Sotto', 'Marlon Uy',
  'Marisol Cruz', 'Rhea Puno', 'Alex Tan', 'Rico D.',
];

// Archived people have no phone in assets/db/users.json. These numbers are
// assigned in alphabetical order of ARCHIVED so the mapping is stable and
// reproducible. They sit in the 917-000-00xx block, which no real subscriber
// number occupies here and no seeded profile already uses.
export const ASSIGNED_DEMO_PHONES = {
  'alex-tan': '+639170000001',
  'jomar-lim': '+639170000002',
  'junel-ramos': '+639170000003',
  'kd-sotto': '+639170000004',
  'marisol-cruz': '+639170000005',
  'marlon-uy': '+639170000006',
  'rhea-puno': '+639170000007',
  'rico-d': '+639170000008',
};

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const EMAIL =
  /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$/i;
export const E164_PH = /^\+639\d{9}$/;

const slugify = (name) =>
  name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const uuidFromMd5 = (hex) =>
  `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;

export const profileId = (slug) =>
  uuidFromMd5(createHash('md5').update(`surgo:demo:profile:${slug}`).digest('hex'));

/**
 * Normalize a Philippine mobile number to E.164 (+639XXXXXXXXX).
 *
 * Accepts the forms a person actually types: 09XXXXXXXXX, 9XXXXXXXXX,
 * +639XXXXXXXXX, 639XXXXXXXXX, 00639XXXXXXXXX, and the same with spaces,
 * dashes or parentheses. Returns null when the number is not a valid PH
 * mobile (the national significant number must be 9 followed by 9 digits).
 */
export function normalizePhone(input) {
  if (typeof input !== 'string') return null;
  let digits = input.replace(/[^\d+]/g, '');
  if (digits.startsWith('+')) digits = digits.slice(1);
  if (digits.startsWith('0063')) digits = digits.slice(4);
  else if (digits.startsWith('63')) digits = digits.slice(2);
  else if (digits.startsWith('0')) digits = digits.slice(1);
  if (!/^9\d{9}$/.test(digits)) return null;
  return `+63${digits}`;
}

/** Render an E.164 PH number in the local 09XXXXXXXXX form people dial. */
export function toLocalPhone(e164) {
  const normalized = normalizePhone(e164);
  if (normalized === null) return null;
  return `0${normalized.slice(3)}`;
}

/**
 * One entry per person, deduplicated by slug exactly as gen_demo_data.mjs does,
 * so the 19 ids here are the ids supabase/demo-data.sql seeded.
 *
 * [phone] is always E.164: the seeded number when the person has one, the
 * assigned demo number otherwise. [phoneAssigned] marks the 8 synthetic ones.
 */
export function demoPeople(usersJson) {
  const bySlug = new Map();
  for (const group of [
    usersJson.passengers,
    usersJson.earners,
    usersJson.owners,
  ]) {
    for (const row of group) {
      const slug = slugify(row.name);
      if (!bySlug.has(slug)) {
        bySlug.set(slug, { slug, name: row.name, email: row.email ?? null, phone: row.phone ?? null });
      }
    }
  }
  for (const name of ARCHIVED) {
    const slug = slugify(name);
    bySlug.set(slug, { slug, name, email: null, phone: null });
  }
  return [...bySlug.values()]
    .map((person) => {
      const phone = person.phone
        ? normalizePhone(person.phone)
        : ASSIGNED_DEMO_PHONES[person.slug] ?? null;
      return {
        ...person,
        id: profileId(person.slug),
        targetEmail:
          person.email?.trim().toLowerCase() ||
          `${person.slug.replace(/-/g, '.')}@${SYNTHETIC_DOMAIN}`,
        syntheticEmail: !person.email,
        phone,
        phoneAssigned: !person.phone,
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

// PINs a person would guess first must never be issued, even at random.
const TRIVIAL_PINS = new Set([
  '000000', '111111', '121212', '123123', '123456', '654321',
  '112233', '696969', '131313', '101010', '202020',
]);

const isTrivialPin = (pin) =>
  TRIVIAL_PINS.has(pin) ||
  pin.split('').every((d) => d === pin[0]) ||
  '0123456789'.includes(pin) ||
  '9876543210'.includes(pin);

/**
 * Generate one unique 6-digit PIN per person. [randInt] is injectable so the
 * test can drive a deterministic sequence; production passes node:crypto's
 * randomInt (CSPRNG). The returned Map is keyed by person id.
 */
export function generateDemoPins(people, randInt = randomInt) {
  const pins = new Map();
  const used = new Set();
  for (const person of people) {
    let pin;
    do {
      pin = String(randInt(0, 1_000_000)).padStart(6, '0');
    } while (used.has(pin) || isTrivialPin(pin));
    used.add(pin);
    pins.set(person.id, pin);
  }
  return pins;
}

/** True when [file] resolves inside [repoRoot] and must not hold credentials. */
export function isInsideRepo(repoRoot, file) {
  const rel = path.relative(repoRoot, path.resolve(file));
  return !rel.startsWith('..') && !path.isAbsolute(rel);
}
