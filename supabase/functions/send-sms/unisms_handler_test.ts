import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';

import { handleSendSms } from './handler.ts';
import type { SendSmsHandlerConfig } from './handler.ts';
import { SEMAPHORE_ENDPOINT } from './semaphore.ts';
import { base64Secret, signWebhook, webhookHeaders } from './test_support.ts';

const KEY = base64Secret();
const NOW = 1_700_000_000;
const CONFIG: SendSmsHandlerConfig = {
  hookSecret: `v1,whsec_${KEY}`,
  smsProvider: 'unisms',
  nowSeconds: NOW,
  unisms: {
    accessKeyId: 'uni_test_key',
    accessKeySecret: 'uni_test_secret',
    signature: 'ApprovedTestSender',
    templateId: 'test_login_template',
  },
};

function payload(phone = '+639175124809', otp = '001234'): string {
  return JSON.stringify({ user: { id: 'test_user', phone }, sms: { otp } });
}

async function signedRequest(body = payload(), timestamp = NOW): Promise<Request> {
  const signature = await signWebhook(KEY, 'test_message', String(timestamp), body);
  return new Request('https://example.test/functions/v1/send-sms', {
    method: 'POST', body,
    headers: webhookHeaders(signature, 'test_message', String(timestamp)),
  });
}

function uniOk(): Response {
  return new Response(JSON.stringify({
    code: 0, data: { messages: [{ id: 'test_id', status: 'sent' }] },
  }));
}

test('signed UniSMS hooks preserve Supabase OTPs and normalize PH recipients without Semaphore config', async () => {
  let calls = 0;
  const cases = [
    ['+639175124809', '001234'],
    ['639175124809', '0000'],
    ['09175124809', '0123456789'],
  ];
  for (const [phone, otp] of cases) {
    const response = await handleSendSms(await signedRequest(payload(phone, otp)), {
      ...CONFIG,
      unisms: { ...CONFIG.unisms!, codeVariable: 'otp_code' },
      fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
        calls++;
        const url = new URL(String(input));
        assert.equal(url.origin, 'https://uni.apistd.com');
        assert.equal(url.searchParams.get('action'), 'sms.message.send');
        const signature = url.searchParams.get('signature');
        url.searchParams.delete('signature');
        const canonical = [...url.searchParams].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
          .map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join('&');
        assert.equal(signature, createHmac('sha256', CONFIG.unisms!.accessKeySecret!)
          .update(canonical).digest('base64'));
        assert.deepEqual(JSON.parse(String(init?.body)), {
          to: '+639175124809', signature: CONFIG.unisms!.signature,
          templateId: CONFIG.unisms!.templateId, templateData: { otp_code: otp },
        });
        return uniOk();
      }) as typeof fetch,
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
  }
  assert.equal(calls, cases.length);
});

test('unknown providers and incomplete UniSMS configuration fail closed despite valid Semaphore config', async () => {
  const cases: SendSmsHandlerConfig[] = [
    { ...CONFIG, smsProvider: '' },
    { ...CONFIG, smsProvider: 'unknown' },
    { ...CONFIG, smsProvider: 'UniSMS' },
    { ...CONFIG, hookSecret: '' },
    { ...CONFIG, unisms: undefined },
    ...[
      { accessKeyId: '' }, { signature: '' }, { templateId: '' },
      { accessKeySecret: undefined }, { authMode: 'hmac', accessKeySecret: '' },
      { authMode: '' }, { authMode: 'unknown' }, { codeVariable: '' },
    ].map((override) => ({ ...CONFIG, unisms: { ...CONFIG.unisms!, ...override } })),
  ];
  let calls = 0;
  for (const config of cases) {
    const response = await handleSendSms(await signedRequest(), {
      ...config, semaphoreApiKey: 'sem_test_key',
      fetchImpl: (async () => { calls++; return uniOk(); }) as typeof fetch,
    });
    assert.equal(response.status, 500);
    assert.deepEqual(await response.json(), { error: 'not_configured' });
  }
  assert.equal(calls, 0);
});

test('UniSMS cannot bypass unsigned, tampered, wrongly signed or expired webhook guards', async () => {
  const signed = await signedRequest();
  const wrong = await signWebhook(btoa('wrong-test-secret'), 'test_message', String(NOW), payload());
  const requests = [
    new Request(signed.url, { method: 'POST', body: payload() }),
    new Request(signed.url, { method: 'POST', headers: signed.headers, body: payload('+639175124809', '999999') }),
    new Request(signed.url, { method: 'POST', headers: signed.headers, body: payload('+639175124810') }),
    new Request(signed.url, { method: 'POST', headers: webhookHeaders(wrong, 'test_message', String(NOW)), body: payload() }),
    await signedRequest(payload(), NOW - 301),
  ];
  let calls = 0;
  for (const request of requests) {
    const response = await handleSendSms(request, {
      ...CONFIG, fetchImpl: (async () => { calls++; return uniOk(); }) as typeof fetch,
    });
    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: 'invalid_signature' });
  }
  assert.equal(calls, 0);
});

test('UniSMS blocks demo identities in all normalized forms', async (t) => {
  t.mock.method(console, 'error', () => {});
  let calls = 0;
  for (const phone of ['+639170000001', '639170000001', '09170000001', '+63 (917) 000-0001']) {
    const response = await handleSendSms(await signedRequest(payload(phone)), {
      ...CONFIG, fetchImpl: (async () => { calls++; return uniOk(); }) as typeof fetch,
    });
    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { error: 'demo_number_blocked' });
  }
  assert.equal(calls, 0);
});

test('UniSMS preserves PH phone, OTP, method and payload validation', async () => {
  const cases: [string, number][] = [
    [payload('+14155552671'), 400],
    [payload('+639175124809', '12ab56'), 400],
    [payload('+639175124809', '123'), 400],
    [JSON.stringify({ user: { phone: '+639175124809' }, sms: { otp: 123456 } }), 400],
    [JSON.stringify({ user: { phone: '+639175124809' }, sms: {} }), 400],
    ['not-json', 400],
    [JSON.stringify({ padding: 'x'.repeat(40 * 1024) }), 413],
  ];
  let calls = 0;
  const fetchImpl = (async () => { calls++; return uniOk(); }) as typeof fetch;
  for (const [body, status] of cases) {
    assert.equal((await handleSendSms(await signedRequest(body), { ...CONFIG, fetchImpl })).status, status);
  }
  assert.equal((await handleSendSms(new Request('https://example.test'), { ...CONFIG, fetchImpl })).status, 405);
  assert.equal(calls, 0);
});

test('UniSMS rejection, network and body failures never fall back, retry or leak provider details', async (t) => {
  const logs: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { logs.push(args); });
  const fetches: typeof fetch[] = [
    (async () => new Response('sensitive provider body', { status: 401 })) as typeof fetch,
    (async () => new Response(JSON.stringify({ code: 1, message: 'sensitive provider body' }))) as typeof fetch,
    (async () => new Response(JSON.stringify({ code: 0, data: { messageIds: ['id'], messages: [{ id: 'id', status: 'failed' }] } }))) as typeof fetch,
    (async () => new Response('sensitive provider body')) as typeof fetch,
    (async () => { throw new Error('sensitive provider body'); }) as typeof fetch,
  ];
  for (const failedFetch of fetches) {
    const urls: string[] = [];
    const response = await handleSendSms(await signedRequest(), {
      ...CONFIG, semaphoreApiKey: 'sem_test_key',
      fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
        urls.push(String(input));
        return failedFetch(input, init);
      }) as typeof fetch,
    });
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: 'sms_delivery_failed' });
    assert.equal(urls.length, 1);
    assert.equal(new URL(urls[0]).origin, 'https://uni.apistd.com');
    assert.notEqual(urls[0], SEMAPHORE_ENDPOINT);
  }
  const logged = JSON.stringify(logs);
  for (const sensitive of ['sensitive provider body', CONFIG.unisms!.accessKeyId,
    CONFIG.unisms!.accessKeySecret!, CONFIG.unisms!.signature, '639175124809', '001234']) {
    assert.equal(logged.includes(sensitive), false, sensitive);
  }
});

test('signed UniSMS hook timeouts cover fetch and parsing with one call and no fallback', async (t) => {
  t.mock.method(console, 'error', () => {});
  for (const stalledBody of [false, true]) {
    let calls = 0;
    let signal: AbortSignal | undefined;
    const request = await signedRequest();
    const start = performance.now();
    const response = await handleSendSms(request, {
      ...CONFIG, semaphoreApiKey: 'sem_test_key', timeoutMs: 20,
      fetchImpl: ((_input: RequestInfo | URL, init?: RequestInit) => {
        calls++;
        signal = init?.signal ?? undefined;
        return stalledBody
          ? Promise.resolve({ ok: true, status: 200, text: () => new Promise<string>(() => {}) } as unknown as Response)
          : new Promise<Response>(() => {});
      }) as typeof fetch,
    });
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: 'sms_delivery_failed' });
    assert.equal(signal?.aborted, true);
    assert.equal(calls, 1);
    assert.ok(performance.now() - start < 1000);
  }
});

test('Semaphore remains the default or explicit provider and never falls back to UniSMS', async (t) => {
  t.mock.method(console, 'error', () => {});
  for (const smsProvider of [undefined, 'semaphore']) {
    for (const success of [true, false]) {
      let calls = 0;
      const response = await handleSendSms(await signedRequest(), {
        ...CONFIG, smsProvider, semaphoreApiKey: 'sem_test_key',
        fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
          calls++;
          assert.equal(String(input), SEMAPHORE_ENDPOINT);
          const form = new URLSearchParams(String(init?.body));
          assert.equal(form.get('number'), '639175124809');
          assert.equal(form.get('apikey'), 'sem_test_key');
          assert.ok(form.get('message')!.includes('001234'));
          return new Response(JSON.stringify([{ message_id: 42, status: success ? 'Queued' : 'Failed' }]));
        }) as typeof fetch,
      });
      assert.equal(response.status, success ? 200 : 502);
      assert.equal(calls, 1);
    }
  }
  let calls = 0;
  const response = await handleSendSms(await signedRequest(), {
    ...CONFIG, smsProvider: 'semaphore',
    fetchImpl: (async () => { calls++; return uniOk(); }) as typeof fetch,
  });
  assert.equal(response.status, 500);
  assert.equal(calls, 0);
});

test('index reads runtime UniSMS env values, defaults, and rejects unknown env selection locally', async (t) => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'Deno');
  const env = new Map<string, string>([
    ['SEND_SMS_HOOK_SECRET', CONFIG.hookSecret],
    ['SMS_PROVIDER', 'unisms'],
    ['UNISMS_ACCESS_KEY_ID', 'env_test_key'],
    ['UNISMS_ACCESS_KEY_SECRET', 'env_test_secret'],
    ['UNISMS_SIGNATURE', 'EnvApprovedSender'],
    ['UNISMS_TEMPLATE_ID', 'env_test_template'],
  ]);
  let serve: ((request: Request) => Promise<Response>) | undefined;
  let calls = 0;
  const bodies: Record<string, unknown>[] = [];
  const queries: URLSearchParams[] = [];
  t.mock.method(globalThis, 'fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
    calls++;
    queries.push(new URL(String(input)).searchParams);
    bodies.push(JSON.parse(String(init?.body)));
    return uniOk();
  });
  Object.defineProperty(globalThis, 'Deno', {
    configurable: true,
    value: { env: { get: (key: string) => env.get(key) }, serve: (handler: typeof serve) => { serve = handler; } },
  });
  try {
    await import('./index.ts');
    assert.ok(serve);
    const request = () => signedRequest(payload(), Math.floor(Date.now() / 1000));
    assert.equal((await serve(await request())).status, 200);
    assert.equal(queries[0].get('accessKeyId'), 'env_test_key');
    assert.equal(queries[0].get('algorithm'), 'hmac-sha256');
    assert.deepEqual(bodies[0], {
      to: '+639175124809', signature: 'EnvApprovedSender',
      templateId: 'env_test_template', templateData: { code: '001234' },
    });
    env.set('UNISMS_AUTH_MODE', 'simple');
    env.delete('UNISMS_ACCESS_KEY_SECRET');
    env.set('UNISMS_CODE_VARIABLE', 'env_otp');
    assert.equal((await serve(await request())).status, 200);
    assert.equal(queries[1].has('algorithm'), false);
    assert.deepEqual(bodies[1].templateData, { env_otp: '001234' });
    env.delete('UNISMS_AUTH_MODE');
    assert.equal((await serve(await request())).status, 500);
    env.set('SMS_PROVIDER', 'typo');
    env.set('SEMAPHORE_API_KEY', 'sem_test_key');
    assert.equal((await serve(await request())).status, 500);
    assert.equal(calls, 2);
  } finally {
    if (descriptor) Object.defineProperty(globalThis, 'Deno', descriptor);
    else Reflect.deleteProperty(globalThis, 'Deno');
  }
});
