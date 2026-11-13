import assert from 'node:assert/strict';
import test from 'node:test';

import { handleSendSms } from './handler.ts';
import { SEMAPHORE_ENDPOINT } from './semaphore.ts';
import { base64Secret, signWebhook, webhookHeaders } from './test_support.ts';

const KEY = base64Secret();
const HOOK_SECRET = `v1,whsec_${KEY}`;
const NOW = 1_700_000_000;

interface FetchCall {
  url: string;
  init: RequestInit;
}

function payload(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    user: { id: 'user_1', phone: '+639175124809' },
    sms: { otp: '654321' },
    ...overrides,
  });
}

async function signedRequest(
  body: string,
  options: { key?: string; timestamp?: number } = {},
): Promise<Request> {
  const timestamp = `${options.timestamp ?? NOW}`;
  const signature = await signWebhook(
    options.key ?? KEY,
    'msg_1',
    timestamp,
    body,
  );
  return new Request('https://example.test/functions/v1/send-sms', {
    method: 'POST',
    headers: webhookHeaders(signature, 'msg_1', timestamp),
    body,
  });
}

function captureFetch(
  calls: FetchCall[],
  response: () => Response,
): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return response();
  }) as typeof fetch;
}

function semaphoreOk(): Response {
  return new Response(JSON.stringify([{ message_id: 42, status: 'Queued' }]), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

test('delivers a signed hook to Semaphore', async () => {
  const calls: FetchCall[] = [];
  const request = await signedRequest(payload());
  const response = await handleSendSms(request, {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    semaphoreSenderName: 'SurGo',
    nowSeconds: NOW,
    fetchImpl: captureFetch(calls, semaphoreOk),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, SEMAPHORE_ENDPOINT);
  assert.equal(calls[0].init.method, 'POST');

  const form = new URLSearchParams(String(calls[0].init.body));
  assert.equal(form.get('apikey'), 'sem_test_key');
  assert.equal(form.get('number'), '639175124809');
  assert.equal(
    form.get('message'),
    'Your SurGo OTP code is 654321. Please do not share. Expires in 1 minute.',
  );
  assert.equal(form.get('sendername'), 'SurGo');
});

test('omits sendername when it is not configured', async () => {
  const calls: FetchCall[] = [];
  const response = await handleSendSms(await signedRequest(payload()), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: captureFetch(calls, semaphoreOk),
  });

  assert.equal(response.status, 200);
  const form = new URLSearchParams(String(calls[0].init.body));
  assert.equal(form.get('sendername'), null);
});

test('rejects unsigned or tampered requests before delivery', async () => {
  const calls: FetchCall[] = [];
  const request = await signedRequest(payload(), { key: btoa('wrong-secret') });
  const response = await handleSendSms(request, {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: captureFetch(calls, semaphoreOk),
  });

  assert.equal(response.status, 401);
  assert.equal(calls.length, 0);
});

test('rejects stale hook requests', async () => {
  const calls: FetchCall[] = [];
  const response = await handleSendSms(
    await signedRequest(payload(), { timestamp: NOW - 301 }),
    {
      hookSecret: HOOK_SECRET,
      semaphoreApiKey: 'sem_test_key',
      nowSeconds: NOW,
      fetchImpl: captureFetch(calls, semaphoreOk),
    },
  );

  assert.equal(response.status, 401);
  assert.equal(calls.length, 0);
});

test('rejects non-PH phone numbers and non-numeric OTPs', async () => {
  const cases = [
    payload({ user: { phone: '+14155552671' } }),
    payload({ sms: { otp: '12ab56' } }),
    payload({ sms: {} }),
  ];

  for (const body of cases) {
    const calls: FetchCall[] = [];
    const response = await handleSendSms(await signedRequest(body), {
      hookSecret: HOOK_SECRET,
      semaphoreApiKey: 'sem_test_key',
      nowSeconds: NOW,
      fetchImpl: captureFetch(calls, semaphoreOk),
    });
    assert.equal(response.status, 200, body);
    const json = await response.json() as {
      error: { http_code: number; message: string };
    };
    assert.equal(json.error.http_code, 400, body);
    assert.equal(typeof json.error.message, 'string');
    assert.equal(calls.length, 0, body);
  }
});

test('rejects malformed JSON after a valid signature', async () => {
  const response = await handleSendSms(await signedRequest('not-json'), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    error: {
      http_code: 400,
      message: 'That request could not be processed. Try again.',
    },
  });
});

test('returns a hook error object when Semaphore rejects the request', async (t) => {
  t.mock.method(console, 'error', () => {});
  const response = await handleSendSms(await signedRequest(payload()), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: captureFetch(
      [],
      () => new Response('{"message":"Invalid API key"}', { status: 400 }),
    ),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    error: {
      http_code: 422,
      message: 'We could not send the SurGo code to this number. Try again in a moment.',
    },
  });
});

test('returns a hook error object when Semaphore reports a failed message', async (t) => {
  t.mock.method(console, 'error', () => {});
  const response = await handleSendSms(await signedRequest(payload()), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: captureFetch(
      [],
      () =>
        new Response(JSON.stringify([{ message_id: 7, status: 'Failed' }]), {
          status: 200,
        }),
    ),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    error: {
      http_code: 422,
      message: 'We could not send the SurGo code to this number. Try again in a moment.',
    },
  });
});

test('returns a hook error object on a network failure', async (t) => {
  t.mock.method(console, 'error', () => {});
  const response = await handleSendSms(await signedRequest(payload()), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: (async () => {
      throw new Error('network down');
    }) as typeof fetch,
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    error: {
      http_code: 422,
      message: 'We could not send the SurGo code to this number. Try again in a moment.',
    },
  });
});

test('returns a hook error object when secrets are missing', async () => {
  const response = await handleSendSms(await signedRequest(payload()), {
    hookSecret: '',
    semaphoreApiKey: '',
    nowSeconds: NOW,
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    error: {
      http_code: 500,
      message: 'Sign-in is temporarily unavailable. Please try again.',
    },
  });
});

test('rejects oversized bodies', async () => {
  const response = await handleSendSms(
    await signedRequest(payload({ note: 'x'.repeat(40 * 1024) })),
    {
      hookSecret: HOOK_SECRET,
      semaphoreApiKey: 'sem_test_key',
      nowSeconds: NOW,
    },
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    error: {
      http_code: 413,
      message: 'That request is too large. Try again.',
    },
  });
});

test('rejects non-POST requests', async () => {
  const response = await handleSendSms(
    new Request('https://example.test/functions/v1/send-sms'),
    { hookSecret: HOOK_SECRET, semaphoreApiKey: 'sem_test_key' },
  );
  assert.equal(response.status, 405);
});

test('never sends an OTP to a demo number in any spelling', async (t) => {
  t.mock.method(console, 'error', () => {});
  const forms = [
    '+639170000001',
    '639170000001',
    '09170000001',
  ];

  for (const phone of forms) {
    const calls: FetchCall[] = [];
    const response = await handleSendSms(
      await signedRequest(payload({ user: { phone } })),
      {
        hookSecret: HOOK_SECRET,
        semaphoreApiKey: 'sem_test_key',
        nowSeconds: NOW,
        fetchImpl: captureFetch(calls, semaphoreOk),
      },
    );
    assert.equal(response.status, 200, phone);
    assert.deepEqual(await response.json(), {
      error: {
        http_code: 403,
        message: 'This number cannot receive a SurGo code.',
      },
    });
    assert.equal(calls.length, 0, phone);
  }
});

test('prefers sms.phone over user.phone for the destination', async () => {
  const calls: FetchCall[] = [];
  const body = JSON.stringify({
    user: { id: 'user_1', phone: '+639175124809' },
    sms: { otp: '654321', phone: '+639175124810' },
  });
  const response = await handleSendSms(await signedRequest(body), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: captureFetch(calls, semaphoreOk),
  });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  const form = new URLSearchParams(String(calls[0].init.body));
  assert.equal(form.get('number'), '639175124810');
});

test('delivers a first-time phone link when user.phone is null', async () => {
  const calls: FetchCall[] = [];
  const body = JSON.stringify({
    user: { id: 'user_1', phone: null },
    sms: { otp: '654321', phone: '639175124810' },
  });
  const response = await handleSendSms(await signedRequest(body), {
    hookSecret: HOOK_SECRET,
    semaphoreApiKey: 'sem_test_key',
    nowSeconds: NOW,
    fetchImpl: captureFetch(calls, semaphoreOk),
  });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  const form = new URLSearchParams(String(calls[0].init.body));
  assert.equal(form.get('number'), '639175124810');
});

test('a real number next to the demo block still delivers', async () => {
  const calls: FetchCall[] = [];
  const response = await handleSendSms(
    await signedRequest(payload({ user: { phone: '+639175124810' } })),
    {
      hookSecret: HOOK_SECRET,
      semaphoreApiKey: 'sem_test_key',
      nowSeconds: NOW,
      fetchImpl: captureFetch(calls, semaphoreOk),
    },
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
});
