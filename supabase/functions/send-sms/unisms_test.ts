import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';

import { isUniSmsConfigured, sendUniSms, UNISMS_ENDPOINT } from './unisms.ts';
import type { UniSmsConfig } from './unisms.ts';

const CONFIG: UniSmsConfig = {
  accessKeyId: 'uni_test_key',
  accessKeySecret: 'uni_test_secret',
  signature: 'ApprovedTestSender',
  templateId: 'test_login_template',
};

function responseFetch(body: unknown, status = 200): typeof fetch {
  return (async () => new Response(JSON.stringify(body), { status })) as typeof fetch;
}

function legacySuccess(): unknown {
  return {
    code: '0',
    data: {
      recipients: 1,
      messageCount: 1,
      messages: [{ id: 'test_message_1', to: '+639175124809', status: 'sent' }],
    },
  };
}

test('UniSMS HMAC matches the legacy SDK canonical query and preserves the OTP', async () => {
  const keyId = 'test key+/=é!()*';
  let calls = 0;
  const before = Date.now();
  const result = await sendUniSms('639175124809', '001234', {
    ...CONFIG,
    accessKeyId: keyId,
    codeVariable: 'verification_code',
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls++;
      const url = new URL(String(input));
      const query = url.searchParams;
      assert.equal(url.origin + url.pathname, 'https://uni.apistd.com/');
      assert.equal(query.get('action'), new URL(UNISMS_ENDPOINT).searchParams.get('action'));
      assert.equal(query.get('accessKeyId'), keyId);
      assert.equal(query.get('algorithm'), 'hmac-sha256');
      const timestamp = Number(query.get('timestamp'));
      assert.ok(timestamp >= before && timestamp <= Date.now());
      assert.match(query.get('nonce')!, /^[a-f0-9]{32}$/);
      assert.deepEqual([...query.keys()].sort(), [
        'accessKeyId', 'action', 'algorithm', 'nonce', 'signature', 'timestamp',
      ]);
      const canonical = [
        `accessKeyId=${encodeURIComponent(keyId)}`,
        'action=sms.message.send',
        'algorithm=hmac-sha256',
        `nonce=${query.get('nonce')}`,
        `timestamp=${query.get('timestamp')}`,
      ].join('&');
      assert.equal(query.get('signature'), createHmac('sha256', CONFIG.accessKeySecret!)
        .update(canonical).digest('base64'));
      assert.equal(String(input).includes(CONFIG.accessKeySecret!), false);
      assert.equal(init?.method, 'POST');
      assert.equal(new Headers(init?.headers).get('content-type'), 'application/json');
      assert.equal(init?.redirect, 'error');
      assert.equal(init?.signal?.aborted, false);
      assert.deepEqual(JSON.parse(String(init?.body)), {
        to: '+639175124809',
        signature: CONFIG.signature,
        templateId: CONFIG.templateId,
        templateData: { verification_code: '001234' },
      });
      return new Response(JSON.stringify(legacySuccess()));
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(calls, 1);
});

test('UniSMS simple auth is explicit, key-ID-only, and defaults the variable to code', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG,
    accessKeySecret: undefined,
    authMode: 'simple',
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls++;
      assert.deepEqual(Object.fromEntries(new URL(String(input)).searchParams), {
        action: 'sms.message.send', accessKeyId: CONFIG.accessKeyId,
      });
      assert.deepEqual(JSON.parse(String(init?.body)).templateData, { code: '654321' });
      return new Response(JSON.stringify({ code: 0, data: { messageIds: ['test_id'] } }));
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(calls, 1);
});

test('UniSMS explicit simple mode stays simple even with a secret configured', async () => {
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG, authMode: 'simple',
    fetchImpl: (async (input: RequestInfo | URL) => {
      assert.equal(new URL(String(input)).searchParams.has('signature'), false);
      return new Response(JSON.stringify(legacySuccess()));
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true });
});

test('UniSMS uses a fresh cryptographic nonce per request', async () => {
  const nonces: string[] = [];
  for (let i = 0; i < 2; i++) {
    const result = await sendUniSms('639175124809', '654321', {
      ...CONFIG,
      fetchImpl: (async (input: RequestInfo | URL) => {
        nonces.push(new URL(String(input)).searchParams.get('nonce')!);
        return new Response(JSON.stringify(legacySuccess()));
      }) as typeof fetch,
    });
    assert.equal(result.ok, true);
  }
  assert.notEqual(nonces[0], nonces[1]);
});

test('UniSMS guards all required configuration and never implicitly downgrades HMAC', async () => {
  assert.equal(isUniSmsConfigured(undefined), false);
  assert.equal(isUniSmsConfigured(CONFIG), true);
  assert.equal(isUniSmsConfigured({ ...CONFIG, authMode: 'hmac' }), true);
  const cases: UniSmsConfig[] = [
    { ...CONFIG, accessKeyId: '' },
    { ...CONFIG, accessKeyId: '  ' },
    { ...CONFIG, signature: '' },
    { ...CONFIG, signature: '  ' },
    { ...CONFIG, templateId: '' },
    { ...CONFIG, templateId: '  ' },
    { ...CONFIG, accessKeySecret: undefined },
    { ...CONFIG, accessKeySecret: '' },
    { ...CONFIG, accessKeySecret: '  ' },
    { ...CONFIG, authMode: 'hmac', accessKeySecret: undefined },
    { ...CONFIG, authMode: '' },
    { ...CONFIG, authMode: 'unknown' },
    { ...CONFIG, authMode: 'Simple' },
    { ...CONFIG, codeVariable: '' },
    { ...CONFIG, codeVariable: '  ' },
  ];
  let calls = 0;
  for (const config of cases) {
    assert.equal(isUniSmsConfigured(config), false, JSON.stringify(config));
    const result = await sendUniSms('639175124809', '654321', {
      ...config,
      fetchImpl: (async () => { calls++; throw new Error('must not fetch'); }) as typeof fetch,
    });
    assert.deepEqual(result, { ok: false, reason: 'not_configured' });
  }
  assert.equal(calls, 0);
});

test('UniSMS accepts only identified provider acceptance, including the legacy response', async () => {
  const bodies = [
    legacySuccess(),
    { code: 0, data: { messageIds: ['test_id'] } },
    { code: '0', messageIds: ['test_id'] },
    { code: 0, data: { messages: [{ id: 'test_id', status: 'queued' }] } },
    { code: 0, data: { messages: [{ id: 'test_id', status: 'accepted', code: 0 }] } },
    { code: 0, data: { messages: [{ id: 'test_id', status: 'pending' }] } },
    { code: 0, data: { messageIds: ['test_id'], messages: [{ id: 'test_id', status: 'sent' }] } },
  ];
  for (const body of bodies) {
    const result = await sendUniSms('639175124809', '654321', {
      ...CONFIG, fetchImpl: responseFetch(body, 202),
    });
    assert.deepEqual(result, { ok: true }, JSON.stringify(body));
  }
});

test('UniSMS rejects errors, empty or unknown bodies, unidentified and explicitly failed entries', async () => {
  const bodies = [
    null, [], {}, { code: 0 }, { code: 0, data: null },
    { code: false, data: { messageIds: ['id'] } },
    { code: '', data: { messageIds: ['id'] } },
    { code: null, data: { messageIds: ['id'] } },
    { code: 1, data: { messageIds: ['id'] } },
    { code: 0, data: { messageIds: [] } },
    { code: 0, data: { messageIds: [''] } },
    { code: 0, data: { messageIds: ['  '] } },
    { code: 0, data: { messageIds: [null] } },
    { code: 0, data: { messageIds: [{}] } },
    { code: 0, data: { messageIds: 'id' } },
    { code: 0, data: { messages: [] } },
    { code: 0, data: { messages: [{ id: 'id' }] } },
    { code: 0, data: { messages: [{ status: 'sent' }] } },
    { code: 0, data: { messages: [{ id: '', status: 'sent' }] } },
    { code: 0, data: { messages: [{ id: 'id', status: 'new-status' }] } },
    { code: 0, data: { messages: [{ id: 'id', status: 'failed' }] } },
    { code: 0, data: { messages: [{ id: 'id', status: 'sent', code: 1 }] } },
    { code: 0, data: { messages: [{ id: 'id', status: 'sent', success: false }] } },
    { code: 0, data: { messageIds: ['id'], messages: [{ id: 'id', status: 'failed' }] } },
    { code: 0, data: { messageIds: ['id'], messages: 'unknown' } },
    { code: 0, data: { messageIds: ['id'], messages: [] } },
    { code: 0, data: { messages: [
      { id: 'good', status: 'sent' }, { id: 'bad', status: 'Failed' },
    ] } },
  ];
  for (const body of bodies) {
    const result = await sendUniSms('639175124809', '654321', {
      ...CONFIG, fetchImpl: responseFetch(body),
    });
    assert.deepEqual(result, { ok: false, reason: 'rejected', status: 200 }, JSON.stringify(body));
  }
});

test('UniSMS rejects non-2xx without reading or leaking the response body', async () => {
  let reads = 0;
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG,
    fetchImpl: (async () => ({
      ok: false, status: 401,
      text: async () => { reads++; throw new Error('sensitive body'); },
    } as unknown as Response)) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'http_error', status: 401 });
  assert.equal(reads, 0);
});

test('UniSMS reports malformed JSON and body-reading failures without provider data', async () => {
  for (const fetchImpl of [
    (async () => new Response('not-json: sensitive body')) as typeof fetch,
    (async () => ({ ok: true, status: 200, text: async () => {
      throw new Error('sensitive body');
    } } as unknown as Response)) as typeof fetch,
  ]) {
    const result = await sendUniSms('639175124809', '654321', { ...CONFIG, fetchImpl });
    assert.deepEqual(result, { ok: false, reason: 'invalid_response', status: 200 });
  }
});

test('UniSMS reports network failures without retries or error details', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG,
    fetchImpl: (async () => { calls++; throw new Error('sensitive credentials'); }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'network_error' });
  assert.equal(calls, 1);
});

test('UniSMS aborts and bounds a fetch that ignores abort', async () => {
  let signal: AbortSignal | undefined;
  let calls = 0;
  const start = performance.now();
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG, timeoutMs: 20,
    fetchImpl: ((_input: RequestInfo | URL, init?: RequestInit) => {
      calls++;
      signal = init?.signal ?? undefined;
      return new Promise<Response>(() => {});
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'timeout' });
  assert.equal(signal?.aborted, true);
  assert.equal(calls, 1);
  assert.ok(performance.now() - start < 1000);
});

test('UniSMS shares one deadline across fetch and stalled response parsing', async () => {
  let signal: AbortSignal | undefined;
  let reads = 0;
  const start = performance.now();
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG, timeoutMs: 40,
    fetchImpl: (async (_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      await new Promise<void>((resolve) => setTimeout(resolve, 10));
      return { ok: true, status: 200, text: () => {
        reads++;
        return new Promise<string>(() => {});
      } } as unknown as Response;
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'timeout' });
  assert.equal(signal?.aborted, true);
  assert.equal(reads, 1);
  assert.ok(performance.now() - start < 1000);
});

test('UniSMS deadline is capped at two seconds, including invalid timeout overrides', async (t) => {
  const delays: number[] = [];
  const original = globalThis.setTimeout;
  t.mock.method(globalThis, 'setTimeout', (callback: () => void, delay: number) => {
    delays.push(delay);
    return original(callback, 5);
  });
  for (const timeoutMs of [undefined, 5000, Infinity, NaN, -1, 0]) {
    const result = await sendUniSms('639175124809', '654321', {
      ...CONFIG, timeoutMs,
      fetchImpl: (() => new Promise<Response>(() => {})) as typeof fetch,
    });
    assert.deepEqual(result, { ok: false, reason: 'timeout' });
  }
  assert.deepEqual(delays, Array(6).fill(2000));
});

test('UniSMS clears the deadline after success and does not abort later', async (t) => {
  let cleared = false;
  const original = globalThis.clearTimeout;
  t.mock.method(globalThis, 'clearTimeout', (timer: ReturnType<typeof setTimeout>) => {
    cleared = true;
    return original(timer);
  });
  const result = await sendUniSms('639175124809', '654321', {
    ...CONFIG, fetchImpl: responseFetch(legacySuccess()),
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(cleared, true);
});
