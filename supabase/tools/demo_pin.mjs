// Node-side PBKDF2 helpers for demo PINs.
//
// Must stay byte-compatible with supabase/functions/demo-login/pin.ts and the
// format check in migration 20261111140000_demo_pin_access.sql:
//   pbkdf2-sha256$iterations$salt$hash   (base64url, no padding)

import { pbkdf2Sync, randomBytes, timingSafeEqual } from 'node:crypto';

export const PIN_ITERATIONS = 210_000;

export const PIN_HASH_FORMAT =
  /^pbkdf2-sha256\$[0-9]{6}\$[A-Za-z0-9_-]{20,64}\$[A-Za-z0-9_-]{40,64}$/;

/** Hashes a PIN with a fresh 16-byte salt and 210,000 PBKDF2-SHA256 rounds. */
export function hashDemoPin(pin, iterations = PIN_ITERATIONS) {
  if (!/^\d{6}$/.test(pin)) throw new Error('PIN must be six digits');
  const salt = randomBytes(16);
  const hash = pbkdf2Sync(pin, salt, iterations, 32, 'sha256');
  return `pbkdf2-sha256$${iterations}$${salt.toString('base64url')}$${hash.toString('base64url')}`;
}

/** Verifies a PIN against an encoded hash. Never throws on malformed input. */
export function verifyDemoPin(pin, encoded) {
  const parts = String(encoded).split('$');
  if (parts.length !== 4 || parts[0] !== 'pbkdf2-sha256') return false;
  const iterations = Number(parts[1]);
  if (!Number.isInteger(iterations) || iterations < 100_000 || iterations > 1_000_000) {
    return false;
  }
  let salt;
  let expected;
  try {
    salt = Buffer.from(parts[2], 'base64url');
    expected = Buffer.from(parts[3], 'base64url');
  } catch {
    return false;
  }
  if (salt.length < 8 || expected.length < 16) return false;
  const actual = pbkdf2Sync(pin, salt, iterations, expected.length, 'sha256');
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
