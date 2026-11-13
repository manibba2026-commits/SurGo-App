/**
 * Shape of the Supabase Send SMS hook payload:
 * `{ "user": { "phone": "+639175124809", ... }, "sms": { "otp": "123456" } }`
 *
 * Newer Auth versions also put the destination in `sms.phone`. That field is
 * the one to trust: for a phone change it holds the new number while
 * `user.phone` is still the old one, and for a first-time phone link
 * `user.phone` is null. Only the two fields this function needs are read;
 * everything else is ignored so the payload can evolve without breaking
 * delivery.
 */

export interface SmsHookPayload {
  phone: string;
  otp: string;
}

function nonemptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

export function extractSmsHookPayload(value: unknown): SmsHookPayload | null {
  if (value === null || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  const user = record.user;
  const sms = record.sms;
  if (user === null || typeof user !== 'object') return null;
  if (sms === null || typeof sms !== 'object') return null;

  const smsRecord = sms as Record<string, unknown>;
  const userRecord = user as Record<string, unknown>;
  const phone = nonemptyString(smsRecord.phone)
    ? smsRecord.phone
    : nonemptyString(userRecord.phone)
    ? userRecord.phone
    : null;
  const otp = smsRecord.otp;
  if (phone === null || typeof otp !== 'string') return null;

  const trimmedOtp = otp.trim();
  if (!trimmedOtp) return null;

  return { phone: phone.trim(), otp: trimmedOtp };
}
