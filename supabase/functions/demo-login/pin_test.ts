import assert from 'node:assert/strict';
import test from 'node:test';

import { PIN_ITERATIONS, hashPin, verifyPin } from './pin.ts';

const SQL_FORMAT =
  /^pbkdf2-sha256\$[0-9]{6}\$[A-Za-z0-9_-]{20,64}\$[A-Za-z0-9_-]{40,64}$/;

test('a hash round-trips and matches the database format', async () => {
  const hash = await hashPin('246810', 100_000);
  assert.match(hash, SQL_FORMAT);
  assert.equal(await verifyPin('246810', hash), true);
  assert.equal(await verifyPin('246811', hash), false);
});

test('the default iteration count is used when none is supplied', async () => {
  const hash = await hashPin('135790');
  assert.ok(hash.startsWith(`pbkdf2-sha256$${PIN_ITERATIONS}$`));
});

test('each hash gets a fresh salt', async () => {
  const a = await hashPin('246810', 100_000);
  const b = await hashPin('246810', 100_000);
  assert.notEqual(a, b);
  assert.equal(await verifyPin('246810', a), true);
  assert.equal(await verifyPin('246810', b), true);
});

test('malformed encodings are rejected without throwing', async () => {
  for (const bad of [
    '',
    'not-a-hash',
    'pbkdf2-sha256$100000$salt$hash',
    'pbkdf2-sha512$100000$MDEyMzQ1Njc4OWFiY2RlZg$MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY',
    'pbkdf2-sha256$abc$MDEyMzQ1Njc4OWFiY2RlZg$MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY',
    'pbkdf2-sha256$99999$MDEyMzQ1Njc4OWFiY2RlZg$MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY',
  ]) {
    assert.equal(await verifyPin('246810', bad), false, bad);
  }
});

test('a differently sized hash does not verify', async () => {
  const hash = await hashPin('246810', 100_000);
  const short = hash.slice(0, hash.lastIndexOf('$') + 10);
  assert.equal(await verifyPin('246810', short), false);
});
