import { createClient } from '@/lib/supabase/server';
import { ok, pageRange, toPage, type Row } from '@/lib/query';
import { peso, dt, label } from '@/lib/format';
import { PageHeader, Table, Badge, Filters, Field, Select, Pager, Empty, Who } from '@/components/ui';

type SP = { status?: string; category?: string; page?: string };
const ST = ['available', 'accepted', 'going_to_pickup', 'at_pickup', 'picked_up', 'delivering', 'at_customer', 'delivered', 'cancelled'];
const CAT = ['groceries', 'food_delivery', 'pharmacy', 'parcel', 'laundry', 'other'];
export default async function Pasuyo({ searchParams: sp }: { searchParams: SP }) {
  const page = toPage(sp.page);
  let qb = createClient().from('service_requests')
    .select('id,title,category,status,budget_centavos,quoted_fee_centavos,platform_fee_centavos,requested_at,delivered_at,pickup_address,dropoff_address,customer:profiles!service_requests_customer_id_fkey(id,full_name),provider:profiles!service_requests_provider_id_fkey(id,full_name)', { count: 'exact' })
    .order('requested_at', { ascending: false }).range(...pageRange(page));
  if (sp.status) qb = qb.eq('status', sp.status);
  if (sp.category) qb = qb.eq('category', sp.category);
  const res = await qb;
  const rows = ok(res, 'Pasuyo requests') as unknown as Row[];
  return (
    <>
      <PageHeader title="Pasuyo requests" sub="Errands, pabili and padala. Pasuyo fee policy is not defined yet; amounts are shown as stored." />
      <Filters action="/pasuyo">
        <Field name="status" label="Status"><Select name="status" defaultValue={sp.status ?? ''} options={[['', 'Any'], ...ST.map((s): [string, string] => [s, label(s)])]} /></Field>
        <Field name="category" label="Category"><Select name="category" defaultValue={sp.category ?? ''} options={[['', 'Any'], ...CAT.map((s): [string, string] => [s, label(s)])]} /></Field>
      </Filters>
      <Table head={['Requested', 'Errand', 'Category', 'Requester', 'Helper', 'Budget', 'Helper fee', 'Platform fee', 'Status', 'Delivered']} empty={<Empty title="No Pasuyo requests" hint="Errands appear when customers post them in the app." />}>
        {rows.map((s) => (
          <tr key={s.id}>
            <td className="whitespace-nowrap text-ink-500">{dt(s.requested_at)}</td>
            <td className="max-w-[240px]"><div className="font-medium">{s.title}</div><div className="truncate text-xs text-ink-500">{s.pickup_address}{s.dropoff_address ? ` → ${s.dropoff_address}` : ''}</div></td>
            <td className="capitalize">{label(s.category)}</td>
            <td><Who p={s.customer} id={s.customer?.id} href /></td><td><Who p={s.provider} id={s.provider?.id} href /></td>
            <td className="tabular-nums">{peso(s.budget_centavos)}</td><td className="tabular-nums">{peso(s.quoted_fee_centavos)}</td><td className="tabular-nums">{peso(s.platform_fee_centavos)}</td>
            <td><Badge status={s.status} /></td><td className="whitespace-nowrap text-ink-500">{dt(s.delivered_at)}</td>
          </tr>
        ))}
      </Table>
      <Pager base="/pasuyo" params={sp} page={page} count={res.count ?? 0} />
    </>
  );
}
