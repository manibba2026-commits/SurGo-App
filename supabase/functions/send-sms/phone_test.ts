import assert from 'node:assert/strict';
import test from 'node:test';

import { buildOtpMessage } from './message.ts';
import { isValidOtp, normalizePhilippineNumber } from './phone.ts';

test('normalizes PH mobile numbers to Semaphore form', () => {
  const cases: Array<[string, string]> = [
    ['+639175124809', '639175124809'],
    ['639175124809', '639175124809'],
    ['09175124809', '639175124809'],
    ['+63 917 512 4809', '639175124809'],
    ['0917-512-4809', '639175124809'],
    ['+63 (917) 512.4809', '639175124809'],
    ['  0998 555 1234  ', '639985551234'],
  ];
  for (const [input, expected] of cases) {
    assert.equal(normalizePhilippineNumber(input), expected, input);
  }
});

test('rejects numbers that are not PH mobiles', () => {
  const invalid = [
    '',
    '12345',
    '+14155552671',
    '+6309175124809',
    '8175124809',
    '+63917512480',
    '0917 512 480',
    '+63 2 123 4567',
    '0917-CALL-NOW',
    '++639175124809',
  ];
  for (const input of invalid) {
    assert.equal(normalizePhilippineNumber(input), null, input);
  }
});

test('accepts numeric OTPs only', () => {
  for (const otp of ['123456', '0000', '1234567890']) {
    assert.equal(isValidOtp(otp), true, otp);
  }
  for (const otp of ['', '12', '123', '12345678901', '12345a', ' 123456 ']) {
    assert.equal(isValidOtp(otp), false, otp);
  }
});

test('builds the documented message', () => {
  assert.equal(
    buildOtpMessage('123456'),
    'Your SurGo verification code is: 123456. Do not share this code with anyone.',
  );
});
