/**
 * Demonstration rows for the Finance page.
 *
 * These are fixtures that live only in this file. They are never written to the
 * database, never read by admin_overview(), and never added to a real figure.
 * The Finance page renders them in their own section, below a banner that says
 * so. Amounts are illustrative and do not represent collected fees or payouts.
 */
export type SimulatedFinanceRow = {
  simulated: true;
  reference: string;
  occurred_at: string;
  service: 'ride' | 'rental' | 'pasuyo';
  description: string;
  /** Illustrative cash value, in centavos. */
  cash_centavos: number;
  /** Illustrative platform fee, in centavos. */
  platform_fee_centavos: number;
};

export const SIMULATED_FINANCE_NOTE =
  'Simulated records for demonstration only. They are not database rows, not collected fees or payouts, and are never counted in the real figures on this page.';

export const SIMULATED_FINANCE: SimulatedFinanceRow[] = [
  {
    simulated: true,
    reference: 'SIM-2026-0001',
    occurred_at: '2026-10-24T09:15:00+08:00',
    service: 'ride',
    description: 'Sample ride · Tandag City to Bongtud',
    cash_centavos: 12000,
    platform_fee_centavos: 1200,
  },
  {
    simulated: true,
    reference: 'SIM-2026-0002',
    occurred_at: '2026-10-25T14:40:00+08:00',
    service: 'pasuyo',
    description: 'Sample errand · market pickup',
    cash_centavos: 8500,
    platform_fee_centavos: 850,
  },
  {
    simulated: true,
    reference: 'SIM-2026-0003',
    occurred_at: '2026-10-27T08:05:00+08:00',
    service: 'rental',
    description: 'Sample rental · one day, tricycle',
    cash_centavos: 60000,
    platform_fee_centavos: 6000,
  },
  {
    simulated: true,
    reference: 'SIM-2026-0004',
    occurred_at: '2026-10-29T17:20:00+08:00',
    service: 'ride',
    description: 'Sample ride · Tandag City to Tago',
    cash_centavos: 15000,
    platform_fee_centavos: 1500,
  },
  {
    simulated: true,
    reference: 'SIM-2026-0005',
    occurred_at: '2026-11-01T10:10:00+08:00',
    service: 'pasuyo',
    description: 'Sample errand · pharmacy pickup',
    cash_centavos: 6500,
    platform_fee_centavos: 650,
  },
  {
    simulated: true,
    reference: 'SIM-2026-0006',
    occurred_at: '2026-11-03T13:35:00+08:00',
    service: 'ride',
    description: 'Sample ride · Tandag City to San Miguel',
    cash_centavos: 13500,
    platform_fee_centavos: 1350,
  },
  {
    simulated: true,
    reference: 'SIM-2026-0007',
    occurred_at: '2026-11-05T07:50:00+08:00',
    service: 'rental',
    description: 'Sample rental · half day, multicab',
    cash_centavos: 45000,
    platform_fee_centavos: 4500,
  },
];
