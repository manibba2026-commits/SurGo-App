/**
 * Minimal Semaphore v4 client. Only the four documented fields are sent.
 * Response bodies are never logged or echoed; callers get a coarse result.
 */

export const SEMAPHORE_ENDPOINT =
  'https://api.semaphore.co/api/v4/messages';

export type SemaphoreSendResult =
  | { ok: true }
  | {
      ok: false;
      reason: 'http_error' | 'network_error' | 'rejected' | 'invalid_response';
      status?: number;
    };

export interface SemaphoreSendOptions {
  apiKey: string;
  senderName?: string;
  fetchImpl?: typeof fetch;
  /**
   * Supabase gives the whole HTTP hook 5 seconds, including edge cold start
   * and network. Keep this well below that budget.
   */
  timeoutMs?: number;
  /** Injectable timer functions for tests. */
  setTimeoutImpl?: (handler: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimeoutImpl?: (timer: ReturnType<typeof setTimeout>) => void;
}

const DEFAULT_TIMEOUT_MS = 2000;

/**
 * Semaphore's documented synchronous statuses. `Failed` and `Refunded` are
 * delivery failures; anything unknown is also treated as a failure so the hook
 * never reports success for a response it does not understand.
 */
const ACCEPTED_STATUSES = new Set(['queued', 'pending', 'sent']);

function entryAccepted(entry: unknown): boolean {
  if (entry === null || typeof entry !== 'object') return false;
  const record = entry as Record<string, unknown>;
  if (record.message_id === undefined || record.message_id === null) {
    return false;
  }
  const status = String(record.status ?? '').toLowerCase();
  return ACCEPTED_STATUSES.has(status);
}

function bodyAccepted(parsed: unknown): boolean {
  if (Array.isArray(parsed)) {
    return parsed.length > 0 && parsed.every(entryAccepted);
  }
  return entryAccepted(parsed);
}

export async function sendSemaphoreSms(
  number: string,
  message: string,
  options: SemaphoreSendOptions,
): Promise<SemaphoreSendResult> {
  const form = new URLSearchParams();
  form.set('apikey', options.apiKey);
  form.set('number', number);
  form.set('message', message);
  if (options.senderName) {
    form.set('sendername', options.senderName);
  }

  const fetchImpl = options.fetchImpl ?? fetch;
  const setTimer = options.setTimeoutImpl ?? setTimeout;
  const clearTimer = options.clearTimeoutImpl ?? clearTimeout;
  const controller = new AbortController();
  const budget = Number.isFinite(options.timeoutMs) && options.timeoutMs! > 0
    ? Math.min(options.timeoutMs!, DEFAULT_TIMEOUT_MS)
    : DEFAULT_TIMEOUT_MS;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<SemaphoreSendResult>((resolve) => {
    timer = setTimer(() => {
      resolve({ ok: false, reason: 'network_error' });
      controller.abort();
    }, budget);
  });

  const send = async (): Promise<SemaphoreSendResult> => {
    let response: Response;
    try {
      response = await fetchImpl(SEMAPHORE_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form.toString(),
        signal: controller.signal,
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

    return { ok: true };
  };

  try {
    // One deadline covers fetch and body parsing, even if abort is ignored.
    return await Promise.race([send(), deadline]);
  } finally {
    if (timer !== undefined) clearTimer(timer);
  }
}
