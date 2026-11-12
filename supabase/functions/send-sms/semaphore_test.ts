import assert from 'node:assert/strict';
import test from 'node:test';

import { SEMAPHORE_ENDPOINT, sendSemaphoreSms } from './semaphore.ts';

function responseFetch(body: string, status = 200): typeof fetch {
  return (async () => new Response(body, { status })) as typeof fetch;
}

function delivered(status: string): string {
  return JSON.stringify([{ message_id: 42, status }]);
}

test('accepts every documented synchronous success status', async () => {
  for (const status of ['Queued', 'Pending', 'Sent']) {
    const result = await sendSemaphoreSms('639175124809', 'code', {
      apiKey: 'sem_test_key',
      fetchImpl: responseFetch(delivered(status)),
    });
    assert.deepEqual(result, { ok: true }, status);
  }
});

test('accepts a single-object success response', async () => {
  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key',
    fetchImpl: responseFetch(
      JSON.stringify({ message_id: 42, status: 'Sent' }),
    ),
  });
  assert.deepEqual(result, { ok: true });
});

test('rejects Failed, Refunded, unknown or incomplete statuses', async () => {
  const bodies = [
    delivered('Failed'),
    delivered('Refunded'),
    delivered('SomethingNew'),
    JSON.stringify([{ message_id: 42 }]),
    JSON.stringify([{ status: 'Queued' }]),
    JSON.stringify([{}]),
    '[]',
  ];
  for (const body of bodies) {
    const result = await sendSemaphoreSms('639175124809', 'code', {
      apiKey: 'sem_test_key',
      fetchImpl: responseFetch(body),
    });
    assert.equal(result.ok, false, body);
    assert.equal(
      (result as { reason: string }).reason,
      'rejected',
      body,
    );
  }
});

test('reports HTTP errors without reading or leaking the body', async () => {
  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key',
    fetchImpl: responseFetch('{"message":"Invalid API key"}', 401),
  });
  assert.deepEqual(result, {
    ok: false,
    reason: 'http_error',
    status: 401,
  });
});

test('reports network failures', async () => {
  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key',
    fetchImpl: (async () => {
      throw new Error('network down');
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'network_error' });
});

test('reports malformed success bodies', async () => {
  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key',
    fetchImpl: responseFetch('not-json'),
  });
  assert.deepEqual(result, {
    ok: false,
    reason: 'invalid_response',
    status: 200,
  });
});

test('aborts a slow Semaphore call within the configured budget', async () => {
  const hangingFetch = ((_input: RequestInfo | URL, init?: RequestInit) => {
    return new Promise((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => {
        reject(new DOMException('Aborted', 'AbortError'));
      });
    });
  }) as typeof fetch;

  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key',
    fetchImpl: hangingFetch,
    timeoutMs: 20,
  });
  assert.deepEqual(result, { ok: false, reason: 'network_error' });
});

test('sends the documented Semaphore fields', async () => {
  let url = '';
  let init: RequestInit | undefined;
  const fetchImpl = (async (input: RequestInfo | URL, options?: RequestInit) => {
    url = String(input);
    init = options;
    return new Response(delivered('Queued'), { status: 200 });
  }) as typeof fetch;

  await sendSemaphoreSms('639175124809', 'Your code is 123456.', {
    apiKey: 'sem_test_key',
    senderName: 'SurGo',
    fetchImpl,
  });

  assert.equal(url, SEMAPHORE_ENDPOINT);
  assert.equal(init?.method, 'POST');
  const form = new URLSearchParams(String(init?.body));
  assert.deepEqual(Object.fromEntries(form), {
    apikey: 'sem_test_key',
    number: '639175124809',
    message: 'Your code is 123456.',
    sendername: 'SurGo',
  });
});

test('Semaphore deadline bounds a fetch that ignores abort', async () => {
  let signal: AbortSignal | undefined;
  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key', timeoutMs: 20,
    fetchImpl: ((_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      return new Promise<Response>(() => {});
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'network_error' });
  assert.equal(signal?.aborted, true);
});

test('Semaphore shares one deadline across fetch and response-body parsing', async () => {
  let signal: AbortSignal | undefined;
  let reads = 0;
  const start = performance.now();
  const result = await sendSemaphoreSms('639175124809', 'code', {
    apiKey: 'sem_test_key', timeoutMs: 40,
    fetchImpl: (async (_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      await new Promise<void>((resolve) => setTimeout(resolve, 10));
      return { ok: true, status: 200, text: () => {
        reads++;
        return new Promise<string>(() => {});
      } } as unknown as Response;
    }) as typeof fetch,
  });
  assert.deepEqual(result, { ok: false, reason: 'network_error' });
  assert.equal(signal?.aborted, true);
  assert.equal(reads, 1);
  assert.ok(performance.now() - start < 1000);
});

test('Semaphore deadline cannot exceed the two-second provider budget', async (t) => {
  const delays: number[] = [];
  const original = globalThis.setTimeout;
  t.mock.method(globalThis, 'setTimeout', (callback: () => void, delay: number) => {
    delays.push(delay);
    return original(callback, 5);
  });
  for (const timeoutMs of [undefined, 5000, Infinity, NaN, -1, 0]) {
    const result = await sendSemaphoreSms('639175124809', 'code', {
      apiKey: 'sem_test_key', timeoutMs,
      fetchImpl: (() => new Promise<Response>(() => {})) as typeof fetch,
    });
    assert.deepEqual(result, { ok: false, reason: 'network_error' });
  }
  assert.deepEqual(delays, Array(6).fill(2000));
});
