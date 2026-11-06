import Link from 'next/link';
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { ok, type Row } from '@/lib/query';
import { dt, label, peso } from '@/lib/format';
import { PageHeader, Panel, Badge, Table, Input } from '@/components/ui';
import { ActionForm } from '@/components/ActionForm';
import { setAccountStatus } from '@/app/actions';

export default async function UserDetail({ params }: { params: { id: string } }) {
  const db = createClient();
  const { data: u, error } = await db.from('profiles').select('*').eq('id', params.id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!u) notFound();
  const [roles, prov, veh, rides, tx, audit] = await Promise.all([
    db.from('user_roles').select('role,status,approved_at').eq('profile_id', u.id),
    db.from('provider_profiles').select('*').eq('profile_id', u.id).maybeSingle(),
    db.from('vehicles').select('id,name,plate_number,status,price_per_day_centavos').eq('owner_profile_id', u.id),
    db.from('ride_requests').select('id,status,pickup_address,dropoff_address,requested_at,fare_centavos').or(`passenger_id.eq.${u.id},rider_id.eq.${u.id}`).order('requested_at', { ascending: false }).limit(5),
    db.from('service_transactions').select('provider_payout_centavos,platform_revenue_centavos,status').or(`customer_id.eq.${u.id},provider_id.eq.${u.id}`),
    db.from('admin_audit_logs').select('action,created_at,after_state').eq('entity_id', u.id).order('created_at', { ascending: false }).limit(5),
  ]);
  const R = (x: any, w: string) => ok(x, w) as Row[];
  const roleRows = R(roles, 'Roles'), vehicles = R(veh, 'Vehicles'), rideRows = R(rides, 'Rides'), txRows = R(tx, 'Transactions'), auditRows = R(audit, 'Audit');
  const p = prov.data as Row | null;
  const earned = txRows.filter((t) => t.status === 'completed').reduce((a, t) => a + Number(t.provider_payout_centavos), 0);
  const active = u.account_status === 'active';
  return (
    <>
      <PageHeader title={u.full_name} sub={`${u.email ?? 'no email'} · ${u.phone ?? 'no phone'}`} actions={<Badge status={u.account_status} />} />
      <div className="grid gap-4 lg:grid-cols-3">
        <Panel title="Account">
          <dl className="space-y-2 text-sm">
            {[['Registered', dt(u.created_at)], ['Last seen', dt(u.last_seen_at)], ['Rating', Number(u.rating).toFixed(2)], ['Total rides', String(u.total_rides)], ['Earned as provider', peso(earned)]].map(([k, v]) => (
              <div key={k} className="flex justify-between"><dt className="text-ink-500">{k}</dt><dd>{v}</dd></div>
            ))}
          </dl>
        </Panel>
        <Panel title="Roles">
          {roleRows.length === 0 ? <p className="text-sm text-ink-500">No roles assigned.</p> : (
            <ul className="space-y-2 text-sm">{roleRows.map((r) => <li key={r.role} className="flex items-center justify-between"><span className="capitalize">{label(r.role)}</span><Badge status={r.status} /></li>)}</ul>
          )}
          {p && <p className="mt-3 border-t border-line pt-3 text-xs text-ink-500">Provider: {label(p.provider_type)} · capabilities {(p.capabilities as string[]).join(', ') || 'none'} · {p.is_available ? 'available now' : 'offline'} · {p.total_trips} trips</p>}
        </Panel>
        <Panel title="Account status">
          <p className="mb-3 text-sm text-ink-500">Suspending blocks this person from using the app. The change is recorded in the audit log.</p>
          <ActionForm action={setAccountStatus} hidden={{ id: u.id, status: active ? 'suspended' : 'active' }}
            label={active ? 'Suspend account' : 'Reactivate account'} tone={active ? 'danger' : 'primary'} confirm={active ? 'Suspend this account?' : undefined}>
            <Input name="reason" placeholder="Reason (kept in audit log)" required className="w-56" />
          </ActionForm>
        </Panel>
      </div>
      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Panel title="Recent rides">
          {rideRows.length === 0 ? <p className="text-sm text-ink-500">No rides.</p> : (
            <ul className="divide-y divide-line text-sm">{rideRows.map((r) => <li key={r.id} className="flex justify-between gap-2 py-2"><Link className="truncate hover:underline" href={`/rides/${r.id}`}>{r.pickup_address} → {r.dropoff_address}</Link><Badge status={r.status} /></li>)}</ul>
          )}
        </Panel>
        <Panel title="Vehicles owned">
          {vehicles.length === 0 ? <p className="text-sm text-ink-500">No vehicles.</p> : (
            <Table head={['Vehicle', 'Plate', 'Rate/day', 'Status']}>{vehicles.map((v) => <tr key={v.id}><td>{v.name}</td><td>{v.plate_number}</td><td>{peso(v.price_per_day_centavos)}</td><td><Badge status={v.status} /></td></tr>)}</Table>
          )}
        </Panel>
      </div>
      {auditRows.length > 0 && (
        <Panel title="Admin actions on this account" className="mt-4">
          <ul className="space-y-1 text-sm">{auditRows.map((a, i) => <li key={i}>{a.action} <span className="text-ink-500">· {dt(a.created_at)}{a.after_state?.reason ? ` · ${a.after_state.reason}` : ''}</span></li>)}</ul>
        </Panel>
      )}
    </>
  );
}
