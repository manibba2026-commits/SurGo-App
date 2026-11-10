/**
 * Philippine mobile normalization for demo sign-in.
 *
 * People type 09170000001, +63 917 000 0001, 639170000001 or 0063917...; the
 * database stores E.164. Real-user OTP sign-in is untouched and still uses
 * Supabase Auth's own phone handling.
 */

const PH_NATIONAL = /^9\d{9}$/;

/** Returns +639XXXXXXXXX, or null when the input is not a PH mobile. */
export function normalizePhilippineNumber(input: unknown): string | null {
  if (typeof input !== 'string') return null;

  let digits = input.replace(/[^\d+]/g, '');
  if (digits.startsWith('+')) digits = digits.slice(1);
  if (digits.startsWith('0063')) {
    digits = digits.slice(4);
  } else if (digits.startsWith('63')) {
    digits = digits.slice(2);
  } else if (digits.startsWith('0')) {
    digits = digits.slice(1);
  }

  return PH_NATIONAL.test(digits) ? `+63${digits}` : null;
}
