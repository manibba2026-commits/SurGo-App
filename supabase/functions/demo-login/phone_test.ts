import assert from 'node:assert/strict';
import test from 'node:test';

import { normalizePhilippineNumber } from './phone.ts';

test('accepts 09, +639, 639 and 0063 forms', () => {
  const cases: Array<[string, string]> = [
    ['09170000001', '+639170000001'],
    ['9170000001', '+639170000001'],
    ['+639170000001', '+639170000001'],
    ['639170000001', '+639170000001'],
    ['00639170000001', '+639170000001'],
    ['0917 000 0001', '+639170000001'],
    ['+63 917-000-0001', '+639170000001'],
    ['(0917) 000 0001', '+639170000001'],
  ];
  for (const [input, expected] of cases) {
    assert.equal(normalizePhilippineNumber(input), expected, input);
  }
});

test('rejects malformed or non-PH numbers', () => {
  for (const input of [
    '', '12345', '08170000001', '091700000012', '+63917000000',
    '+15551234567', 'not a number', null, undefined, 639170000001,
  ]) {
    assert.equal(normalizePhilippineNumber(input), null, String(input));
  }
});
