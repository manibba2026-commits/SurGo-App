import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { cookies } from 'next/headers';

/** Server client bound to the signed-in user's session. RLS always applies. */
export function createClient() {
  const store = cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => store.getAll(),
        setAll: (items: { name: string; value: string; options: CookieOptions }[]) => {
          try { items.forEach(({ name, value, options }) => store.set(name, value, options)); } catch { /* called from a Server Component */ }
        },
      },
    },
  );
}
