import Link from 'next/link';
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { ok, okOrDenied, type Row } from '@/lib/query';
import { dt, label, peso } from '@/lib/format';
import { verificationForProfile } from '@/lib/verification';
import { PageHeader, Panel, Badge, Table, Input, Empty } from '@/components/ui';
import { ActionForm } from '@/components/ActionForm';
import { ApplicationCard, VehicleDocumentList } from '@/components/Verification';
import { AttachmentsManager } from '@/components/AttachmentsManager';
import { attachmentsForProfile } from '@/lib/attachments';
import { setAccountStatus } from '@/app/actions';

export default async function UserDetail({ params }: { params: { id: string } }) {
  const db = createClient();
  const { data: u, error } = await db.from('profiles').select('*').eq('id', params.id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!u) notFound();
  const [roles, prov, veh, rides, tx, audit, verification, attachments] = await Promise.all([
    db.from('user_roles').select('role,status,approved_at').eq('profile_id', u.id),
    db.from('provider_profiles').select('*').eq('profile_id', u.id).maybeSingle(),
    db.from('vehicles').select('id,name,plate_number,status,price_per_day_centavos').eq('owner_profile_id', u.id),
    db.from('ride_requests').select('id,status,pickup_address,dropoff_address,requested_at,fare_centavos').or(`passenger_id.eq.${u.id},rider_id.eq.${u.id}`).order('requested_at', { ascending: false }).limit(5),
    db.from('service_transactions').select('provider_payout_centavos,platform_revenue_centavos,status').or(`customer_id.eq.${u.id},provider_id.eq.${u.id}`),
    db.from('admin_audit_logs').select('action,created_at,after_state').eq('entity_id', u.id).order('created_at', { ascending: false }).limit(5),
    verificationForProfile(db, u.id),
    attachmentsForProfile(db, u.id),
  ]);
  const R = (x: any, w: string) => ok(x, w) as Row[];
  const roleRows = R(roles, 'Roles'), vehicles = R(veh, 'Vehicles'), rideRows = R(rides, 'Rides'), txRows = R(tx, 'Transactions');
  const auditRows = okOrDenied<Row[]>(audit as any, 'Audit');
  const applications = verification.applications;
  const p = prov.data as Row | null;
  const earned = txRows.filter((t) => t.status === 'completed').reduce((a, t) => a + Number(t.provider_payout_centavos), 0);
  const active = u.account_status === 'active';
  const openWork = applications.filter((a) => ['submitted', 'under_review', 'needs_resubmission'].includes(a.status)).length;
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
      <div className="mt-8">
        <h2 className="mb-1 text-lg font-semibold">Verification</h2>
        <p className="mb-3 text-sm text-ink-500">
          {openWork
            ? `${openWork} application${openWork === 1 ? '' : 's'} waiting on a decision.`
            : applications.length
              ? 'Every application from this account has been decided.'
              : 'This account has never submitted a capability application.'}
        </p>
        <div className="space-y-4">
          {applications.length === 0 ? (
            <Empty title="No applications" hint="Applications appear here once the person submits documents for a capability in the app." />
          ) : (
            applications.map((a) => (
              <ApplicationCard
                key={a.id}
                app={a}
                files={verification.applicationFiles}
                title={`${label(a.capability_type)} application`}
              />
            ))
          )}
          <Panel title="Documents on their vehicles">
            <VehicleDocumentList documents={verification.vehicleDocuments} files={verification.vehicleFiles} />
          </Panel>
        </div>
      </div>
      <div className="mt-4">
        <Panel
          title="Files"
          aside={
            attachments ? (
              <span className="text-xs text-ink-500">
                {attachments.rows.length} file{attachments.rows.length === 1 ? '' : 's'}
              </span>
            ) : undefined
          }
        >
          {attachments === null ? (
            <p className="text-sm text-ink-500">
              Not available yet: the attachments migration has not been applied to this project, so there is no
              private file bucket or metadata table to manage. Apply the pending Supabase migrations first.
            </p>
          ) : (
            <AttachmentsManager
              profileId={u.id}
              rows={attachments.rows}
              files={Object.fromEntries(attachments.files)}
            />
          )}
        </Panel>
      </div>

      {auditRows === null ? (
        <Panel title="Admin actions on this account" className="mt-4">
          <p className="text-sm text-ink-500">Not readable by this session: the &quot;authenticated&quot; role has no SELECT privilege on admin_audit_logs, so decisions are logged but only visible through the service-role channel.</p>
        </Panel>
      ) : auditRows.length > 0 ? (
        <Panel title="Admin actions on this account" className="mt-4">
          <ul className="space-y-1 text-sm">{auditRows.map((a, i) => <li key={i}>{a.action} <span className="text-ink-500">· {dt(a.created_at)}{a.after_state?.reason ? ` · ${a.after_state.reason}` : ''}</span></li>)}</ul>
        </Panel>
      ) : null}
    </>
  );
}
