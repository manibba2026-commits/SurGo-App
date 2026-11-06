import Link from 'next/link';
import { getAdmin } from '@/lib/auth';
import { redirect } from 'next/navigation';
import { signOut } from '@/app/actions';
import { Nav } from '@/components/Nav';

export const dynamic = 'force-dynamic';

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const admin = await getAdmin();
  if (admin === 'anon') redirect('/login');
  if (!admin) {
    return (
      <main className="mx-auto mt-24 max-w-md rounded-lg border border-line bg-white p-6">
        <h1 className="text-lg font-semibold">No administrator access</h1>
        <p className="mt-2 text-sm text-ink-500">You are signed in, but this account has no approved administrator role. Roles are granted only in the database; ask an existing administrator.</p>
        <form action={signOut} className="mt-4"><button className="rounded-md bg-ink px-3 py-2 text-sm font-medium text-white">Sign out</button></form>
      </main>
    );
  }
  return (
    <div className="min-h-screen lg:grid lg:grid-cols-[232px_1fr]">
      <aside className="bg-ink px-3 py-5 text-white lg:sticky lg:top-0 lg:h-screen lg:overflow-y-auto">
        <Link href="/dashboard" className="mb-6 block px-3 text-lg font-semibold tracking-tight">SurGo <span className="font-normal text-ink-300">Admin</span></Link>
        <Nav />
        <div className="mt-8 border-t border-white/10 px-3 pt-4 text-sm">
          <div className="truncate font-medium">{admin.name}</div>
          <div className="truncate text-xs text-ink-300">{admin.email}</div>
          <form action={signOut}><button className="mt-2 text-xs text-ink-300 underline hover:text-white">Sign out</button></form>
        </div>
      </aside>
      <main className="min-w-0 px-4 py-6 lg:px-8 lg:py-8"><div className="mx-auto max-w-6xl">{children}</div></main>
    </div>
  );
}
