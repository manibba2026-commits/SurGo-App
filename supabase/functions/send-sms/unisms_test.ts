import assert from 'node:assert/strict';
import test from 'node:test';

import {
  isUniSmsConfigured,
  sendUniSms,
  UNISMS_DEFAULT_SENDER_ID,
  UNISMS_ENDPOINT,
} from './unisms.ts';
import type { UniSmsConfig } from './unisms.ts';

const CONFIG: UniSmsConfig = { apiKey: 'uni_test_key', senderId: 'Unisoft' };
const MESSAGE = 'Your SurGo verification code is: 001234. Do not share this code with anyone.';

function responseFetch(body: unknown, status = 201): typeof fetch {
  return (async () => new Response(JSON.stringify(body), { status })) as typeof fetch;
}

function accepted(): unknown {
  return {
    message: {
      status: 'pending',
      metadata: {},
      created: '2026-03-16T14:32:44Z',
      content: MESSAGE,
      sender_id: 'Unisoft',
      recipient: '+639175124809',
      reference_id: 'msg_84e8b93b-6315-46af-a686',
      fail_reason: null,
    },
  };
}

test('UniSMS posts the finished message with Basic auth and the configured sender', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls++;
      assert.equal(String(input), UNISMS_ENDPOINT);
      assert.equal(init?.method, 'POST');
      const headers = new Headers(init?.headers);
      assert.equal(headers.get('content-type'), 'application/json');
      assert.equal(
        headers.get('authorization'),
        `Basic ${Buffer.from(`${CONFIG.apiKey}:`).toString('base64')}`,
      );
      assert.equal(init?.redirect, 'error');
      assert.equal(init?.signal?.aborted, false);
      assert.deepEqual(JSON.parse(String(init?.body)), {
        recipient: '+639175124809',
        content: MESSAGE,
        sender_id: 'Unisoft',
      });
      // The key travels only in the header, never in the URL.
      assert.equal(String(input).includes(CONFIG.apiKey), false);
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(calls, 1);
});

test('UniSMS defaults the sender id but never defaults the key', async () => {
  let body: Record<string, unknown> = {};
  const result = await sendUniSms('639175124809', MESSAGE, {
    apiKey: 'uni_test_key',
    fetchImpl: (async (_input: RequestInfo | URL, init?: RequestInit) => {
      body = JSON.parse(String(init?.body));
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(body.sender_id, UNISMS_DEFAULT_SENDER_ID);
});

test('UniSMS guards missing configuration without calling the provider', async () => {
  assert.equal(isUniSmsConfigured(undefined), false);
  assert.equal(isUniSmsConfigured({ apiKey: '' }), false);
  assert.equal(isUniSmsConfigured({ apiKey: '   ' }), false);
  assert.equal(isUniSmsConfigured(CONFIG), true);
  let calls = 0;
  for (const config of [{ apiKey: '' }, { apiKey: '  ' }]) {
    const result = await sendUniSms('639175124809', MESSAGE, {
      ...config,
      fetchImpl: (async () => { calls++; throw new Error('must not fetch'); }) as typeof fetch,
    });
    assert.deepEqual(result, { ok: false, reason: 'not_configured' });
  }
  assert.equal(calls, 0);
});

test('UniSMS accepts the documented pending message and other accepted statuses', async () => {
  for (const status of ['pending', 'sent', 'queued', 'accepted', 'success']) {
    const result = await sendUniSms('639175124809', MESSAGE, {
      ...CONFIG,
      fetchImpl: responseFetch({
        message: { status, reference_id: 'msg_test', fail_reason: null },
      }),
    });
    assert.deepEqual(result, { ok: true }, status);
  }
});

test('UniSMS rejects errors, failed messages and bodies it cannot identify', async () => {
  const bodies = [
    null, [], {}, 'ok', true,
    { message: null },
    { message: 'sent' },
    { message: { status: 'failed', reference_id: 'msg_test' } },
    { message: { status: 'new-status', reference_id: 'msg_test' } },
    { message: { reference_id: 'msg_test' } },
    { message: { status: 'sent', fail_reason: 'carrier rejected' } },
    { message: { status: 'sent', success: false } },
    { error: 'invalid key' },
  ];
  for (const body of bodies) {
    const result = await sendUniSms('639175124809', MESSAGE, {
      ...CONFIG,
      fetchImpl: responseFetch(body, 201),
    });
    assert.deepEqual(
      result,
      { ok: false, reason: 'rejected', status: 201 },
      JSON.stringify(body),
    );
  }
});

test('UniSMS rejects non-2xx without reading or leaking the response body', async () => {
  let reads = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
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
    (async () => ({ ok: true, status: 201, text: async () => {
      throw new Error('sensitive body');
    } } as unknown as Response)) as typeof fetch,
  ]) {
    const result = await sendUniSms('639175124809', MESSAGE, { ...CONFIG, fetchImpl });
    assert.equal(result.ok, false);
    assert.equal(result.ok ? '' : result.reason, 'invalid_response');
  }
});

test('UniSMS reports network failures without retries or error details', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
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
  const result = await sendUniSms('639175124809', MESSAGE, {
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
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG, timeoutMs: 40,
    fetchImpl: (async (_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      await new Promise<void>((resolve) => setTimeout(resolve, 10));
      return { ok: true, status: 201, text: () => {
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
    const result = await sendUniSms('639175124809', MESSAGE, {
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
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG, fetchImpl: responseFetch(accepted()),
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(cleared, true);
});
