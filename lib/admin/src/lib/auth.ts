import { cache } from 'react';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

export type Admin = { id: string; email: string | null; name: string };

/** Verified admin session. The role check is `is_admin()` in Postgres (user_roles: approved admin);
 *  the browser can neither grant nor spoof it. Returns null when signed in but not an admin. */
export const getAdmin = cache(async (): Promise<Admin | null | 'anon'> => {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return 'anon';
  const { data: ok } = await supabase.rpc('is_admin');
  if (ok !== true) return null;
  const { data: p } = await supabase.from('profiles').select('full_name').eq('id', user.id).maybeSingle();
  return { id: user.id, email: user.email ?? null, name: p?.full_name ?? user.email ?? 'Administrator' };
});

export async function requireAdmin(): Promise<Admin> {
  const a = await getAdmin();
  if (a === 'anon') redirect('/login');
  if (!a) throw new Error('Not authorized: this account does not have an approved administrator role.');
  return a;
}
