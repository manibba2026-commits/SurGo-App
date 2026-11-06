import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { ok, pageRange, toPage, type Row } from '@/lib/query';
import { label, d } from '@/lib/format';
import { PageHeader, Table, Badge, Filters, Field, Select, Pager, Empty } from '@/components/ui';

type SP = { type?: string; available?: string; page?: string };
export default async function Providers({ searchParams }: { searchParams: SP }) {
  const db = createClient(), page = toPage(searchParams.page);
  let qb = db.from('provider_profiles')
    .select('id,profile_id,provider_type,capabilities,is_available,rating,total_trips,created_at,profile:profiles(full_name,email,phone,account_status)', { count: 'exact' })
    .order('created_at', { ascending: false }).range(...pageRange(page));
  if (searchParams.type) qb = qb.eq('provider_type', searchParams.type);
  if (searchParams.available) qb = qb.eq('is_available', searchParams.available === 'yes');
  const res = await qb;
  const rows = ok(res, 'Providers') as unknown as Row[];
  const ids = rows.map((r) => r.profile_id);
  const veh = ids.length ? ok(await db.from('vehicles').select('owner_profile_id,status').in('owner_profile_id', ids), 'Vehicles') as Row[] : [];
  const docs = ids.length ? ok(await db.from('verification_applications').select('profile_id,capability_type,status').in('profile_id', ids), 'Verification') as Row[] : [];
  return (
    <>
      <PageHeader title="Riders, helpers & vehicle owners" sub="Provider directory with verification status and fleet size." />
      <Filters action="/providers">
        <Field name="type" label="Type"><Select name="type" defaultValue={searchParams.type ?? ''} options={[['', 'All'], ['earner', 'Rider / helper'], ['vehicle_owner', 'Vehicle owner']]} /></Field>
        <Field name="available" label="Availability"><Select name="available" defaultValue={searchParams.available ?? ''} options={[['', 'Any'], ['yes', 'Available now'], ['no', 'Offline']]} /></Field>
      </Filters>
      <Table head={['Provider', 'Type', 'Capabilities', 'Verification', 'Availability', 'Vehicles', 'Rating', 'Trips', 'Since']} empty={<Empty title="No providers yet" hint="Provider profiles are created when people apply to earn or list vehicles." />}>
        {rows.map((r) => {
          const mine = docs.filter((x) => x.profile_id === r.profile_id);
          return (
            <tr key={r.id}>
              <td><Link className="font-medium text-sea-600 hover:underline" href={`/users/${r.profile_id}`}>{r.profile?.full_name}</Link><div className="text-xs text-ink-500">{r.profile?.email ?? r.profile?.phone}</div></td>
              <td>{label(r.provider_type)}</td>
              <td className="text-ink-500">{(r.capabilities as string[]).join(', ') || '—'}</td>
              <td>{mine.length ? <div className="flex flex-col gap-1">{mine.map((m) => <Badge key={m.capability_type} status={`${label(m.capability_type)}: ${label(m.status)}`} tone={m.status === 'approved' ? 'good' : m.status === 'rejected' ? 'bad' : 'warn'} />)}</div> : <span className="text-ink-300">No application</span>}</td>
              <td>{r.provider_type === 'vehicle_owner' ? <span className="text-ink-300">n/a</span> : <Badge status={r.is_available ? 'available now' : 'offline'} tone={r.is_available ? 'good' : 'mute'} />}</td>
              <td className="tabular-nums">{r.provider_type === 'vehicle_owner' ? veh.filter((v) => v.owner_profile_id === r.profile_id).length : '—'}</td>
              <td className="tabular-nums">{Number(r.rating).toFixed(2)}</td><td className="tabular-nums">{r.total_trips}</td><td className="text-ink-500">{d(r.created_at)}</td>
            </tr>
          );
        })}
      </Table>
      <Pager base="/providers" params={searchParams} page={page} count={res.count ?? 0} />
    </>
  );
}
