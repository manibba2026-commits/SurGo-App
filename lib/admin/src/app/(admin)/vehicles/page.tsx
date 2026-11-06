import { createClient } from '@/lib/supabase/server';
import { ok, pageRange, toPage, type Row } from '@/lib/query';
import { peso, d } from '@/lib/format';
import { PageHeader, Table, Badge, Filters, Field, Select, Pager, Empty, Input } from '@/components/ui';
import { ActionForm } from '@/components/ActionForm';
import { setVehicleStatus } from '@/app/actions';

type SP = { status?: string; category?: string; page?: string };
export default async function Vehicles({ searchParams }: { searchParams: SP }) {
  const page = toPage(searchParams.page);
  let qb = createClient().from('vehicles')
    .select('id,name,vehicle_type,category,plate_number,price_per_day_centavos,status,rating,total_rentals,created_at,owner:profiles!vehicles_owner_profile_id_fkey(full_name)', { count: 'exact' })
    .order('created_at', { ascending: false }).range(...pageRange(page));
  if (searchParams.status) qb = qb.eq('status', searchParams.status);
  if (searchParams.category) qb = qb.eq('category', searchParams.category);
  const res = await qb;
  const rows = ok(res, 'Vehicles') as unknown as Row[];
  return (
    <>
      <PageHeader title="Vehicle inventory" sub="Vehicles listed for rental by owners. Only active vehicles are visible to renters." />
      <Filters action="/vehicles">
        <Field name="status" label="Status"><Select name="status" defaultValue={searchParams.status ?? ''} options={[['', 'Any'], ['pending_verification', 'Pending verification'], ['active', 'Active'], ['inactive', 'Inactive'], ['suspended', 'Suspended']]} /></Field>
        <Field name="category" label="Category"><Select name="category" defaultValue={searchParams.category ?? ''} options={[['', 'Any'], ['2-Wheel', '2-Wheel'], ['3-Wheel', '3-Wheel'], ['4-Wheel', '4-Wheel'], ['Truck', 'Truck']]} /></Field>
      </Filters>
      <Table head={['Vehicle', 'Owner', 'Category', 'Plate', 'Rate / day', 'Rentals', 'Status', 'Change status']} empty={<Empty title="No vehicles listed" hint="Vehicles appear after an owner adds one in the app." />}>
        {rows.map((v) => (
          <tr key={v.id}>
            <td><div className="font-medium">{v.name}</div><div className="text-xs text-ink-500">{v.vehicle_type} · added {d(v.created_at)}</div></td>
            <td>{v.owner?.full_name}</td><td>{v.category}</td><td>{v.plate_number}</td>
            <td className="tabular-nums">{peso(v.price_per_day_centavos)}</td><td className="tabular-nums">{v.total_rentals}</td>
            <td><Badge status={v.status} /></td>
            <td>
              <ActionForm action={setVehicleStatus} hidden={{ id: v.id }} label="Save" tone="quiet">
                <Select name="status" aria-label="New status" defaultValue={v.status} options={[['active', 'Active'], ['inactive', 'Inactive'], ['suspended', 'Suspended'], ['pending_verification', 'Pending verification']]} />
                <Input name="reason" placeholder="Reason" className="w-28" />
              </ActionForm>
            </td>
          </tr>
        ))}
      </Table>
      <Pager base="/vehicles" params={searchParams} page={page} count={res.count ?? 0} />
    </>
  );
}
