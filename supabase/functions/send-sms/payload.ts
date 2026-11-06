/**
 * Shape of the Supabase Send SMS hook payload:
 * `{ "user": { "phone": "+639175124809", ... }, "sms": { "otp": "123456" } }`
 *
 * Only the two fields this function needs are read; everything else is
 * ignored so the payload can evolve without breaking delivery.
 */

export interface SmsHookPayload {
  phone: string;
  otp: string;
}

export function extractSmsHookPayload(value: unknown): SmsHookPayload | null {
  if (value === null || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  const user = record.user;
  const sms = record.sms;
  if (user === null || typeof user !== 'object') return null;
  if (sms === null || typeof sms !== 'object') return null;

  const phone = (user as Record<string, unknown>).phone;
  const otp = (sms as Record<string, unknown>).otp;
  if (typeof phone !== 'string' || typeof otp !== 'string') return null;

  const trimmedPhone = phone.trim();
  const trimmedOtp = otp.trim();
  if (!trimmedPhone || !trimmedOtp) return null;

  return { phone: trimmedPhone, otp: trimmedOtp };
}
