import test from 'node:test';
import assert from 'node:assert/strict';
import { actualOnly, completedTotals, type FinanceRow } from './financeSeparation.ts';

const real: FinanceRow[] = [
  { status: 'completed', customer_pays_centavos: 12000, provider_payout_centavos: 10800, platform_revenue_centavos: 1200 },
  { status: 'completed', customer_pays_centavos: 6000, provider_payout_centavos: 5400, platform_revenue_centavos: 600 },
  { status: 'pending', customer_pays_centavos: 9900, provider_payout_centavos: 8900, platform_revenue_centavos: 1000 },
  { status: 'voided', customer_pays_centavos: 5000, provider_payout_centavos: 4500, platform_revenue_centavos: 500 },
];

const demo: FinanceRow[] = [
  { is_simulated: true, status: 'completed', customer_pays_centavos: 11000, provider_payout_centavos: 11000, platform_revenue_centavos: 0 },
  { is_simulated: true, status: 'completed', customer_pays_centavos: 9500, provider_payout_centavos: 9500, platform_revenue_centavos: 0 },
];

test('completed totals count only completed, real rows', () => {
  assert.deepEqual(completedTotals(real), {
    count: 2,
    cashCentavos: 18000,
    payoutCentavos: 16200,
    feeCentavos: 1800,
  });
});

test('database demo rows never enter a real total', () => {
  const mixed = [...real, ...demo] as FinanceRow[];
  assert.deepEqual(completedTotals(actualOnly(mixed)), completedTotals(real));
});

test('actualOnly drops both fixture and database demo markers', () => {
  assert.deepEqual(actualOnly([...real, ...demo]), real);
  assert.deepEqual(actualOnly([{ simulated: true }, { is_simulated: true }]), []);
});

test('demo settlements carry zero platform revenue', () => {
  assert.deepEqual(completedTotals(demo), {
    count: 2,
    cashCentavos: 20500,
    payoutCentavos: 20500,
    feeCentavos: 0,
  });
});
