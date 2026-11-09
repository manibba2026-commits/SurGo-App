import { d, dt, label } from '@/lib/format';
import type { Row } from '@/lib/query';
import { allDocsApproved, documentFileState, isReviewable, type FileState } from '@/lib/verification';
import { reviewApplication, reviewDocument } from '@/app/actions';
import { ActionForm } from '@/components/ActionForm';
import { Badge, Input, Panel } from '@/components/ui';

/**
 * One document and its review controls. `file` is the storage lookup result:
 * a referenced path with no object behind it says so instead of offering a
 * link that would fail.
 */
export function DocumentRow({
  doc,
  kind,
  file,
}: {
  doc: Row;
  kind: 'verification' | 'vehicle';
  file?: FileState;
}) {
  const pending = doc.status === 'pending';
  const state = documentFileState(doc, file);

  return (
    <li className="rounded-md border border-line p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <div className="text-sm font-medium">{doc.label ?? label(doc.document_type)}</div>
          <div className="text-xs text-ink-500">
            {doc.document_number ? `No. ${doc.document_number} · ` : ''}
            {doc.expires_at ? `expires ${d(doc.expires_at)}` : 'no expiry given'}
            {doc.reviewed_at ? ` · reviewed ${dt(doc.reviewed_at)}` : ''}
          </div>
        </div>
        <div className="flex items-center gap-3">
          <Badge status={doc.status} />
          {state ? (
            <span className="text-xs text-ink-300" title={state.hint}>
              {state.text}
            </span>
          ) : (
            <a
              href={file!.url!}
              target="_blank"
              rel="noopener noreferrer"
              className="text-sm text-sea-600 hover:underline"
            >
              Preview file
            </a>
          )}
        </div>
      </div>
      {doc.rejection_reason && (
        <p className="mt-1 text-xs text-coral">Rejected: {doc.rejection_reason}</p>
      )}
      {pending && (
        <div className="mt-2 flex flex-wrap gap-4">
          <ActionForm
            action={reviewDocument}
            hidden={{ kind, id: doc.id, decision: 'approved' }}
            label="Approve file"
            tone="quiet"
          />
          <ActionForm
            action={reviewDocument}
            hidden={{ kind, id: doc.id, decision: 'rejected' }}
            label="Reject file"
            tone="danger"
          >
            <Input name="reason" required placeholder="Reason" className="w-44" />
          </ActionForm>
        </div>
      )}
    </li>
  );
}

/**
 * One application with its documents and decisions. The review buttons call the
 * same audited server actions the verification queue uses.
 */
export function ApplicationCard({
  app,
  files,
  title,
  contact,
}: {
  app: Row;
  files: Map<string, FileState>;
  title: string;
  contact?: string | null;
}) {
  const reviewable = isReviewable(app.status);
  return (
    <Panel title={title} aside={<Badge status={app.status} />}>
      <dl className="grid gap-x-6 gap-y-1 text-xs text-ink-500 sm:grid-cols-2">
        <div className="flex justify-between gap-2 sm:block">
          <dt className="sm:hidden">Capability</dt>
          <dd className="text-ink">{label(app.capability_type)}</dd>
        </div>
        <div className="flex justify-between gap-2 sm:block">
          <dt>Submitted</dt>
          <dd>{dt(app.submitted_at)}</dd>
        </div>
        <div className="flex justify-between gap-2 sm:block">
          <dt>Decision</dt>
          <dd>{app.decided_at ? dt(app.decided_at) : 'not decided yet'}</dd>
        </div>
        {contact && (
          <div className="flex justify-between gap-2 sm:block">
            <dt>Applicant</dt>
            <dd>{contact}</dd>
          </div>
        )}
      </dl>
      {app.rejection_reason && (
        <p className="mt-2 text-xs text-coral">
          {app.status === 'needs_resubmission' ? 'Needs resubmission' : 'Rejected'}:{' '}
          {app.rejection_reason}
        </p>
      )}
      <div className="mt-3">
        {app.documents.length === 0 ? (
          <p className="text-sm text-ink-500">No documents attached.</p>
        ) : (
          <ul className="space-y-2">
            {app.documents.map((doc: Row) => (
              <DocumentRow key={doc.id} doc={doc} kind="verification" file={files.get(doc.storage_path)} />
            ))}
          </ul>
        )}
      </div>
      {reviewable && (
        <div className="mt-4 flex flex-wrap items-start gap-6 border-t border-line pt-3">
          <ActionForm
            action={reviewApplication}
            hidden={{ id: app.id, decision: 'approved' }}
            label="Approve application"
            confirm={
              allDocsApproved(app.documents)
                ? undefined
                : 'Not every document is approved yet. Approve the application anyway?'
            }
          />
          <ActionForm
            action={reviewApplication}
            hidden={{ id: app.id, decision: 'needs_resubmission' }}
            label="Request resubmission"
            tone="quiet"
          >
            <Input name="reason" required placeholder="What to fix" className="w-48" />
          </ActionForm>
          <ActionForm
            action={reviewApplication}
            hidden={{ id: app.id, decision: 'rejected' }}
            label="Reject"
            tone="danger"
          >
            <Input name="reason" required placeholder="Reason" className="w-40" />
          </ActionForm>
        </div>
      )}
    </Panel>
  );
}

/** Shared by the queue and the person page so the wording can never drift. */
export function VehicleDocumentList({
  documents,
  files,
  showOwner,
}: {
  documents: Row[];
  files: Map<string, FileState>;
  showOwner?: boolean;
}) {
  if (!documents.length) {
    return (
      <p className="text-sm text-ink-500">
        {showOwner ? 'No vehicle documents on record.' : 'No vehicle documents pending.'}
      </p>
    );
  }
  return (
    <ul className="space-y-2">
      {documents.map((doc) => (
        <li key={doc.id}>
          <p className="mb-1 text-xs text-ink-500">
            {doc.vehicle?.name} · {doc.vehicle?.plate_number}
            {showOwner && doc.vehicle?.owner?.full_name
              ? ` · owner ${doc.vehicle.owner.full_name}`
              : ''}
          </p>
          <DocumentRow
            doc={{ ...doc, label: label(doc.document_type) }}
            kind="vehicle"
            file={files.get(doc.storage_path)}
          />
        </li>
      ))}
    </ul>
  );
}
