import Link from 'next/link';
import { PageHeader } from '@/components/ui';
import { CreateUserForm } from '@/components/AccountForms';

export default function NewUser() {
  const serviceReady = !!process.env.SUPABASE_SERVICE_ROLE_KEY;
  return (
    <>
      <PageHeader
        title="Create user"
        sub="Creates a Supabase Auth account, its profile, and the roles you choose. Rider and Vehicle owner privileges stay pending until their documents are reviewed."
        actions={<Link href="/users" className="text-sm text-ink-500 hover:text-ink">Back to users</Link>}
      />
      {!serviceReady && (
        <div className="mb-4 rounded-md border border-line bg-paper px-4 py-3 text-sm text-ink-500" role="status">
          <span className="font-medium text-ink">Server key not configured.</span>{' '}
          Creating accounts needs SUPABASE_SERVICE_ROLE_KEY on the server (a server-only variable, never NEXT_PUBLIC).
          Editing existing accounts, roles and documents keeps working without it.
        </div>
      )}
      <CreateUserForm />
    </>
  );
}
