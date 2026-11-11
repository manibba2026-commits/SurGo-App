import { buildOtpMessage } from './message.ts';
import { isDemoNumber } from './demo_numbers.ts';
import { extractSmsHookPayload } from './payload.ts';
import { isValidOtp, normalizePhilippineNumber } from './phone.ts';
import { sendSemaphoreSms } from './semaphore.ts';
import { verifyStandardWebhook } from './webhook.ts';

export interface SendSmsHandlerConfig {
  hookSecret: string;
  semaphoreApiKey: string;
  semaphoreSenderName?: string;
  fetchImpl?: typeof fetch;
  nowSeconds?: number;
  timeoutMs?: number;
}

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const MAX_BODY_BYTES = 32 * 1024;

/**
 * Handles one Send SMS hook request. Supabase Auth owns OTP generation,
 * expiry and verification; this function only verifies the webhook signature
 * and hands the already-generated code to Semaphore.
 */
export async function handleSendSms(
  request: Request,
  config: SendSmsHandlerConfig,
): Promise<Response> {
  if (request.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }
  if (!config.hookSecret || !config.semaphoreApiKey) {
    return json({ error: 'not_configured' }, 500);
  }

  const rawBody = await request.text();
  if (!rawBody) {
    return json({ error: 'invalid_payload' }, 400);
  }
  if (rawBody.length > MAX_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }

  const verified = await verifyStandardWebhook(rawBody, request.headers, {
    secret: config.hookSecret,
    nowSeconds: config.nowSeconds,
  });
  if (!verified.ok) {
    return json({ error: 'invalid_signature' }, 401);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json({ error: 'invalid_payload' }, 400);
  }

  const extracted = extractSmsHookPayload(payload);
  if (!extracted) {
    return json({ error: 'invalid_payload' }, 400);
  }

  const number = normalizePhilippineNumber(extracted.phone);
  if (!number) {
    return json({ error: 'invalid_phone' }, 400);
  }
  // Demo identities sign in with a PIN; their phone must never receive an OTP.
  if (isDemoNumber(number)) {
    console.error('send-sms: refused a demo number');
    return json({ error: 'demo_number_blocked' }, 403);
  }
  if (!isValidOtp(extracted.otp)) {
    return json({ error: 'invalid_otp' }, 400);
  }

  const delivered = await sendSemaphoreSms(
    number,
    buildOtpMessage(extracted.otp),
    {
      apiKey: config.semaphoreApiKey,
      senderName: config.semaphoreSenderName,
      fetchImpl: config.fetchImpl,
      timeoutMs: config.timeoutMs,
    },
  );

  if (!delivered.ok) {
    // Reason and HTTP status are safe to log; the payload, phone and OTP are not.
    console.error('send-sms: Semaphore delivery failed', {
      reason: delivered.reason,
      status: delivered.status,
    });
    return json({ error: 'sms_delivery_failed' }, 502);
  }

  return json({ ok: true }, 200);
}
