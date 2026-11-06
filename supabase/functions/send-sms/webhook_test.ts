import assert from 'node:assert/strict';
import test from 'node:test';

import { base64Secret, signWebhook, webhookHeaders } from './test_support.ts';
import { normalizeHookSecret, verifyStandardWebhook } from './webhook.ts';

const KEY = base64Secret();
const BODY = JSON.stringify({
  user: { phone: '+639175124809' },
  sms: { otp: '123456' },
});
const NOW = 1_700_000_000;
const TIMESTAMP = `${NOW}`;

test('accepts the dashboard secret format with v1,whsec_ prefix', async () => {
  const signature = await signWebhook(KEY, 'msg_1', TIMESTAMP, BODY);
  const result = await verifyStandardWebhook(
    BODY,
    webhookHeaders(signature, 'msg_1', TIMESTAMP),
    { secret: `v1,whsec_${KEY}`, nowSeconds: NOW },
  );
  assert.deepEqual(result, { ok: true });
});

test('accepts bare whsec_ and bare base64 secrets', async () => {
  const signature = await signWebhook(KEY, 'msg_1', TIMESTAMP, BODY);
  for (const secret of [`whsec_${KEY}`, KEY]) {
    const result = await verifyStandardWebhook(
      BODY,
      webhookHeaders(signature, 'msg_1', TIMESTAMP),
      { secret, nowSeconds: NOW },
    );
    assert.deepEqual(result, { ok: true }, secret);
  }
});

test('normalizes hook secrets', () => {
  assert.equal(normalizeHookSecret(`v1,whsec_${KEY}`), KEY);
  assert.equal(normalizeHookSecret(`whsec_${KEY}`), KEY);
  assert.equal(normalizeHookSecret(` ${KEY} `), KEY);
});

test('rejects a tampered body', async () => {
  const signature = await signWebhook(KEY, 'msg_1', TIMESTAMP, BODY);
  const result = await verifyStandardWebhook(
    BODY.replace('+639175124809', '+639175124808'),
    webhookHeaders(signature, 'msg_1', TIMESTAMP),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(result, { ok: false, reason: 'invalid_signature' });
});

test('rejects a signature made with another secret', async () => {
  const other = btoa('a-different-hook-secret');
  const signature = await signWebhook(other, 'msg_1', TIMESTAMP, BODY);
  const result = await verifyStandardWebhook(
    BODY,
    webhookHeaders(signature, 'msg_1', TIMESTAMP),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(result, { ok: false, reason: 'invalid_signature' });
});

test('rejects stale and far-future timestamps', async () => {
  const stale = `${NOW - 301}`;
  const future = `${NOW + 301}`;
  for (const timestamp of [stale, future]) {
    const signature = await signWebhook(KEY, 'msg_1', timestamp, BODY);
    const result = await verifyStandardWebhook(
      BODY,
      webhookHeaders(signature, 'msg_1', timestamp),
      { secret: KEY, nowSeconds: NOW },
    );
    assert.deepEqual(
      result,
      { ok: false, reason: 'expired_timestamp' },
      timestamp,
    );
  }
});

test('accepts a timestamp exactly at the tolerance edge', async () => {
  const timestamp = `${NOW - 300}`;
  const signature = await signWebhook(KEY, 'msg_1', timestamp, BODY);
  const result = await verifyStandardWebhook(
    BODY,
    webhookHeaders(signature, 'msg_1', timestamp),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(result, { ok: true });
});

test('rejects missing or malformed headers', async () => {
  const signature = await signWebhook(KEY, 'msg_1', TIMESTAMP, BODY);

  const missing = await verifyStandardWebhook(
    BODY,
    new Headers({ 'webhook-id': 'msg_1' }),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(missing, { ok: false, reason: 'missing_headers' });

  const malformed = await verifyStandardWebhook(
    BODY,
    webhookHeaders(signature, 'msg_1', 'not-a-number'),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(malformed, { ok: false, reason: 'invalid_timestamp' });
});

test('rejects an unusable secret', async () => {
  const signature = await signWebhook(KEY, 'msg_1', TIMESTAMP, BODY);
  const result = await verifyStandardWebhook(
    BODY,
    webhookHeaders(signature, 'msg_1', TIMESTAMP),
    { secret: '***not-base64***', nowSeconds: NOW },
  );
  assert.deepEqual(result, { ok: false, reason: 'invalid_secret' });
});

test('accepts any matching v1 entry and ignores other versions', async () => {
  const signature = await signWebhook(KEY, 'msg_1', TIMESTAMP, BODY);

  const multiple = await verifyStandardWebhook(
    BODY,
    webhookHeaders(`v1,AAAA ${signature}`, 'msg_1', TIMESTAMP),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(multiple, { ok: true });

  const olderVersion = await verifyStandardWebhook(
    BODY,
    webhookHeaders(`v2,${signature.slice(3)}`, 'msg_1', TIMESTAMP),
    { secret: KEY, nowSeconds: NOW },
  );
  assert.deepEqual(olderVersion, { ok: false, reason: 'invalid_signature' });
});
