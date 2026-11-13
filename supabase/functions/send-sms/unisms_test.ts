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
const MESSAGE = 'Your SurGo OTP code is 001234. Please do not share. Expires in 1 minute.';
const REF = 'msg_84e8b93b-6315-46af-a686';

function responseFetch(body: unknown, status = 201): typeof fetch {
  return (async () => new Response(JSON.stringify(body), { status })) as typeof fetch;
}

function accepted(status = 'pending'): unknown {
  return {
    message: {
      status,
      metadata: {},
      created: '2026-03-16T14:32:44Z',
      content: MESSAGE,
      sender_id: 'Unisoft',
      recipient: '+639175124809',
      reference_id: REF,
      fail_reason: null,
    },
  };
}

function statusBody(status: string, failReason: string | null = null): unknown {
  return {
    message: {
      status,
      reference_id: REF,
      recipient: '+639175124809',
      fail_reason: failReason,
    },
  };
}

/** Existing tests focus on the send; the status check is covered separately. */
const NO_VERIFY = { verifyDelivery: false } as const;

test('UniSMS posts the finished message with Basic auth and the configured sender', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    ...NO_VERIFY,
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
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.equal(calls, 1);
});

test('UniSMS defaults the sender id but never defaults the key', async () => {
  let body: Record<string, unknown> = {};
  const result = await sendUniSms('639175124809', MESSAGE, {
    apiKey: 'uni_test_key',
    ...NO_VERIFY,
    fetchImpl: (async (_input: RequestInfo | URL, init?: RequestInit) => {
      body = JSON.parse(String(init?.body));
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.equal(body.sender_id, UNISMS_DEFAULT_SENDER_ID);
  assert.equal(UNISMS_DEFAULT_SENDER_ID, 'Unisoft');
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
      ...NO_VERIFY,
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
      ...NO_VERIFY,
      fetchImpl: responseFetch({
        message: { status, reference_id: 'msg_test', fail_reason: null },
      }),
    });
    assert.deepEqual(result, { ok: true, referenceId: 'msg_test' }, status);
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
      ...NO_VERIFY,
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
    ...NO_VERIFY,
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
    const result = await sendUniSms('639175124809', MESSAGE, {
      ...CONFIG,
      ...NO_VERIFY,
      fetchImpl,
    });
    assert.equal(result.ok, false);
    assert.equal(result.ok ? '' : result.reason, 'invalid_response');
  }
});

test('UniSMS reports network failures without retries or error details', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    ...NO_VERIFY,
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
    ...CONFIG,
    ...NO_VERIFY,
    timeoutMs: 20,
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
    ...CONFIG,
    ...NO_VERIFY,
    timeoutMs: 40,
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

test('UniSMS deadline is capped at two seconds, including invalid timeout overrides', async () => {
  const delays: number[] = [];
  for (const timeoutMs of [undefined, 5000, Infinity, NaN, -1, 0]) {
    const result = await sendUniSms('639175124809', MESSAGE, {
      ...CONFIG,
      ...NO_VERIFY,
      timeoutMs,
      setTimeoutImpl: (callback, delay) => {
        delays.push(delay);
        return setTimeout(callback, 5);
      },
      fetchImpl: (() => new Promise<Response>(() => {})) as typeof fetch,
    });
    assert.deepEqual(result, { ok: false, reason: 'timeout' });
  }
  assert.deepEqual(delays, Array(6).fill(2000));
});

test('UniSMS clears the deadline after success and does not abort later', async () => {
  let cleared = false;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    ...NO_VERIFY,
    clearTimeoutImpl: (timer) => {
      cleared = true;
      clearTimeout(timer);
    },
    fetchImpl: responseFetch(accepted()),
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.equal(cleared, true);
});

// ------------------------------------------------------- delivery status ----

test('UniSMS reads the delivery status and succeeds when the message is sent', async () => {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    statusDelayMs: 0,
    sleepImpl: async () => {},
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), init });
      if (init?.method === 'GET') {
        return new Response(JSON.stringify(statusBody('sent')), { status: 200 });
      }
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url, `${UNISMS_ENDPOINT}/${REF}`);
  assert.equal(calls[1].init?.method, 'GET');
  const headers = new Headers(calls[1].init?.headers);
  assert.equal(
    headers.get('authorization'),
    `Basic ${Buffer.from(`${CONFIG.apiKey}:`).toString('base64')}`,
  );
});

test('UniSMS surfaces an asynchronous content rejection', async () => {
  const failReason = 'Unacceptable content: OTP does not follow valid format.';
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    statusDelayMs: 0,
    sleepImpl: async () => {},
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'GET') {
        return new Response(
          JSON.stringify(statusBody('failed', failReason)),
          { status: 200 },
        );
      }
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, {
    ok: false,
    reason: 'rejected',
    status: 200,
    failReason,
  });
});

test('UniSMS treats a still-pending status as accepted', async () => {
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    statusDelayMs: 0,
    sleepImpl: async () => {},
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'GET') {
        return new Response(JSON.stringify(statusBody('pending')), { status: 200 });
      }
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
});

test('UniSMS does not fail an accepted send when the status check fails', async () => {
  for (const statusFetch of [
    (async () => { throw new Error('status network down'); }) as typeof fetch,
    (async () => new Response('nope', { status: 500 })) as typeof fetch,
    (async () => new Response('not-json', { status: 200 })) as typeof fetch,
  ]) {
    const result = await sendUniSms('639175124809', MESSAGE, {
      ...CONFIG,
      statusDelayMs: 0,
      sleepImpl: async () => {},
      fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
        if (init?.method === 'GET') return statusFetch(input, init);
        return new Response(JSON.stringify(accepted()), { status: 201 });
      }) as typeof fetch,
    });
    assert.deepEqual(result, { ok: true, referenceId: REF });
  }
});

test('UniSMS skips the status check when verification is disabled', async () => {
  let calls = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    ...NO_VERIFY,
    fetchImpl: (async () => {
      calls++;
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.equal(calls, 1);
});

test('UniSMS waits for the status target after a fast send', async () => {
  const sleeps: number[] = [];
  let now = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    statusDelayMs: 1500,
    now: () => now,
    sleepImpl: async (ms) => { sleeps.push(ms); },
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'GET') {
        return new Response(JSON.stringify(statusBody('sent')), { status: 200 });
      }
      now = 300;
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.deepEqual(sleeps, [1200]);
});

test('UniSMS does not wait when the send already passed the status target', async () => {
  const sleeps: number[] = [];
  let now = 0;
  const result = await sendUniSms('639175124809', MESSAGE, {
    ...CONFIG,
    statusDelayMs: 1500,
    now: () => now,
    sleepImpl: async (ms) => { sleeps.push(ms); },
    fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'GET') {
        return new Response(JSON.stringify(statusBody('sent')), { status: 200 });
      }
      now = 2000;
      return new Response(JSON.stringify(accepted()), { status: 201 });
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: true, referenceId: REF });
  assert.deepEqual(sleeps, []);
});
