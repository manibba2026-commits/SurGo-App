import Link from 'next/link';
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { ok, okOrDenied, type Row } from '@/lib/query';
import { dt, label, peso } from '@/lib/format';
import {
  allDocsApproved,
  approvalBlockReason,
  isReviewable,
  verificationForProfile,
  VERIFICATION_DOCUMENT_TYPES,
  VEHICLE_DOCUMENT_TYPES,
} from '@/lib/verification';
import { PageHeader, Panel, Badge, Table, Input, Empty } from '@/components/ui';
import { ActionForm } from '@/components/ActionForm';
import { ApplicationCard, VehicleDocumentList } from '@/components/Verification';
import { AvatarClear, AvatarUpload, ContactForm } from '@/components/AccountForms';
import { DocumentUpload } from '@/components/DocumentUpload';
import { AttachmentsManager } from '@/components/AttachmentsManager';
import { attachmentsForProfile } from '@/lib/attachments';
import { setAccountStatus, setUserRole, startVerification, updateProfile } from '@/app/actions';

const ROLE_ROWS: { key: string; title: string }[] = [
  { key: 'passenger', title: 'Passenger' },
  { key: 'earner', title: 'Helper' },
  { key: 'rider', title: 'Rider' },
  { key: 'vehicle_owner', title: 'Vehicle owner' },
];
const ROLE_STATUSES: [string, string][] = [
  ['pending', 'Pending'],
  ['approved', 'Approved'],
  ['suspended', 'Suspended'],
  ['revoked', 'Revoked'],
];

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
  const avatarUrl = u.avatar_path
    ? `${process.env.NEXT_PUBLIC_SUPABASE_URL}/storage/v1/object/public/avatars/${u.avatar_path}`
    : null;

  // The same rule the database enforces when a role is approved: a Rider or
  // Vehicle owner needs a decided application whose files are all approved.
  const approvalGate = (role: string): string | null => {
    if (role !== 'rider' && role !== 'vehicle_owner') return null;
    const matching = applications.filter((a) => a.capability_type === role);
    const approved = matching.find((a) => a.status === 'approved');
    if (approved) {
      return allDocsApproved(approved.documents as Row[])
        ? null
        : 'Approval is blocked: the approved application has files that are not approved.';
    }
    const open = matching.find((a) => isReviewable(a.status));
    if (open) {
      const block = approvalBlockReason(open.documents as Row[]);
      return block
        ? `${block} Approve the application once every file is approved.`
        : 'The application is waiting for a decision. Approve it in the Verification panel below.';
    }
    if (matching.length) {
      return `The latest application is ${label(matching[0].status)}. Open a new verification to submit fresh documents.`;
    }
    return 'No verification application yet. Open verification, then attach the required documents.';
  };
  const hasOpenApplication = (role: string) =>
    applications.some((a) => a.capability_type === role && isReviewable(a.status));

  return (
    <>
      <PageHeader
        title={u.full_name}
        sub={`${u.email ?? 'no email'} · ${u.phone ?? 'no phone'}`}
        actions={
          <div className="flex items-center gap-3">
            <Badge status={u.account_status} />
            <Link href="/users" className="text-sm text-ink-500 hover:text-ink">All users</Link>
          </div>
        }
      />
      <div className="grid gap-4 lg:grid-cols-3">
        <Panel title="Account">
          <div className="flex items-center gap-3">
            {avatarUrl ? (
              // Public bucket: the path is stored on the profile.
              // eslint-disable-next-line @next/next/no-img-element
              <img src={avatarUrl} alt="" className="h-14 w-14 rounded-full border border-line object-cover" />
            ) : (
              <div className="flex h-14 w-14 items-center justify-center rounded-full bg-paper text-lg font-medium text-ink-300">
                {u.full_name?.slice(0, 1)?.toUpperCase() ?? '?'}
              </div>
            )}
            <div className="min-w-0 text-sm">
              <div className="truncate font-medium text-ink">{u.full_name}</div>
              <div className="truncate text-xs text-ink-500">{u.email ?? 'no email'} · {u.phone ?? 'no phone'}</div>
              <div className="truncate text-xs text-ink-500">
                {[u.barangay, u.address].filter(Boolean).join(' · ') || 'No address on record'}
              </div>
            </div>
          </div>
          <dl className="mt-3 space-y-2 border-t border-line pt-3 text-sm">
            {[['Registered', dt(u.created_at)], ['Last seen', dt(u.last_seen_at)], ['Rating', Number(u.rating).toFixed(2)], ['Total rides', String(u.total_rides)], ['Earned as provider', peso(earned)]].map(([k, v]) => (
              <div key={k} className="flex justify-between"><dt className="text-ink-500">{k}</dt><dd>{v}</dd></div>
            ))}
          </dl>
        </Panel>
        <Panel title="Contact">
          <ContactForm id={u.id} email={u.email ?? null} phone={u.phone ?? null} />
        </Panel>
        <Panel title="Profile photo">
          <AvatarUpload id={u.id} hasAvatar={!!u.avatar_path} />
          {u.avatar_path && <AvatarClear id={u.id} />}
        </Panel>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Panel title="Profile details">
          <ActionForm action={updateProfile} hidden={{ id: u.id }} label="Save profile">
            <div className="grid w-full gap-2 sm:grid-cols-2">
              <label className="text-xs text-ink-500">Full name
                <Input name="full_name" defaultValue={u.full_name} required className="w-full" />
              </label>
              <label className="text-xs text-ink-500">First name
                <Input name="first_name" defaultValue={u.first_name ?? ''} className="w-full" />
              </label>
              <label className="text-xs text-ink-500">Barangay
                <Input name="barangay" defaultValue={u.barangay ?? ''} className="w-full" />
              </label>
              <label className="text-xs text-ink-500">Address
                <Input name="address" defaultValue={u.address ?? ''} className="w-full" />
              </label>
            </div>
          </ActionForm>
        </Panel>
        <Panel title="Roles">
          {roleRows.length === 0 && <p className="mb-3 text-sm text-ink-500">No roles assigned.</p>}
          <ul className="space-y-3 text-sm">
            {ROLE_ROWS.map((r) => {
              const current = roleRows.find((x) => x.role === r.key);
              const gate = approvalGate(r.key);
              return (
                <li key={r.key} className="border-b border-line pb-3 last:border-0 last:pb-0">
                  <div className="flex items-center justify-between gap-2">
                    <span className="font-medium text-ink">
                      {r.title}
                      {r.key === 'earner' && <span className="ml-1 text-xs font-normal text-ink-300">(earner)</span>}
                    </span>
                    {current ? <Badge status={current.status} /> : <span className="text-xs text-ink-300">not assigned</span>}
                  </div>
                  <div className="mt-2">
                    <ActionForm action={setUserRole} hidden={{ id: u.id, role: r.key }} label="Update role" tone="quiet">
                      <select id={`status-${r.key}`} name="status" defaultValue={current?.status ?? 'pending'} className="rounded-md border border-line bg-white px-2 py-1.5 text-sm text-ink">
                        {ROLE_STATUSES.map(([value, text]) => <option key={value} value={value}>{text}</option>)}
                      </select>
                      <Input id={`reason-${r.key}`} name="reason" placeholder="Reason (audit)" className="w-40" />
                    </ActionForm>
                  </div>
                  {gate && <p className="mt-1 text-xs text-coral">{gate}</p>}
                  {(r.key === 'rider' || r.key === 'vehicle_owner') && current?.status !== 'approved' && !hasOpenApplication(r.key) && (
                    <div className="mt-2">
                      <ActionForm action={startVerification} hidden={{ id: u.id, capability: r.key }} label="Open verification" tone="quiet" />
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
          {p && <p className="mt-3 border-t border-line pt-3 text-xs text-ink-500">Provider: {label(p.provider_type)} · capabilities {(p.capabilities as string[]).join(', ') || 'none'} · {p.is_available ? 'available now' : 'offline'} · {p.total_trips} trips</p>}
        </Panel>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Panel title="Account status">
          <p className="mb-3 text-sm text-ink-500">Suspending blocks this person from using the app. The change is recorded in the audit log.</p>
          <ActionForm action={setAccountStatus} hidden={{ id: u.id, status: active ? 'suspended' : 'active' }}
            label={active ? 'Suspend account' : 'Reactivate account'} tone={active ? 'danger' : 'primary'} confirm={active ? 'Suspend this account?' : undefined}>
            <Input name="reason" placeholder="Reason (kept in audit log)" required className="w-56" />
          </ActionForm>
        </Panel>
        <Panel title="Recent rides">
          {rideRows.length === 0 ? <p className="text-sm text-ink-500">No rides.</p> : (
            <ul className="divide-y divide-line text-sm">{rideRows.map((r) => <li key={r.id} className="flex justify-between gap-2 py-2"><Link className="truncate hover:underline" href={`/rides/${r.id}`}>{r.pickup_address} → {r.dropoff_address}</Link><Badge status={r.status} /></li>)}</ul>
          )}
        </Panel>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Panel title="Vehicles owned">
          {vehicles.length === 0 ? <p className="text-sm text-ink-500">No vehicles.</p> : (
            <Table head={['Vehicle', 'Plate', 'Rate/day', 'Status']}>{vehicles.map((v) => <tr key={v.id}><td>{v.name}</td><td>{v.plate_number}</td><td>{peso(v.price_per_day_centavos)}</td><td><Badge status={v.status} /></td></tr>)}</Table>
          )}
        </Panel>
        <Panel title="Documents on their vehicles">
          <VehicleDocumentList documents={verification.vehicleDocuments} files={verification.vehicleFiles} manage />
          {vehicles.length > 0 && (
            <div className="mt-3 space-y-3 border-t border-line pt-3">
              {vehicles.map((v) => (
                <div key={v.id}>
                  <p className="text-xs text-ink-500">Upload for {v.name} · {v.plate_number}</p>
                  <DocumentUpload
                    profileId={u.id}
                    kind="vehicle"
                    targetId={v.id}
                    types={VEHICLE_DOCUMENT_TYPES}
                  />
                </div>
              ))}
            </div>
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
            <Empty title="No applications" hint="Open verification from the Roles panel, or wait for the person to submit documents in the app." />
          ) : (
            applications.map((a) => (
              <ApplicationCard
                key={a.id}
                app={a}
                files={verification.applicationFiles}
                title={`${label(a.capability_type)} application`}
                manage
                upload={isReviewable(a.status) ? (
                  <DocumentUpload
                    profileId={u.id}
                    kind="verification"
                    targetId={a.id}
                    types={VERIFICATION_DOCUMENT_TYPES}
                  />
                ) : undefined}
              />
            ))
          )}
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
