import { createClient } from '@/lib/supabase/server';
import { ok, pageRange, toPage, type Row } from '@/lib/query';
import { peso, dt, label } from '@/lib/format';
import { PageHeader, Table, Badge, Filters, Field, Select, Pager, Empty, Who } from '@/components/ui';

type SP = { status?: string; page?: string };
const ST = ['requested', 'awaiting_owner', 'accepted', 'active', 'returned', 'completed', 'declined', 'cancelled'];
export default async function Rentals({ searchParams: sp }: { searchParams: SP }) {
  const page = toPage(sp.page);
  let qb = createClient().from('rental_bookings')
    .select('id,status,start_at,end_at,total_fare_centavos,platform_fee_centavos,created_at,completed_at,renter:profiles!rental_bookings_renter_id_fkey(id,full_name),owner:profiles!rental_bookings_owner_id_fkey(id,full_name),vehicle:vehicles!rental_bookings_vehicle_owner_fkey(name,plate_number)', { count: 'exact' })
    .order('created_at', { ascending: false }).range(...pageRange(page));
  if (sp.status) qb = qb.eq('status', sp.status);
  const res = await qb;
  const rows = ok(res, 'Rental bookings') as unknown as Row[];
  return (
    <>
      <PageHeader title="Rental bookings" sub="Booking history across all owners. Rental fee policy has not been set, so fee amounts are shown exactly as stored." />
      <Filters action="/rentals">
        <Field name="status" label="Status"><Select name="status" defaultValue={sp.status ?? ''} options={[['', 'Any'], ...ST.map((s): [string, string] => [s, label(s)])]} /></Field>
      </Filters>
      <Table head={['Created', 'Vehicle', 'Renter', 'Owner', 'Period', 'Total fare', 'Platform fee', 'Status', 'Completed']} empty={<Empty title="No rental bookings" hint="Bookings appear when renters request a vehicle." />}>
        {rows.map((b) => (
          <tr key={b.id}>
            <td className="whitespace-nowrap text-ink-500">{dt(b.created_at)}</td>
            <td><div className="font-medium">{b.vehicle?.name}</div><div className="text-xs text-ink-500">{b.vehicle?.plate_number}</div></td>
            <td><Who p={b.renter} id={b.renter?.id} href /></td><td><Who p={b.owner} id={b.owner?.id} href /></td>
            <td className="whitespace-nowrap text-xs text-ink-500">{dt(b.start_at)}<br />→ {dt(b.end_at)}</td>
            <td className="tabular-nums">{peso(b.total_fare_centavos)}</td><td className="tabular-nums">{peso(b.platform_fee_centavos)}</td>
            <td><Badge status={b.status} /></td><td className="whitespace-nowrap text-ink-500">{dt(b.completed_at)}</td>
          </tr>
        ))}
      </Table>
      <Pager base="/rentals" params={sp} page={page} count={res.count ?? 0} />
    </>
  );
}
