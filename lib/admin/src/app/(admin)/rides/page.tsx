import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { ok, clean, pageRange, toPage, type Row } from '@/lib/query';
import { peso, dt } from '@/lib/format';
import { PageHeader, Table, Badge, Filters, Field, Input, Select, Pager, Empty, Who } from '@/components/ui';

type SP = { status?: string; from?: string; to?: string; passenger?: string; rider?: string; page?: string };
const STATUSES = ['searching', 'awaiting_acceptance', 'accepted', 'heading_to_pickup', 'arrived', 'in_progress', 'completed', 'cancelled'];
export default async function Rides({ searchParams: sp }: { searchParams: SP }) {
  const page = toPage(sp.page), pq = clean(sp.passenger), rq = clean(sp.rider);
  const sel = `id,status,pickup_address,dropoff_address,distance_km,fare_centavos,platform_fee_centavos,requested_at,completed_at,passenger:profiles!ride_requests_passenger_id_fkey${pq ? '!inner' : ''}(id,full_name),rider:profiles!ride_requests_rider_id_fkey${rq ? '!inner' : ''}(id,full_name)`;
  let qb = createClient().from('ride_requests').select(sel, { count: 'exact' }).order('requested_at', { ascending: false }).range(...pageRange(page));
  if (sp.status) qb = qb.eq('status', sp.status);
  if (sp.from) qb = qb.gte('requested_at', `${sp.from}T00:00:00+08:00`);
  if (sp.to) qb = qb.lte('requested_at', `${sp.to}T23:59:59+08:00`);
  if (pq) qb = qb.ilike('passenger.full_name', `%${pq}%`);
  if (rq) qb = qb.ilike('rider.full_name', `%${rq}%`);
  const res = await qb;
  const rows = ok(res, 'Rides') as unknown as Row[];
  return (
    <>
      <PageHeader title="Rides" sub="Customer total = provider fare + platform fee (cash). Fee collection is tracked under Finance." />
      <Filters action="/rides">
        <Field name="status" label="Status"><Select name="status" defaultValue={sp.status ?? ''} options={[['', 'Any'], ...STATUSES.map((s): [string, string] => [s, s.replace(/_/g, ' ')])]} /></Field>
        <Field name="from" label="From"><Input type="date" name="from" defaultValue={sp.from} /></Field>
        <Field name="to" label="To"><Input type="date" name="to" defaultValue={sp.to} /></Field>
        <Field name="passenger" label="Passenger"><Input name="passenger" defaultValue={sp.passenger} placeholder="Name" className="w-36" /></Field>
        <Field name="rider" label="Rider"><Input name="rider" defaultValue={sp.rider} placeholder="Name" className="w-36" /></Field>
      </Filters>
      <Table head={['Requested', 'Route', 'Passenger', 'Rider', 'Km', 'Provider fare', 'Platform fee', 'Customer total', 'Status', 'Completed']} empty={<Empty title="No rides match" hint="Try clearing filters. Rides appear once passengers book in the app." />}>
        {rows.map((r) => (
          <tr key={r.id}>
            <td className="whitespace-nowrap text-ink-500">{dt(r.requested_at)}</td>
            <td className="max-w-[260px]"><Link href={`/rides/${r.id}`} className="text-sea-600 hover:underline">{r.pickup_address} → {r.dropoff_address}</Link></td>
            <td><Who p={r.passenger} id={r.passenger?.id} href /></td><td><Who p={r.rider} id={r.rider?.id} href /></td>
            <td className="tabular-nums">{Number(r.distance_km).toFixed(1)}</td>
            <td className="tabular-nums">{peso(r.fare_centavos)}</td><td className="tabular-nums">{peso(r.platform_fee_centavos)}</td>
            <td className="font-medium tabular-nums">{peso(r.fare_centavos + r.platform_fee_centavos)}</td>
            <td><Badge status={r.status} /></td><td className="whitespace-nowrap text-ink-500">{dt(r.completed_at)}</td>
          </tr>
        ))}
      </Table>
      <Pager base="/rides" params={sp} page={page} count={res.count ?? 0} />
    </>
  );
}
