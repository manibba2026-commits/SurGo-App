import { createClient } from '@/lib/supabase/server';
import { ok, type Row } from '@/lib/query';
import { dt, label, d } from '@/lib/format';
import { PageHeader, Panel, Badge, Empty, Filters, Field, Select, Input } from '@/components/ui';
import { ActionForm } from '@/components/ActionForm';
import { reviewApplication, reviewDocument } from '@/app/actions';

async function signed(db: ReturnType<typeof createClient>, bucket: string, paths: string[]) {
  const map = new Map<string, string>();
  if (!paths.length) return map;
  const { data } = await db.storage.from(bucket).createSignedUrls(paths, 600);
  (data ?? []).forEach((x) => x.signedUrl && x.path && map.set(x.path, x.signedUrl));
  return map;
}
function DocRow({ doc, kind, url }: { doc: Row; kind: 'verification' | 'vehicle'; url?: string }) {
  const pending = doc.status === 'pending';
  return (
    <li className="rounded-md border border-line p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div><div className="text-sm font-medium">{doc.label ?? label(doc.document_type)}</div>
          <div className="text-xs text-ink-500">{doc.document_number ? `No. ${doc.document_number} · ` : ''}{doc.expires_at ? `expires ${d(doc.expires_at)}` : 'no expiry given'}</div></div>
        <div className="flex items-center gap-3"><Badge status={doc.status} />
          {url ? <a href={url} target="_blank" rel="noopener noreferrer" className="text-sm text-sea-600 hover:underline">Preview file</a> : <span className="text-xs text-ink-300">{doc.storage_path ? 'Preview unavailable' : 'No file uploaded'}</span>}</div>
      </div>
      {doc.rejection_reason && <p className="mt-1 text-xs text-coral">Rejected: {doc.rejection_reason}</p>}
      {pending && (
        <div className="mt-2 flex flex-wrap gap-4">
          <ActionForm action={reviewDocument} hidden={{ kind, id: doc.id, decision: 'approved' }} label="Approve file" tone="quiet" />
          <ActionForm action={reviewDocument} hidden={{ kind, id: doc.id, decision: 'rejected' }} label="Reject file" tone="danger"><Input name="reason" required placeholder="Reason" className="w-44" /></ActionForm>
        </div>
      )}
    </li>
  );
}

export default async function Verification({ searchParams }: { searchParams: { status?: string } }) {
  const db = createClient();
  const f = searchParams.status ?? 'open';
  let qb = db.from('verification_applications')
    .select('id,capability_type,status,submitted_at,decided_at,rejection_reason,profile:profiles!verification_applications_profile_id_fkey(id,full_name,email,phone),documents:verification_documents(id,document_type,label,document_number,storage_path,expires_at,status,rejection_reason)')
    .order('submitted_at', { ascending: true, nullsFirst: false }).limit(50);
  qb = f === 'open' ? qb.in('status', ['submitted', 'under_review']) : f === 'all' ? qb : qb.eq('status', f);
  const apps = ok(await qb as any, 'Applications') as Row[];
  const vdocs = ok(await db.from('vehicle_documents')
    .select('id,document_type,document_number,storage_path,expires_at,status,rejection_reason,vehicle:vehicles(name,plate_number,owner:profiles!vehicles_owner_profile_id_fkey(full_name))')
    .eq('status', 'pending').order('created_at').limit(50) as any, 'Vehicle documents') as Row[];
  const [urls, vurls] = await Promise.all([
    signed(db, 'verification-documents', apps.flatMap((a) => a.documents.map((x: Row) => x.storage_path).filter(Boolean))),
    signed(db, 'vehicle-documents', vdocs.map((x) => x.storage_path).filter(Boolean)),
  ]);
  return (
    <>
      <PageHeader title="Verification" sub="Approving an application grants that role. Decisions run through an audited server function, not the browser." />
      <Filters action="/verification">
        <Field name="status" label="Applications"><Select name="status" defaultValue={f} options={[['open', 'Awaiting review'], ['needs_resubmission', 'Needs resubmission'], ['approved', 'Approved'], ['rejected', 'Rejected'], ['draft', 'Drafts'], ['all', 'All']]} /></Field>
      </Filters>
      {apps.length === 0 ? <Empty title="No applications in this view" hint="Applications show here once people submit documents in the app." /> : (
        <div className="space-y-4">
          {apps.map((a) => {
            const reviewable = ['submitted', 'under_review', 'needs_resubmission'].includes(a.status);
            const allApproved = a.documents.length > 0 && a.documents.every((x: Row) => x.status === 'approved');
            return (
              <Panel key={a.id} title={`${a.profile?.full_name} — ${label(a.capability_type)}`} aside={<Badge status={a.status} />}>
                <p className="mb-3 text-xs text-ink-500">{a.profile?.email ?? a.profile?.phone} · submitted {dt(a.submitted_at)}{a.rejection_reason ? ` · reason: ${a.rejection_reason}` : ''}</p>
                {a.documents.length === 0 ? <p className="text-sm text-ink-500">No documents attached.</p> :
                  <ul className="space-y-2">{a.documents.map((x: Row) => <DocRow key={x.id} doc={x} kind="verification" url={urls.get(x.storage_path)} />)}</ul>}
                {reviewable && (
                  <div className="mt-4 flex flex-wrap items-start gap-6 border-t border-line pt-3">
                    <ActionForm action={reviewApplication} hidden={{ id: a.id, decision: 'approved' }} label="Approve application" confirm={allApproved ? undefined : 'Not every document is approved yet. Approve the application anyway?'} />
                    <ActionForm action={reviewApplication} hidden={{ id: a.id, decision: 'needs_resubmission' }} label="Request resubmission" tone="quiet"><Input name="reason" required placeholder="What to fix" className="w-48" /></ActionForm>
                    <ActionForm action={reviewApplication} hidden={{ id: a.id, decision: 'rejected' }} label="Reject" tone="danger"><Input name="reason" required placeholder="Reason" className="w-40" /></ActionForm>
                  </div>
                )}
              </Panel>
            );
          })}
        </div>
      )}
      <h2 className="mb-3 mt-10 text-lg font-semibold">Vehicle documents awaiting review</h2>
      {vdocs.length === 0 ? <Empty title="No vehicle documents pending" /> : (
        <ul className="space-y-2">{vdocs.map((x) => (
          <div key={x.id}><p className="mb-1 text-xs text-ink-500">{x.vehicle?.name} · {x.vehicle?.plate_number} · owner {x.vehicle?.owner?.full_name}</p>
            <DocRow doc={{ ...x, label: label(x.document_type) }} kind="vehicle" url={vurls.get(x.storage_path)} /></div>))}</ul>
      )}
    </>
  );
}
