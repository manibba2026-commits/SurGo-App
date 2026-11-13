/**
 * UniSMS (unismsapi.com) one-shot client.
 *
 * The provider takes the finished message, not a template: the hook owns the
 * OTP text and only the sender name is configuration. Authentication is HTTP
 * Basic with the API key as the username and an empty password, so the key
 * never appears in a URL or a log line.
 */

export const UNISMS_ENDPOINT = 'https://unismsapi.com/api/sms';
export const UNISMS_DEFAULT_SENDER_ID = 'UniSMS';

export interface UniSmsConfig {
  apiKey: string;
  /** Approved alphanumeric sender name; the console default is `UniSMS`. */
  senderId?: string;
}

export interface UniSmsSendOptions extends UniSmsConfig {
  fetchImpl?: typeof fetch;
  /** May shorten, but never extend, the two-second provider budget. */
  timeoutMs?: number;
}

export type UniSmsSendResult =
  | { ok: true }
  | {
      ok: false;
      reason:
        | 'not_configured'
        | 'http_error'
        | 'network_error'
        | 'timeout'
        | 'rejected'
        | 'invalid_response';
      status?: number;
    };

function nonempty(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

export function isUniSmsConfigured(
  config: UniSmsConfig | undefined,
): config is UniSmsConfig {
  return Boolean(config && nonempty(config.apiKey));
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

/** Statuses uniSMS returns once it has accepted a message. */
const ACCEPTED_STATUSES = new Set([
  'pending', 'queued', 'sent', 'accepted', 'success',
]);

/**
 * The documented success body is `{ message: { status, reference_id,
 * fail_reason, ... } }`. Anything without that envelope is treated as a
 * rejection so a proxy error page can never look like a delivery.
 */
function bodyAccepted(value: unknown): boolean {
  const envelope = record(value);
  if (!envelope) return false;
  const message = record(envelope.message);
  if (!message) return false;
  if (message.success === false) return false;
  if (message.fail_reason !== undefined && message.fail_reason !== null &&
      message.fail_reason !== '') {
    return false;
  }
  const status = typeof message.status === 'string'
    ? message.status.toLowerCase()
    : '';
  return ACCEPTED_STATUSES.has(status);
}

export async function sendUniSms(
  number: string,
  message: string,
  options: UniSmsSendOptions,
): Promise<UniSmsSendResult> {
  if (!isUniSmsConfigured(options)) {
    return { ok: false, reason: 'not_configured' };
  }
  const senderId = nonempty(options.senderId)
    ? options.senderId.trim()
    : UNISMS_DEFAULT_SENDER_ID;
  const authorization = `Basic ${btoa(`${options.apiKey.trim()}:`)}`;

  const controller = new AbortController();
  const budget = Number.isFinite(options.timeoutMs) && options.timeoutMs! > 0
    ? Math.min(options.timeoutMs!, 2000)
    : 2000;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<UniSmsSendResult>((resolve) => {
    timer = setTimeout(() => {
      resolve({ ok: false, reason: 'timeout' });
      controller.abort();
    }, budget);
  });

  const send = async (): Promise<UniSmsSendResult> => {
    let response: Response;
    try {
      response = await (options.fetchImpl ?? fetch)(UNISMS_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          Authorization: authorization,
        },
        body: JSON.stringify({
          recipient: `+${number}`,
          content: message,
          sender_id: senderId,
        }),
        signal: controller.signal,
        // Never forward credentials or repeat the POST on redirects.
        redirect: 'error',
      });
    } catch {
      return { ok: false, reason: 'network_error' };
    }
    if (!response.ok) {
      return { ok: false, reason: 'http_error', status: response.status };
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(await response.text());
    } catch {
      return { ok: false, reason: 'invalid_response', status: response.status };
    }
    return bodyAccepted(parsed)
      ? { ok: true }
      : { ok: false, reason: 'rejected', status: response.status };
  };

  try {
    // Abort alone cannot bound a fetch mock or stalled response body.
    return await Promise.race([send(), deadline]);
  } finally {
    clearTimeout(timer);
  }
}
