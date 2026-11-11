import assert from 'node:assert/strict';
import test from 'node:test';

import { DEMO_NUMBERS, isDemoNumber } from './demo_numbers.ts';
import { DEMO_PHONES } from '../../tools/demo_provision_plan.mjs';

test('the SMS denylist matches the provisioning plan exactly', () => {
  const planned = Object.values(DEMO_PHONES).sort();
  assert.deepEqual([...DEMO_NUMBERS].sort(), planned);
});

test('every demo number is a unique E.164 PH mobile', () => {
  assert.equal(DEMO_NUMBERS.length, 19);
  assert.equal(new Set(DEMO_NUMBERS).size, DEMO_NUMBERS.length);
  for (const number of DEMO_NUMBERS) {
    assert.match(number, /^\+639\d{9}$/);
  }
});

test('isDemoNumber matches E.164 and Semaphore-normalized forms only', () => {
  for (const number of DEMO_NUMBERS) {
    assert.equal(isDemoNumber(number), true);
    assert.equal(isDemoNumber(number.replace(/^\+/, '')), true);
    assert.equal(isDemoNumber(`+${number}`), false);
  }
  assert.equal(isDemoNumber('639175124809'), false);
  assert.equal(isDemoNumber('639170000020'), false);
});
