import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  PIN_HASH_FORMAT,
  PIN_ITERATIONS,
  hashDemoPin,
  verifyDemoPin,
} from './demo_pin.mjs';
import { verifyPin as verifyEdgePin } from '../functions/demo-login/pin.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const migration = readFileSync(
  path.resolve(here, '..', 'migrations', '20261111140000_demo_pin_access.sql'),
  'utf8',
);

test('the database migration accepts the encoding this tool writes', () => {
  const hash = hashDemoPin('246810', 100_000);
  assert.match(hash, PIN_HASH_FORMAT);
  // The migration's check constraint carries the same expression.
  assert.ok(migration.includes('pbkdf2-sha256\\$[0-9]{6}\\$'));
  assert.ok(migration.includes('[A-Za-z0-9_-]{20,64}'));
});

test('a hash round-trips and rejects the wrong PIN', () => {
  const hash = hashDemoPin('246810', 100_000);
  assert.equal(verifyDemoPin('246810', hash), true);
  assert.equal(verifyDemoPin('246811', hash), false);
});

test('the default iteration count is 210,000', () => {
  assert.ok(hashDemoPin('246810').startsWith(`pbkdf2-sha256$${PIN_ITERATIONS}$`));
});

test('the Edge Function verifier accepts a tool-generated hash', async () => {
  const hash = hashDemoPin('246810', 100_000);
  assert.equal(await verifyEdgePin('246810', hash), true);
  assert.equal(await verifyEdgePin('246811', hash), false);
});

test('malformed input is rejected without throwing', () => {
  for (const bad of [
    '', 'nope', 'pbkdf2-sha256$100000$salt$hash',
    'pbkdf2-sha512$100000$MDEyMzQ1Njc4OWFiY2RlZg$MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY',
  ]) {
    assert.equal(verifyDemoPin('246810', bad), false, bad);
  }
  assert.throws(() => hashDemoPin('12ab'), /six digits/);
});
