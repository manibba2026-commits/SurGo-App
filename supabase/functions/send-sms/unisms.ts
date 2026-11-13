/**
 * UniSMS (unismsapi.com) one-shot client.
 *
 * The provider takes the finished message, not a template: the hook owns the
 * OTP text and only the sender name is configuration. Authentication is HTTP
 * Basic with the API key as the username and an empty password, so the key
 * never appears in a URL or a log line.
 *
 * The send endpoint answers 201 with `status: "pending"` and then settles the
 * message asynchronously. The client therefore waits briefly and reads
 * `GET /sms/:reference_id` so a content rejection or carrier failure is
 * reported to the hook instead of being mistaken for a delivered code.
 */

export const UNISMS_ENDPOINT = 'https://unismsapi.com/api/sms';
export const UNISMS_DEFAULT_SENDER_ID = 'Unisoft';

/** Time from the start of the send to the first status check. */
const STATUS_CHECK_TARGET_MS = 1500;
/** Upper bound for the status request itself. */
const STATUS_TIMEOUT_MS = 800;

export interface UniSmsConfig {
  apiKey: string;
  /** Approved alphanumeric sender name; the console default is `Unisoft`. */
  senderId?: string;
}

export interface UniSmsSendOptions extends UniSmsConfig {
  fetchImpl?: typeof fetch;
  /** May shorten, but never extend, the two-second provider budget. */
  timeoutMs?: number;
  /**
   * Read the provider's delivery status before reporting success. Defaults to
   * true; disable only in tests that do not model the status endpoint.
   */
  verifyDelivery?: boolean;
  /** Wait before the first status check, in ms. Defaults to 1500. */
  statusDelayMs?: number;
  /** Timeout for the status check, in ms. Defaults to 800. */
  statusTimeoutMs?: number;
  /** Injectable clock for tests. */
  now?: () => number;
  /** Injectable sleep for tests. */
  sleepImpl?: (ms: number) => Promise<void>;
  /** Injectable timer functions for tests. */
  setTimeoutImpl?: (handler: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimeoutImpl?: (timer: ReturnType<typeof setTimeout>) => void;
}

export type UniSmsSendResult =
  | { ok: true; referenceId?: string }
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
      /** Provider's coarse failure reason; never the message body or phone. */
      failReason?: string;
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

function referenceIdOf(value: unknown): string | undefined {
  const envelope = record(value);
  const message = envelope ? record(envelope.message) : null;
  const reference = message?.reference_id;
  return typeof reference === 'string' && reference.length > 0
    ? reference
    : undefined;
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Reads the provider's delivery status. Any failure (network, timeout, bad
 * body) is treated as "unknown" so it never turns an accepted send into a
 * false failure.
 */
async function readDeliveryStatus(
  referenceId: string,
  authorization: string,
  options: UniSmsSendOptions,
): Promise<{ status?: string; failReason?: string }> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const setTimer = options.setTimeoutImpl ?? setTimeout;
  const clearTimer = options.clearTimeoutImpl ?? clearTimeout;
  const budget = Number.isFinite(options.statusTimeoutMs) &&
      options.statusTimeoutMs! > 0
    ? options.statusTimeoutMs!
    : STATUS_TIMEOUT_MS;
  const controller = new AbortController();
  const timer = setTimer(() => controller.abort(), budget);
  try {
    const response = await fetchImpl(`${UNISMS_ENDPOINT}/${referenceId}`, {
      method: 'GET',
      headers: { Accept: 'application/json', Authorization: authorization },
      signal: controller.signal,
    });
    if (!response.ok) return {};
    const parsed = JSON.parse(await response.text());
    const message = record(parsed?.message);
    return {
      status: typeof message?.status === 'string'
        ? message.status.toLowerCase()
        : undefined,
      failReason: typeof message?.fail_reason === 'string' &&
          message.fail_reason.length > 0
        ? message.fail_reason
        : undefined,
    };
  } catch {
    return {};
  } finally {
    clearTimer(timer);
  }
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
  const setTimer = options.setTimeoutImpl ?? setTimeout;
  const clearTimer = options.clearTimeoutImpl ?? clearTimeout;
  const budget = Number.isFinite(options.timeoutMs) && options.timeoutMs! > 0
    ? Math.min(options.timeoutMs!, 2000)
    : 2000;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<UniSmsSendResult>((resolve) => {
    timer = setTimer(() => {
      resolve({ ok: false, reason: 'timeout' });
      controller.abort();
    }, budget);
  });

  const startedAt = (options.now ?? Date.now)();

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
    if (!bodyAccepted(parsed)) {
      return { ok: false, reason: 'rejected', status: response.status };
    }
    return { ok: true, referenceId: referenceIdOf(parsed) };
  };

  let accepted: UniSmsSendResult;
  try {
    // Abort alone cannot bound a fetch mock or stalled response body.
    accepted = await Promise.race([send(), deadline]);
  } finally {
    if (timer !== undefined) clearTimer(timer);
  }

  if (!accepted.ok) return accepted;
  if (options.verifyDelivery === false || !accepted.referenceId) return accepted;

  // Settle the asynchronous part of the delivery, but keep the whole call
  // well inside Supabase's five-second hook budget: the status check starts
  // about 1.5s after the send began and is capped at 800ms.
  const elapsed = (options.now ?? Date.now)() - startedAt;
  const target = Number.isFinite(options.statusDelayMs) &&
      options.statusDelayMs! >= 0
    ? options.statusDelayMs!
    : STATUS_CHECK_TARGET_MS;
  const wait = Math.max(0, target - elapsed);
  if (wait > 0) {
    await (options.sleepImpl ?? defaultSleep)(wait);
  }

  const status = await readDeliveryStatus(
    accepted.referenceId,
    authorization,
    options,
  );
  if (status.status === 'failed' || status.failReason) {
    return {
      ok: false,
      reason: 'rejected',
      status: 200,
      failReason: status.failReason,
    };
  }
  return accepted;
}
