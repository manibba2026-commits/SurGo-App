import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  ARCHIVED,
  ASSIGNED_DEMO_PHONES,
  E164_PH,
  EMAIL,
  SYNTHETIC_DOMAIN,
  demoPeople,
  generateDemoPins,
  isInsideRepo,
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

test('the 8 people without an email get a reserved-domain address', () => {
  const synthetic = people.filter((p) => p.syntheticEmail);
  assert.deepEqual(
    synthetic.map((p) => p.name).sort(),
    [...ARCHIVED].sort(),
  );
  for (const person of synthetic) {
    assert.ok(person.targetEmail.endsWith(`@${SYNTHETIC_DOMAIN}`));
    assert.match(person.targetEmail, EMAIL);
  }
  const real = people.filter((p) => !p.syntheticEmail);
  assert.equal(real.length, 11);
  for (const person of real) assert.equal(person.targetEmail, person.email);
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
  }
});

test('the 11 seeded numbers are preserved and normalized', () => {
  const preserved = people.filter((p) => !p.phoneAssigned);
  assert.equal(preserved.length, 11);
  assert.deepEqual(
    preserved.map((p) => p.name).sort(),
    ['Jr Derigay', 'Grace Ann Villaflor', 'Nena Villareal', 'Danilo Cruz',
      'Rosalinda Pajo', 'Isabella Dizon', 'Bebot Lim', 'Carlo Mendoza',
      'Danny Reyes', 'Edwin Santillan', 'Marco Villanueva'].sort(),
  );
  for (const person of preserved) {
    assert.equal(normalizePhone(person.phone), person.phone, person.name);
    assert.ok(person.phone.startsWith('+639'), person.name);
  }
});

test('the 8 archived people get the documented assigned numbers', () => {
  const assigned = people.filter((p) => p.phoneAssigned);
  assert.deepEqual(assigned.map((p) => p.name).sort(), [...ARCHIVED].sort());
  for (const person of assigned) {
    assert.equal(person.phone, ASSIGNED_DEMO_PHONES[person.slug], person.name);
  }
  // Assigned numbers are contiguous, ordered by the archived-name sort, and
  // never collide with a preserved number.
  assert.deepEqual(
    assigned.map((p) => p.phone).sort(),
    ['+639170000001', '+639170000002', '+639170000003', '+639170000004',
      '+639170000005', '+639170000006', '+639170000007', '+639170000008'],
  );
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
