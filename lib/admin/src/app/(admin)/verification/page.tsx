import { createClient } from '@/lib/supabase/server';
import { verificationQueue } from '@/lib/verification';
import { label } from '@/lib/format';
import { PageHeader, Panel, Empty, Filters, Field, Select } from '@/components/ui';
import { ApplicationCard, VehicleDocumentList } from '@/components/Verification';

export default async function Verification({ searchParams }: { searchParams: { status?: string } }) {
  const db = createClient();
  const f = searchParams.status ?? 'open';
  const { applications, applicationFiles, vehicleDocuments, vehicleFiles } = await verificationQueue(db, f);
  return (
    <>
      <PageHeader title="Verification" sub="Approving an application grants that role. Decisions run through an audited server function, not the browser." />
      <Filters action="/verification">
        <Field name="status" label="Applications"><Select name="status" defaultValue={f} options={[['open', 'Awaiting review'], ['needs_resubmission', 'Needs resubmission'], ['approved', 'Approved'], ['rejected', 'Rejected'], ['draft', 'Drafts'], ['all', 'All']]} /></Field>
      </Filters>
      {applications.length === 0 ? <Empty title="No applications in this view" hint="Nothing is waiting for a decision here. Switch the status filter for resubmissions, drafts and decisions, or open the person's record to see everything they have submitted." /> : (
        <div className="space-y-4">
          {applications.map((a) => (
            <ApplicationCard
              key={a.id}
              app={a}
              files={applicationFiles}
              title={`${a.profile?.full_name ?? 'Unknown applicant'} — ${label(a.capability_type)}`}
              contact={a.profile?.email ?? a.profile?.phone}
            />
          ))}
        </div>
      )}
      <Panel title="Vehicle documents awaiting review" className="mt-4">
        <VehicleDocumentList documents={vehicleDocuments} files={vehicleFiles} showOwner />
      </Panel>
    </>
  );
}
