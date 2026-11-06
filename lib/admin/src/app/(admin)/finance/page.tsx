import { createClient } from '@/lib/supabase/server';
import { ok, pageRange, toPage, type Row } from '@/lib/query';
import { peso, dt, label } from '@/lib/format';
import { PageHeader, Panel, Stat, Table, Badge, Filters, Field, Select, Input, Pager, Empty, Who } from '@/components/ui';
import { FeeStrip } from '@/components/charts';
import { ActionForm } from '@/components/ActionForm';
import { updateRemittance } from '@/app/actions';

type SP = { status?: string; service?: string; page?: string };
export default async function Finance({ searchParams: sp }: { searchParams: SP }) {
  const db = createClient(), page = toPage(sp.page);
  let rq = db.from('cash_fee_remittances')
    .select('id,amount_centavos,status,due_at,remitted_at,reference_number,notes,provider:profiles!cash_fee_remittances_provider_id_fkey(id,full_name)', { count: 'exact' })
    .order('due_at', { ascending: true }).range(...pageRange(page));
  if (sp.status) rq = rq.eq('status', sp.status);
  let tq = db.from('service_transactions')
    .select('id,service_type,status,fare_centavos,platform_fee_centavos,customer_pays_centavos,provider_payout_centavos,platform_revenue_centavos,settled_at,created_at,provider:profiles!service_transactions_provider_id_fkey(id,full_name)')
    .order('created_at', { ascending: false }).limit(25);
  if (sp.service) tq = tq.eq('service_type', sp.service);
  const [ov, remRes, txRes] = await Promise.all([db.rpc('admin_overview'), rq, tq]);
  const o = ok(ov as any, 'Finance summary') as Row;
  const rem = ok(remRes as any, 'Remittances') as Row[];
  const tx = ok(txRes as any, 'Transactions') as Row[];
  const rev = (o.revenue_by_service ?? {}) as Record<string, number>;
  return (
    <>
      <PageHeader title="Finance" sub="Payments are cash. A platform fee is only counted as received once a remittance is marked remitted with a reference number." />
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
      <Filters action="/finance"><Field name="status" label="Status"><Select name="status" defaultValue={sp.status ?? ''} options={[['', 'Any'], ['pending', 'Pending'], ['overdue', 'Overdue'], ['remitted', 'Remitted'], ['waived', 'Waived']]} /></Field></Filters>
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
      <Filters action="/finance"><Field name="service" label="Service"><Select name="service" defaultValue={sp.service ?? ''} options={[['', 'All'], ['ride', 'Ride'], ['rental', 'Rental'], ['pasuyo', 'Pasuyo']]} /></Field></Filters>
      <Table head={['Date', 'Service', 'Provider', 'Customer paid', 'Provider earned', 'Platform fee (owed)', 'Status']} empty={<Empty title="No transactions yet" />}>
        {tx.map((t) => (
          <tr key={t.id}><td className="whitespace-nowrap text-ink-500">{dt(t.settled_at ?? t.created_at)}</td><td className="capitalize">{label(t.service_type)}</td>
            <td><Who p={t.provider} id={t.provider?.id} href /></td><td className="tabular-nums">{peso(t.customer_pays_centavos)}</td>
            <td className="tabular-nums">{peso(t.provider_payout_centavos)}</td><td className="tabular-nums">{peso(t.platform_revenue_centavos)}</td><td><Badge status={t.status} /></td></tr>
        ))}
      </Table>
      <p className="mt-2 text-xs text-ink-500">Showing the 25 most recent transactions.</p>
    </>
  );
}
