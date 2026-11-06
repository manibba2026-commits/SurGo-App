/**
 * Phone helpers for the Send SMS hook.
 *
 * Supabase Auth delivers the recipient in E.164 form (`+639175124809`).
 * Semaphore expects the country code without the leading `+`, so both forms
 * normalize to the same 12-digit `63` + mobile number.
 */

const PH_MOBILE = /^9\d{9}$/;

/**
 * Normalizes a Philippine mobile number to Semaphore's `63XXXXXXXXXX` form.
 *
 * Accepts `+639175124809`, `639175124809`, `09175124809` and spaced or
 * punctuated variants. Returns `null` for anything that is not a PH mobile
 * number so the caller can reject the hook request instead of guessing.
 */
export function normalizePhilippineNumber(input: string): string | null {
  const cleaned = input.trim().replace(/[\s\-().]/g, '');
  if (!/^\+?\d+$/.test(cleaned)) return null;

  let national: string;
  if (cleaned.startsWith('+63')) {
    national = cleaned.slice(3);
  } else if (cleaned.startsWith('63')) {
    national = cleaned.slice(2);
  } else if (cleaned.startsWith('0')) {
    national = cleaned.slice(1);
  } else {
    return null;
  }

  if (!PH_MOBILE.test(national)) return null;
  return `63${national}`;
}

/** Supabase OTPs are numeric; reject anything that could alter the message. */
export function isValidOtp(value: string): boolean {
  return /^\d{4,10}$/.test(value);
}
