import { buildOtpMessage } from './message.ts';
import { isDemoNumber } from './demo_numbers.ts';
import { extractSmsHookPayload } from './payload.ts';
import { isValidOtp, normalizePhilippineNumber } from './phone.ts';
import { sendSemaphoreSms } from './semaphore.ts';
import { isUniSmsConfigured, sendUniSms } from './unisms.ts';
import type { UniSmsConfig } from './unisms.ts';
import { verifyStandardWebhook } from './webhook.ts';

export type SmsProvider = 'semaphore' | 'unisms';

export interface SendSmsHandlerConfig {
  hookSecret: string;
  /** Runtime env value: only SmsProvider values are accepted; omission defaults. */
  smsProvider?: SmsProvider | (string & {});
  semaphoreApiKey?: string;
  semaphoreSenderName?: string;
  unisms?: UniSmsConfig;
  fetchImpl?: typeof fetch;
  nowSeconds?: number;
  timeoutMs?: number;
  /**
   * Read UniSMS's delivery status before reporting success. Defaults to true
   * so an asynchronous content rejection is surfaced instead of pretending
   * the code was delivered.
   */
  verifyDelivery?: boolean;
}

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Supabase Auth only forwards a hook error to the app when the hook answers
 * HTTP 200 with `{ error: { http_code, message } }`. A bare 400/502 is
 * replaced by a generic 500, so every expected failure uses this shape.
 */
function hookError(httpCode: number, message: string): Response {
  return json({ error: { http_code: httpCode, message } }, 200);
}

const MAX_BODY_BYTES = 32 * 1024;

/**
 * Handles one Send SMS hook request. Supabase Auth owns OTP generation,
 * expiry and verification; this function only verifies the signature
 * and hands the already-generated code to the selected provider.
 */
export async function handleSendSms(
  request: Request,
  config: SendSmsHandlerConfig,
): Promise<Response> {
  if (request.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }
  const provider = config.smsProvider ?? 'semaphore';
  const configured = provider === 'semaphore'
    ? Boolean(config.semaphoreApiKey)
    : provider === 'unisms' && isUniSmsConfigured(config.unisms);
  if (!config.hookSecret || !configured) {
    return hookError(
      500,
      'Sign-in is temporarily unavailable. Please try again.',
    );
  }

  const rawBody = await request.text();
  if (!rawBody) {
    return hookError(400, 'That request could not be processed. Try again.');
  }
  if (rawBody.length > MAX_BODY_BYTES) {
    return hookError(413, 'That request is too large. Try again.');
  }

  const verified = await verifyStandardWebhook(rawBody, request.headers, {
    secret: config.hookSecret,
    nowSeconds: config.nowSeconds,
  });
  if (!verified.ok) {
    // Signature failures are configuration errors, not user errors. Keep the
    // 401 so the reason is visible in the function logs.
    return json({ error: 'invalid_signature' }, 401);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return hookError(400, 'That request could not be processed. Try again.');
  }

  const extracted = extractSmsHookPayload(payload);
  if (!extracted) {
    return hookError(400, 'That request could not be processed. Try again.');
  }

  const number = normalizePhilippineNumber(extracted.phone);
  if (!number) {
    return hookError(
      400,
      'Invalid phone number. Enter a valid Philippine mobile number.',
    );
  }
  // Demo identities sign in with a PIN; their phone must never receive an OTP.
  if (isDemoNumber(number)) {
    console.error('send-sms: refused a demo number');
    return hookError(403, 'This number cannot receive a SurGo code.');
  }
  if (!isValidOtp(extracted.otp)) {
    return hookError(400, 'That code could not be sent. Try again.');
  }

  // Exactly one provider call: configuration/rejection never triggers fallback.
  const accepted = provider === 'unisms'
    ? await sendUniSms(number, buildOtpMessage(extracted.otp), {
      ...config.unisms!,
      fetchImpl: config.fetchImpl,
      timeoutMs: config.timeoutMs,
      verifyDelivery: config.verifyDelivery ?? true,
    })
    : await sendSemaphoreSms(number, buildOtpMessage(extracted.otp), {
      apiKey: config.semaphoreApiKey!,
      senderName: config.semaphoreSenderName,
      fetchImpl: config.fetchImpl,
      timeoutMs: config.timeoutMs,
    });

  if (!accepted.ok) {
    // Reason and HTTP status only: provider failure text can echo the message
    // body, which contains the OTP, so it must never reach the logs.
    console.error(`send-sms: ${provider} acceptance failed`, {
      reason: accepted.reason,
      status: accepted.status,
    });
    return hookError(
      422,
      'We could not send the SurGo code to this number. Try again in a moment.',
    );
  }

  // The provider accepted the message. For UniSMS this is backed by a status
  // check; for Semaphore it is the synchronous queue acceptance. Neither is a
  // handset delivery receipt.
  const referenceId = 'referenceId' in accepted
    ? accepted.referenceId
    : undefined;
  if (provider === 'unisms' && referenceId) {
    console.log('send-sms: unisms accepted', { referenceId });
  }
  return json({ ok: true }, 200);
}
