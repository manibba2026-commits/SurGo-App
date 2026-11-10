import test from 'node:test';
import assert from 'node:assert/strict';
import { actualOnly, completedTotals, type FinanceRow } from './financeSeparation.ts';
import { SIMULATED_FINANCE, SIMULATED_FINANCE_NOTE } from './simulatedFinance.ts';

const real: FinanceRow[] = [
  { status: 'completed', customer_pays_centavos: 12000, provider_payout_centavos: 10800, platform_revenue_centavos: 1200 },
  { status: 'completed', customer_pays_centavos: 6000, provider_payout_centavos: 5400, platform_revenue_centavos: 600 },
  { status: 'pending', customer_pays_centavos: 9900, provider_payout_centavos: 8900, platform_revenue_centavos: 1000 },
  { status: 'voided', customer_pays_centavos: 5000, provider_payout_centavos: 4500, platform_revenue_centavos: 500 },
];

test('completed totals count only completed, real rows', () => {
  assert.deepEqual(completedTotals(real), {
    count: 2,
    cashCentavos: 18000,
    payoutCentavos: 16200,
    feeCentavos: 1800,
  });
});

test('simulated fixtures are explicitly marked and carry no real status', () => {
  assert.ok(SIMULATED_FINANCE.length > 0);
  for (const row of SIMULATED_FINANCE) {
    assert.equal(row.simulated, true, 'every fixture is flagged simulated');
    assert.match(row.reference, /^SIM-/, 'fixture references are visibly simulated');
    assert.ok(!('status' in row), 'fixtures never masquerade as completed transactions');
    assert.ok(row.cash_centavos > 0 && row.platform_fee_centavos > 0);
  }
  assert.match(SIMULATED_FINANCE_NOTE, /never counted/i);
});

test('a fixture mixed into database rows cannot change a real total', () => {
  const mixed = [...real, ...SIMULATED_FINANCE] as FinanceRow[];
  assert.deepEqual(completedTotals(actualOnly(mixed)), completedTotals(real));
});

test('actualOnly keeps database rows untouched', () => {
  assert.deepEqual(actualOnly(real), real);
  assert.deepEqual(actualOnly([...SIMULATED_FINANCE] as { simulated?: boolean }[]), []);
});
