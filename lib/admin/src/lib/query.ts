import type { PostgrestError } from '@supabase/supabase-js';
export type Row = Record<string, any>;

/** Unwraps a Supabase result. Failures throw (shown by error.tsx) — we never fall back to mock data. */
export function ok<T>(res: { data: T | null; error: PostgrestError | null; count?: number | null }, what: string): T {
  if (res.error) throw new Error(`${what}: ${res.error.message}`);
  return (res.data ?? ([] as unknown)) as T;
}
export const PAGE = 25;
export const pageRange = (page: number) => [(page - 1) * PAGE, page * PAGE - 1] as const;
export const toPage = (v?: string) => Math.max(1, parseInt(v ?? '1', 10) || 1);
export const clean = (v?: string) => (v ?? '').replace(/[%,()*]/g, ' ').trim();
