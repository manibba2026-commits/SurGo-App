import { createClient } from '@/lib/supabase/server';
import { ok, pageRange, toPage, type Row } from '@/lib/query';
import { peso, dt, label } from '@/lib/format';
import { PageHeader, Panel, Stat, Table, Badge, Filters, Field, Select, Input, Pager, Empty, Who } from '@/components/ui';
import { FeeStrip } from '@/components/charts';
import { ActionForm } from '@/components/ActionForm';
import { actualOnly, completedTotals } from '@/lib/financeSeparation';
import { updateRemittance } from '@/app/actions';

type SP = { rstatus?: string; tstatus?: string; service?: string; from?: string; to?: string; page?: string; tpage?: string };
const day = (v?: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : undefined);

export default async function Finance({ searchParams: sp }: { searchParams: SP }) {
  const db = createClient(), page = toPage(sp.page), tpage = toPage(sp.tpage);
  const from = day(sp.from), to = day(sp.to);

  let rq = db.from('cash_fee_remittances')
    .select('id,amount_centavos,status,due_at,remitted_at,reference_number,notes,provider:profiles!cash_fee_remittances_provider_id_fkey(id,full_name)', { count: 'exact' })
    .order('due_at', { ascending: true }).range(...pageRange(page));
  if (sp.rstatus) rq = rq.eq('status', sp.rstatus);

  let tq = db.from('service_transactions')
    .select('id,service_type,status,fare_centavos,platform_fee_centavos,customer_pays_centavos,provider_payout_centavos,platform_revenue_centavos,settled_at,created_at,is_simulated,provider:profiles!service_transactions_provider_id_fkey(id,full_name)', { count: 'exact' })
    .eq('is_simulated', false)
    .order('created_at', { ascending: false }).range(...pageRange(tpage));
  if (sp.service) tq = tq.eq('service_type', sp.service);
  if (sp.tstatus && ['pending', 'completed', 'voided', 'refunded', 'failed'].includes(sp.tstatus)) tq = tq.eq('status', sp.tstatus);
  if (from) tq = tq.gte('created_at', `${from}T00:00:00+08:00`);
  if (to) tq = tq.lte('created_at', `${to}T23:59:59+08:00`);

  let dq = db.from('service_transactions')
    .select('id,service_type,status,fare_centavos,platform_fee_centavos,customer_pays_centavos,provider_payout_centavos,platform_revenue_centavos,settled_at,created_at,is_simulated,provider:profiles!service_transactions_provider_id_fkey(id,full_name)', { count: 'exact' })
    .eq('is_simulated', true)
    .order('created_at', { ascending: false }).limit(50);
  if (sp.service) dq = dq.eq('service_type', sp.service);
  if (from) dq = dq.gte('created_at', `${from}T00:00:00+08:00`);
  if (to) dq = dq.lte('created_at', `${to}T23:59:59+08:00`);

  const [ov, remRes, txRes, demoRes] = await Promise.all([
    db.rpc('admin_overview'), rq, tq, dq,
  ]);
  const o = ok(ov as any, 'Finance summary') as Row;
  const rem = ok(remRes as any, 'Remittances') as Row[];
  const txRows = ok(txRes as any, 'Transactions') as Row[];
  const demoRows = ok(demoRes as any, 'Simulated activity') as Row[];
  // Every real figure passes through actualOnly as a second guard: the query
  // already excludes demo rows, and the helper refuses any that slip through.
  const tx = actualOnly(txRows);
  const pageTotals = completedTotals(tx);
  const demoTotals = completedTotals(demoRows);
  const rev = (o.revenue_by_service ?? {}) as Record<string, number>;

  return (
    <>
      <PageHeader title="Finance" sub="Payments are cash. A platform fee is only counted as received once a remittance is marked remitted with a reference number. A clearly labelled demo section at the bottom is excluded from every real figure." />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat name="Fees recorded (accrued)" value={peso(o.revenue_total)} hint="completed transactions" />
        <Stat name="Remitted to SurGo" value={peso(o.remit_remitted)} />
        <Stat name="Outstanding" value={peso(o.remit_outstanding)} tone={o.remit_outstanding > 0 ? 'warn' : undefined} />
        <Stat name="Overdue" value={peso(o.remit_overdue)} tone={o.remit_overdue > 0 ? 'bad' : undefined} />
      </div>
      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Panel title="Fee collection status" className="lg:col-span-2"><FeeStrip remitted={o.remit_remitted} outstanding={o.remit_outstanding} overdue={o.remit_overdue} />
          <p className="mt-3 text-xs text-ink-500">Green is cash confirmed received. Amber and red are owed by providers and must not be treated as income.</p></Panel>
        <Panel title="Fees recorded by service">
          <dl className="space-y-1.5 text-sm">{[['Rides', rev.ride], ['Rentals', rev.rental], ['Pasuyo', rev.pasuyo]].map(([k, v]) => <div key={String(k)} className="flex justify-between"><dt className="text-ink-500">{k}</dt><dd className="tabular-nums">{peso(Number(v ?? 0))}</dd></div>)}</dl>
        </Panel>
      </div>

      <h2 className="mb-3 mt-8 text-lg font-semibold">Platform fee remittances</h2>
      <Filters action="/finance"><Field name="rstatus" label="Status"><Select name="rstatus" defaultValue={sp.rstatus ?? ''} options={[['', 'Any'], ['pending', 'Pending'], ['overdue', 'Overdue'], ['remitted', 'Remitted'], ['waived', 'Waived']]} /></Field></Filters>
      <Table head={['Provider', 'Amount', 'Due', 'Status', 'Remitted', 'Reference', 'Actions']} empty={<Empty title="No remittance records" hint="A record is created for each completed cash trip with a platform fee." />}>
        {rem.map((r) => (
          <tr key={r.id}>
            <td><Who p={r.provider} id={r.provider?.id} href /></td><td className="font-medium tabular-nums">{peso(r.amount_centavos)}</td>
            <td className="text-ink-500">{dt(r.due_at)}</td><td><Badge status={r.status} /></td>
            <td className="text-ink-500">{dt(r.remitted_at)}</td><td>{r.reference_number ?? '—'}</td>
            <td>{(r.status === 'pending' || r.status === 'overdue') && (
              <div className="flex flex-col gap-2">
                <ActionForm action={updateRemittance} hidden={{ id: r.id, status: 'remitted' }} label="Mark remitted" tone="primary"><Input name="reference" required placeholder="Receipt / reference no." className="w-40" /></ActionForm>
                <div className="flex gap-3">
                  {r.status === 'pending' && <ActionForm action={updateRemittance} hidden={{ id: r.id, status: 'overdue' }} label="Mark overdue" tone="quiet" />}
                  <ActionForm action={updateRemittance} hidden={{ id: r.id, status: 'waived' }} label="Waive" tone="quiet" confirm="Waive this fee? It will no longer count as owed." />
                </div>
              </div>)}</td>
          </tr>
        ))}
      </Table>
      <Pager base="/finance" params={sp} page={page} count={remRes.count ?? 0} />

      <h2 className="mb-3 mt-8 text-lg font-semibold">Transaction history</h2>
      <Filters action="/finance">
        <Field name="service" label="Service"><Select name="service" defaultValue={sp.service ?? ''} options={[['', 'All'], ['ride', 'Ride'], ['rental', 'Rental'], ['pasuyo', 'Pasuyo']]} /></Field>
        <Field name="tstatus" label="Status"><Select name="tstatus" defaultValue={sp.tstatus ?? ''} options={[['', 'Any'], ['completed', 'Completed'], ['pending', 'Pending'], ['voided', 'Voided'], ['refunded', 'Refunded'], ['failed', 'Failed']]} /></Field>
        <Field name="from" label="From"><Input type="date" name="from" defaultValue={from} /></Field>
        <Field name="to" label="To"><Input type="date" name="to" defaultValue={to} /></Field>
      </Filters>
      <Table head={['Date', 'Service', 'Provider', 'Customer paid', 'Provider earned', 'Platform fee (owed)', 'Status']} empty={<Empty title="No matching transactions" hint="Transactions appear after a cash service is recorded." />}>
        {tx.map((t) => (
          <tr key={t.id}><td className="whitespace-nowrap text-ink-500">{dt(t.settled_at ?? t.created_at)}</td><td className="capitalize">{label(t.service_type)}</td>
            <td><Who p={t.provider} id={t.provider?.id} href /></td><td className="tabular-nums">{peso(t.customer_pays_centavos)}</td>
            <td className="tabular-nums">{peso(t.provider_payout_centavos)}</td><td className="tabular-nums">{peso(t.platform_revenue_centavos)}</td><td><Badge status={t.status} /></td></tr>
        ))}
      </Table>
      <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-ink-500">
          On this page: {pageTotals.count} completed · {peso(pageTotals.cashCentavos)} cash · {peso(pageTotals.payoutCentavos)} provider earned · {peso(pageTotals.feeCentavos)} platform fees.
          Only completed rows count; every figure comes from database records.
        </p>
        <Pager base="/finance" params={sp} page={tpage} count={txRes.count ?? 0} param="tpage" />
      </div>

      <section className="mt-10 border-t-2 border-dashed border-amber-100 pt-6">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-lg font-semibold">Simulated demo activity</h2>
          <span className="rounded bg-amber-100 px-2 py-0.5 text-xs font-semibold text-amber">Demo only · not real</span>
        </div>
        <p className="mt-1 max-w-3xl text-sm text-ink-500">
          These are database rows created for the fictional demo accounts. They are marked
          simulated at the row level, carry zero platform revenue, and are excluded from the
          summary, remittance and transaction figures above.
        </p>
        <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-3">
          <div className="rounded-lg border border-dashed border-amber-100 bg-white px-4 py-3">
            <div className="text-xs text-ink-500">Demo cash (not real)</div>
            <div className="mt-1 text-xl font-semibold tabular-nums text-amber">{peso(demoTotals.cashCentavos)}</div>
          </div>
          <div className="rounded-lg border border-dashed border-amber-100 bg-white px-4 py-3">
            <div className="text-xs text-ink-500">Demo platform revenue (not real)</div>
            <div className="mt-1 text-xl font-semibold tabular-nums text-amber">{peso(demoTotals.feeCentavos)}</div>
          </div>
          <div className="rounded-lg border border-dashed border-amber-100 bg-white px-4 py-3">
            <div className="text-xs text-ink-500">Demo rows</div>
            <div className="mt-1 text-xl font-semibold tabular-nums text-amber">{demoRes.count ?? demoRows.length}</div>
          </div>
        </div>
        <div className="mt-3">
          <Table head={['Date', 'Service', 'Provider', 'Customer paid', 'Provider earned', 'Platform revenue', 'Status']} empty={<Empty title="No simulated activity" hint="Run the demo seed to load the fictional history." />}>
            {demoRows.map((t) => (
              <tr key={t.id}><td className="whitespace-nowrap text-ink-500">{dt(t.settled_at ?? t.created_at)}</td><td className="capitalize">{label(t.service_type)}</td>
                <td><Who p={t.provider} id={t.provider?.id} href /></td><td className="tabular-nums">{peso(t.customer_pays_centavos)}</td>
                <td className="tabular-nums">{peso(t.provider_payout_centavos)}</td><td className="tabular-nums">{peso(t.platform_revenue_centavos)}</td>
                <td><Badge status="simulated" tone="warn" /></td></tr>
            ))}
          </Table>
        </div>
        <p className="mt-2 text-xs text-ink-500">
          The table shows the 50 most recent demo settlements. None of these rows appears in the
          remittance or transaction history above.
        </p>
      </section>
    </>
  );
}
