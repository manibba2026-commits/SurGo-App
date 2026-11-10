import type { PostgrestError } from '@supabase/supabase-js';
export type Row = Record<string, any>;

/** Unwraps a Supabase result. Failures throw (shown by error.tsx) — we never fall back to mock data. */
export function ok<T>(res: { data: T | null; error: PostgrestError | null; count?: number | null }, what: string): T {
  if (res.error) throw new Error(`${what}: ${res.error.message}`);
  return (res.data ?? ([] as unknown)) as T;
}

/** `admin_audit_logs` keeps a SELECT policy for admins but no table privilege for
 *  the `authenticated` role, so 42501 is a documented answer, not a broken query:
 *  the section renders as unavailable instead of taking the page down. Any other
 *  error still throws — this never substitutes data. */
export function okOrDenied<T>(res: { data: T | null; error: PostgrestError | null }, what: string): T | null {
  if (res.error) {
    if (res.error.code === '42501') return null;
    throw new Error(`${what}: ${res.error.message}`);
  }
  return (res.data ?? ([] as unknown)) as T;
}
/** Same shape as {@link okOrDenied}, for a table that a repo migration may not
 *  have applied yet. `42P01` (undefined table) and `PGRST205` (not in the
 *  PostgREST schema cache) mean the feature is unavailable, not that the page is
 *  broken; anything else still throws. */
export function okOrMissing<T>(res: { data: T | null; error: PostgrestError | null }, what: string): T | null {
  if (res.error) {
    if (res.error.code === '42P01' || res.error.code === '42501' || res.error.code === 'PGRST205') return null;
    throw new Error(`${what}: ${res.error.message}`);
  }
  return (res.data ?? ([] as unknown)) as T;
}

export const PAGE = 25;
export const pageRange = (page: number) => [(page - 1) * PAGE, page * PAGE - 1] as const;
export const toPage = (v?: string) => Math.max(1, parseInt(v ?? '1', 10) || 1);
export const clean = (v?: string) => (v ?? '').replace(/[%,()*]/g, ' ').trim();
