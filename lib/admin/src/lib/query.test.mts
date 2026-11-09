import test from 'node:test';
import assert from 'node:assert/strict';
import { ok, okOrDenied } from './query.ts';

const err = (code: string) => ({ data: null, error: { code, message: 'boom' } as any });

test('ok throws so a failed read becomes an error page instead of empty data', () => {
  assert.throws(() => ok(err('PGRST116'), 'Rides'), /Rides: boom/);
  assert.deepEqual(ok({ data: null, error: null }, 'Rides'), []);
});

test('okOrDenied reports a refused read as unavailable, not as zero rows', () => {
  assert.equal(okOrDenied(err('42501'), 'Audit'), null);
});

test('okOrDenied still throws for every other failure', () => {
  assert.throws(() => okOrDenied(err('42P01'), 'Audit'), /Audit: boom/);
  assert.deepEqual(okOrDenied({ data: [{ action: 'x' }], error: null }, 'Audit'), [{ action: 'x' }]);
});
