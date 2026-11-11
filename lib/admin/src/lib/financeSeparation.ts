/**
 * The boundary between real money and demonstration rows.
 *
 * Real figures always come from database rows that passed through `actualOnly`.
 * Demo activity is stored in the same tables with `is_simulated = true`; it is
 * rendered in its own section and never enters a real total.
 */
export type FinanceRow = {
  simulated?: boolean;
  is_simulated?: boolean;
  status?: string | null;
  customer_pays_centavos?: number | string | null;
  provider_payout_centavos?: number | string | null;
  platform_fee_centavos?: number | string | null;
  platform_revenue_centavos?: number | string | null;
};

/** Drops anything flagged as simulated, from a fixture or from the database. */
export function actualOnly<T extends { simulated?: boolean; is_simulated?: boolean }>(
  rows: readonly T[],
): T[] {
  return rows.filter((row) => row.simulated !== true && row.is_simulated !== true);
}

export type TransactionTotals = {
  count: number;
  cashCentavos: number;
  payoutCentavos: number;
  feeCentavos: number;
};

/** Totals for completed rows only; pending, voided, refunded and failed rows
 *  are not money received. Never feed simulated rows in without actualOnly. */
export function completedTotals(rows: readonly FinanceRow[]): TransactionTotals {
  const totals: TransactionTotals = { count: 0, cashCentavos: 0, payoutCentavos: 0, feeCentavos: 0 };
  for (const row of rows) {
    if (row.status !== 'completed') continue;
    totals.count += 1;
    totals.cashCentavos += Number(row.customer_pays_centavos ?? 0);
    totals.payoutCentavos += Number(row.provider_payout_centavos ?? 0);
    totals.feeCentavos += Number(row.platform_revenue_centavos ?? row.platform_fee_centavos ?? 0);
  }
  return totals;
}
