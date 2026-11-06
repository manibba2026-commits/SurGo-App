import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { ok, clean, pageRange, toPage, type Row } from '@/lib/query';
import { dt, label } from '@/lib/format';
import { PageHeader, Table, Badge, Filters, Field, Input, Select, Pager, Empty } from '@/components/ui';

type SP = { q?: string; role?: string; status?: string; page?: string };
export default async function Users({ searchParams }: { searchParams: SP }) {
  const page = toPage(searchParams.page), q = clean(searchParams.q);
  const rel = searchParams.role
    ? 'user_roles!user_roles_profile_id_fkey!inner(role,status)'
    : 'user_roles!user_roles_profile_id_fkey(role,status)';
  let qb = createClient().from('profiles')
    .select(`id,full_name,email,phone,account_status,rating,total_rides,created_at,${rel}`, { count: 'exact' })
    .order('created_at', { ascending: false }).range(...pageRange(page));
  if (q) qb = qb.or(`full_name.ilike.%${q}%,email.ilike.%${q}%,phone.ilike.%${q}%`);
  if (searchParams.status) qb = qb.eq('account_status', searchParams.status);
  if (searchParams.role) qb = qb.eq('user_roles.role', searchParams.role);
  const res = await qb;
  const rows = ok(res, 'Users') as unknown as Row[];
  return (
    <>
      <PageHeader title="Users" sub="Every account. Roles are operational capabilities; one person can hold several." />
      <Filters action="/users">
        <Field name="q" label="Search"><Input name="q" defaultValue={searchParams.q} placeholder="Name, email or phone" className="w-64" /></Field>
        <Field name="role" label="Role"><Select name="role" defaultValue={searchParams.role ?? ''} options={[['', 'Any'], ['passenger', 'Passenger'], ['earner', 'Helper (earner)'], ['rider', 'Rider'], ['vehicle_owner', 'Vehicle owner'], ['admin', 'Administrator']]} /></Field>
        <Field name="status" label="Account"><Select name="status" defaultValue={searchParams.status ?? ''} options={[['', 'Any'], ['active', 'Active'], ['suspended', 'Suspended']]} /></Field>
      </Filters>
      <Table head={['Name', 'Contact', 'Roles', 'Account', 'Rating', 'Rides', 'Registered']} empty={<Empty title="No users match" hint="Users appear after they sign up in the SurGo app." />}>
        {rows.map((u) => (
          <tr key={u.id}>
            <td><Link className="font-medium text-sea-600 hover:underline" href={`/users/${u.id}`}>{u.full_name}</Link></td>
            <td className="text-ink-500">{u.email ?? '—'}<br />{u.phone ?? ''}</td>
            <td><div className="flex flex-wrap gap-1">{(u.user_roles as Row[]).map((r) => <Badge key={r.role} status={`${label(r.role)}${r.status !== 'approved' ? ` (${r.status})` : ''}`} tone={r.status === 'approved' ? 'info' : 'warn'} />)}</div></td>
            <td><Badge status={u.account_status} /></td>
            <td className="tabular-nums">{Number(u.rating).toFixed(2)}</td>
            <td className="tabular-nums">{u.total_rides}</td>
            <td className="text-ink-500">{dt(u.created_at)}</td>
          </tr>
        ))}
      </Table>
      <Pager base="/users" params={searchParams} page={page} count={res.count ?? 0} />
    </>
  );
}
