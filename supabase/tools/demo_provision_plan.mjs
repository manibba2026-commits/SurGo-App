// Pure helpers for provision_demo_accounts.mjs: the 19-person set, the demo
// phone assignment, PIN generation and the credential-path guard. Kept
// separate so a test can cover them without a network call or a hosted write.
//
// Demo sign-in is a Philippine mobile number plus a per-account PIN. No email
// password is ever generated: every address is a reserved .test address that
// cannot receive mail, and demo-login mints sessions server-side.

import { createHash, randomInt } from 'node:crypto';
import path from 'node:path';

// Every demo account gets an address from this reserved .test domain, whether
// or not the seeded row had one. The domain has no MX, so GoTrue's magic-link
// and recovery emails can never reach a real inbox.
export const SYNTHETIC_DOMAIN = 'surgo-demo.test';

// People the seed archived without an email or phone in assets/db/users.json.
// They still need a profile row, so they are added when users.json omits them.
export const ARCHIVED = [
  'Junel Ramos', 'Jomar Lim', 'Kd Sotto', 'Marlon Uy',
  'Marisol Cruz', 'Rhea Puno', 'Alex Tan', 'Rico D.',
];

// No seeded number is reused: ownership of the seed numbers cannot be
// verified, so every person gets a fresh sequential number in the
// 917-000-00xx block. The assignment is keyed by slug (never by list order)
// so it is stable even if users.json is regenerated.
export const DEMO_PHONES = {
  'alex-tan': '+639170000001',
  'bebot-lim': '+639170000002',
  'carlo-mendoza': '+639170000003',
  'danilo-cruz': '+639170000004',
  'danny-reyes': '+639170000005',
  'edwin-santillan': '+639170000006',
  'grace-ann-villaflor': '+639170000007',
  'isabella-dizon': '+639170000008',
  'jomar-lim': '+639170000009',
  'jr-derigay': '+639170000010',
  'junel-ramos': '+639170000011',
  'kd-sotto': '+639170000012',
  'marco-villanueva': '+639170000013',
  'marisol-cruz': '+639170000014',
  'marlon-uy': '+639170000015',
  'nena-villareal': '+639170000016',
  'rhea-puno': '+639170000017',
  'rico-d': '+639170000018',
  'rosalinda-pajo': '+639170000019',
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
 * [phone] is always the assigned E.164 demo number; the seeded numbers are
 * never reused. [targetEmail] is always a reserved .test address. The 8
 * archived people are added when users.json does not carry them.
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
        bySlug.set(slug, {
          slug,
          name: row.name,
          email: row.email ?? null,
          phone: row.phone ?? null,
        });
      }
    }
  }
  for (const name of ARCHIVED) {
    const slug = slugify(name);
    if (!bySlug.has(slug)) {
      bySlug.set(slug, { slug, name, email: null, phone: null });
    }
  }
  return [...bySlug.values()]
    .map((person) => {
      const phone = DEMO_PHONES[person.slug];
      if (!phone) {
        throw new Error(`no demo phone assigned to ${person.slug}`);
      }
      return {
        ...person,
        id: profileId(person.slug),
        targetEmail: `${person.slug.replace(/-/g, '.')}@${SYNTHETIC_DOMAIN}`,
        syntheticEmail: true,
        phone,
        phoneAssigned: true,
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

const SYNCED_FOLDER_NAMES = new Set([
  'onedrive',
  'dropbox',
  'google drive',
  'googledrive',
  'icloud',
  'icloud drive',
  'box',
  'box sync',
  'pcloud',
  'mega',
]);

function isWithin(root, file) {
  const rel = path.relative(path.resolve(root), path.resolve(file));
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/**
 * True when [file] lives in a consumer file-sync folder. Plaintext PINs must
 * not be copied to a vendor cloud just because the folder happens to exist.
 */
export function isSyncedFolder(file) {
  const segments = path.resolve(file)
    .split(/[\\/]+/)
    .filter(Boolean)
    .map((segment) => segment.toLowerCase());
  if (
    segments.some((segment) =>
      SYNCED_FOLDER_NAMES.has(segment) || segment.startsWith('onedrive - ')
    )
  ) {
    return true;
  }
  for (const name of [
    'OneDrive',
    'OneDriveCommercial',
    'OneDriveConsumer',
    'DROPBOX',
    'GOOGLE_DRIVE',
  ]) {
    const root = process.env[name];
    if (root && isWithin(root, file)) return true;
  }
  return false;
}
