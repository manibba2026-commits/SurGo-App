/**
 * PBKDF2-SHA256 encoding for demo PINs.
 *
 * Format: pbkdf2-sha256$iterations$salt$hash, with salt and hash in unpadded
 * base64url. The same format is produced by supabase/tools/demo_pin.mjs; a
 * change here must be mirrored there and in migration 20261111140000.
 */

export const PIN_ITERATIONS = 210_000;
const SALT_BYTES = 16;
const HASH_BYTES = 32;

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') +
    '='.repeat((4 - (value.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

async function derive(
  pin: string,
  salt: Uint8Array,
  iterations: number,
  length: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(pin),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    key,
    length * 8,
  );
  return new Uint8Array(bits);
}

/** Hash a PIN with a fresh random salt. Used by the provisioning tool. */
export async function hashPin(
  pin: string,
  iterations = PIN_ITERATIONS,
): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const hash = await derive(pin, salt, iterations, HASH_BYTES);
  return `pbkdf2-sha256$${iterations}$${toBase64Url(salt)}$${toBase64Url(hash)}`;
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** Verify a PIN against an encoded hash. Returns false for any malformed input. */
export async function verifyPin(
  pin: string,
  encoded: string,
): Promise<boolean> {
  const parts = encoded.split('$');
  if (parts.length !== 4 || parts[0] !== 'pbkdf2-sha256') return false;

  const iterations = Number(parts[1]);
  if (!Number.isInteger(iterations) || iterations < 100_000 || iterations > 1_000_000) {
    return false;
  }

  const salt = fromBase64Url(parts[2]);
  const expected = fromBase64Url(parts[3]);
  if (!salt || !expected || expected.length < 16) return false;

  const actual = await derive(pin, salt, iterations, expected.length);
  return timingSafeEqual(actual, expected);
}

/**
 * A real hash of an unrelated PIN. Verifying against it when the phone is
 * unknown keeps the failure path as slow as a wrong PIN, so response timing
 * does not reveal whether an account exists.
 */
export const DUMMY_PIN_HASH =
  'pbkdf2-sha256$210000$MDEyMzQ1Njc4OWFiY2RlZg$gDbvbNvgS4fe9C4gO4iHHRYKsvqO1vH42zbfoCvcmtc';
