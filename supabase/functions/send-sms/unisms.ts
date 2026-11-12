/** Legacy UniSMS template adapter. Acceptance is not handset delivery. */
export const UNISMS_ENDPOINT =
  'https://uni.apistd.com/?action=sms.message.send';

export interface UniSmsConfig {
  accessKeyId: string;
  accessKeySecret?: string;
  /** An approved UniSMS sender signature, not the HMAC query signature. */
  signature: string;
  templateId: string;
  codeVariable?: string;
  /** Supported values: hmac (default), simple (explicit opt-in only). */
  authMode?: string;
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
  if (!config || !nonempty(config.accessKeyId) ||
      !nonempty(config.signature) || !nonempty(config.templateId) ||
      !nonempty(config.codeVariable ?? 'code')) {
    return false;
  }
  const mode = config.authMode ?? 'hmac';
  return mode === 'simple' ||
    (mode === 'hmac' && nonempty(config.accessKeySecret));
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function zero(value: unknown): boolean {
  return value === 0 || value === '0';
}

function validId(value: unknown): boolean {
  return nonempty(value) ||
    (typeof value === 'number' && Number.isSafeInteger(value) && value > 0);
}

const ACCEPTED_STATUSES = new Set(['sent', 'accepted', 'queued', 'pending']);

function entryAccepted(value: unknown): boolean {
  const entry = record(value);
  return entry !== null && validId(entry.id) &&
    typeof entry.status === 'string' &&
    ACCEPTED_STATUSES.has(entry.status.toLowerCase()) &&
    (entry.code === undefined || zero(entry.code)) && entry.success !== false;
}

function bodyAccepted(value: unknown): boolean {
  const envelope = record(value);
  if (!envelope || !zero(envelope.code)) return false;
  // Legacy unisms@0.0.6 returns data.messages; also accept messageIds responses.
  const data = envelope.data === undefined ? envelope : record(envelope.data);
  if (!data) return false;
  const hasIds = data.messageIds !== undefined;
  const hasMessages = data.messages !== undefined;
  // Never let IDs mask an explicitly failed, unknown or malformed entry.
  if (hasIds && (!Array.isArray(data.messageIds) ||
      data.messageIds.length === 0 || !data.messageIds.every(validId))) {
    return false;
  }
  if (hasMessages && (!Array.isArray(data.messages) ||
      data.messages.length === 0 || !data.messages.every(entryAccepted))) {
    return false;
  }
  return hasIds || hasMessages;
}

async function authenticatedUrl(options: UniSmsConfig): Promise<string> {
  const url = new URL(UNISMS_ENDPOINT);
  url.searchParams.set('accessKeyId', options.accessKeyId);
  if ((options.authMode ?? 'hmac') === 'hmac') {
    url.searchParams.set('algorithm', 'hmac-sha256');
    url.searchParams.set('timestamp', String(Date.now()));
    url.searchParams.set('nonce', crypto.randomUUID().replaceAll('-', ''));
    // Matches uni-sdk@0.0.8: sort raw keys, encode values, then sign (no body).
    const canonical = [...url.searchParams.entries()]
      .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
      .join('&');
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(options.accessKeySecret!),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const digest = new Uint8Array(await crypto.subtle.sign(
      'HMAC', key, new TextEncoder().encode(canonical),
    ));
    url.searchParams.set('signature', btoa(String.fromCharCode(...digest)));
  }
  return url.toString();
}

export async function sendUniSms(
  number: string,
  otp: string,
  options: UniSmsSendOptions,
): Promise<UniSmsSendResult> {
  if (!isUniSmsConfigured(options)) {
    return { ok: false, reason: 'not_configured' };
  }
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
      const url = await authenticatedUrl(options);
      if (controller.signal.aborted) return { ok: false, reason: 'timeout' };
      response = await (options.fetchImpl ?? fetch)(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({
          to: `+${number}`,
          signature: options.signature,
          templateId: options.templateId,
          templateData: { [options.codeVariable ?? 'code']: otp },
        }),
        signal: controller.signal,
        // Do not forward query credentials or repeat the POST on redirects.
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
