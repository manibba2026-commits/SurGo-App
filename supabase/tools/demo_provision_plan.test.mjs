import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  DEMO_PHONES,
  E164_PH,
  EMAIL,
  SYNTHETIC_DOMAIN,
  demoPeople,
  generateDemoPins,
  isInsideRepo,
  isSyncedFolder,
  normalizePhone,
  profileId,
  toLocalPhone,
} from './demo_provision_plan.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const users = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'assets', 'db', 'users.json'), 'utf8'),
);

const people = demoPeople(users);

test('the demo set is exactly the 19 seeded people, one per human', () => {
  assert.equal(people.length, 19);
  assert.equal(new Set(people.map((p) => p.id)).size, 19);
  assert.equal(new Set(people.map((p) => p.targetEmail)).size, 19);
  // Shared role rows for one human (Jr Derigay is a passenger, earner and
  // owner) must not become three accounts.
  assert.equal(people.filter((p) => p.slug === 'jr-derigay').length, 1);
});

test('ids match the deterministic ids supabase/demo-data.sql seeded', () => {
  // These literals are read from demo-data.sql; a change in the derivation
  // would silently provision the wrong rows without this check.
  const expected = {
    'jr-derigay': '19aa7137-bdef-93ed-1610-0139c328cf0e',
    'grace-ann-villaflor': '2db06d3b-a51d-e5a7-f9d7-2b459fc14694',
    'nena-villareal': '6e8dbe00-d9da-bfe0-71bc-0922bcaf5a79',
    'kd-sotto': '55b85eed-6ef1-a9b9-cf5d-8fec8cbfb508',
    'rico-d': '47ca4ef2-7325-73b2-2c37-d802e3595b2e',
  };
  for (const [slug, id] of Object.entries(expected)) {
    assert.equal(profileId(slug), id, slug);
    assert.equal(people.find((p) => p.slug === slug)?.id, id, slug);
  }
});

test('every demo account gets a reserved .test email, never a seeded one', () => {
  const seededEmails = new Set(
    ['passengers', 'earners', 'owners']
      .flatMap((group) => users[group])
      .map((row) => String(row.email ?? '').trim().toLowerCase())
      .filter(Boolean),
  );
  for (const person of people) {
    assert.equal(person.syntheticEmail, true, person.name);
    assert.ok(
      person.targetEmail.endsWith(`@${SYNTHETIC_DOMAIN}`),
      person.targetEmail,
    );
    assert.match(person.targetEmail, EMAIL, person.name);
    assert.equal(
      person.targetEmail,
      `${person.slug.replace(/-/g, '.')}@${SYNTHETIC_DOMAIN}`,
      person.name,
    );
    assert.equal(seededEmails.has(person.targetEmail), false, person.name);
  }
});

test('every target email is lowercase and unique', () => {
  for (const person of people) {
    assert.equal(person.targetEmail, person.targetEmail.toLowerCase());
  }
  assert.equal(
    new Set(people.map((p) => p.targetEmail)).size,
    people.length,
  );
});

test('every demo account gets a unique PH mobile number in E.164', () => {
  assert.equal(new Set(people.map((p) => p.phone)).size, 19);
  for (const person of people) {
    assert.match(person.phone, E164_PH, person.name);
    assert.equal(normalizePhone(person.phone), person.phone, person.name);
    assert.equal(person.phoneAssigned, true, person.name);
    assert.equal(person.phone, DEMO_PHONES[person.slug], person.name);
  }
});

test('the 19 assigned numbers are the documented sequential block', () => {
  assert.equal(Object.keys(DEMO_PHONES).length, 19);
  assert.deepEqual(
    people.map((p) => p.phone).sort(),
    Array.from({ length: 19 }, (_, i) => `+639170000${String(i + 1).padStart(3, '0')}`),
  );
});

test('no seeded number is retained for any demo person', () => {
  const seededNumbers = new Set(
    ['passengers', 'earners', 'owners']
      .flatMap((group) => users[group])
      .map((row) => normalizePhone(row.phone))
      .filter(Boolean),
  );
  for (const person of people) {
    assert.equal(seededNumbers.has(person.phone), false, person.name);
  }
});

test('normalizePhone accepts 09, +639, 639 and 0063 forms', () => {
  const cases = [
    ['09171234567', '+639171234567'],
    ['9171234567', '+639171234567'],
    ['+639171234567', '+639171234567'],
    ['639171234567', '+639171234567'],
    ['00639171234567', '+639171234567'],
    ['0917 123 4567', '+639171234567'],
    ['+63 917-123-4567', '+639171234567'],
    ['(0917) 123 4567', '+639171234567'],
  ];
  for (const [input, expected] of cases) {
    assert.equal(normalizePhone(input), expected, input);
  }
});

test('normalizePhone rejects non-PH or malformed numbers', () => {
  for (const bad of [
    '', '12345', '08171234567', '091712345678', '+63917123456',
    '+15551234567', '09-1712-3456', null, undefined, 639171234567,
  ]) {
    assert.equal(normalizePhone(bad), null, String(bad));
  }
});

test('toLocalPhone renders the 09 form used in the docs', () => {
  assert.equal(toLocalPhone('+639170000001'), '09170000001');
  assert.equal(toLocalPhone('+639267713390'), '09267713390');
  assert.equal(toLocalPhone('12345'), null);
});

test('generated PINs are unique, 6 digits and never trivial', () => {
  let n = 0;
  const seeded = () => n++ % 1_000_000; // deterministic, injectable
  const pins = generateDemoPins(people, seeded);
  assert.equal(pins.size, 19);
  const values = [...pins.values()];
  assert.equal(new Set(values).size, 19);
  for (const pin of values) {
    assert.match(pin, /^\d{6}$/);
    assert.notEqual(pin, '123456');
    assert.notEqual(pin, '000000');
    assert.ok(!pin.split('').every((d) => d === pin[0]), pin);
  }
  // Every person is covered, keyed by the seeded profile id.
  for (const person of people) assert.ok(pins.has(person.id), person.name);
});

test('a colliding generator still yields unique non-trivial PINs', () => {
  const answers = [123456, 123456, 111111, 424242, 424242, 515151];
  let i = 0;
  const colliding = () => answers[Math.min(i++, answers.length - 1)];
  const pins = generateDemoPins(people.slice(0, 2), colliding);
  const values = [...pins.values()];
  assert.equal(new Set(values).size, 2);
  assert.ok(!values.includes('123456'), 'trivial PINs must be skipped');
  assert.ok(!values.includes('111111'), 'repeated-digit PINs must be skipped');
});

test('credentials may not be written inside the repository', () => {
  assert.equal(isInsideRepo(repoRoot, path.join(repoRoot, 'demo.json')), true);
  assert.equal(
    isInsideRepo(repoRoot, path.join(repoRoot, 'supabase', 'x.json')),
    true,
  );
  assert.equal(isInsideRepo(repoRoot, path.join(repoRoot, '..', 'demo.json')), false);
  assert.equal(isInsideRepo(repoRoot, 'C:\\surgo-demo-credentials\\x.json'), false);
});

test('credentials may not be written into a synced folder', () => {
  assert.equal(isSyncedFolder('C:\\Users\\me\\OneDrive\\pins.json'), true);
  assert.equal(
    isSyncedFolder('C:\\Users\\me\\OneDrive - SurGo\\pins.json'),
    true,
  );
  assert.equal(
    isSyncedFolder('C:\\Users\\me\\Dropbox\\surgo\\pins.json'),
    true,
  );
  assert.equal(
    isSyncedFolder('C:\\Users\\me\\Google Drive\\pins.json'),
    true,
  );
  assert.equal(isSyncedFolder('/Users/me/iCloud Drive/pins.json'), true);
  assert.equal(
    isSyncedFolder('C:\\Users\\me\\surgo-demo-credentials\\pins.json'),
    false,
  );
  assert.equal(isSyncedFolder('/home/me/pins/pins.json'), false);
  // A name that merely contains a sync keyword is not a sync folder.
  assert.equal(isSyncedFolder('C:\\work\\boxing\\pins.json'), false);
});
