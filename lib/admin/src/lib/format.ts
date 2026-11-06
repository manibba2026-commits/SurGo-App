/** All money in SurGo is integer centavos. */
export const peso = (c: number | null | undefined) =>
  c == null ? '—' : new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP' }).format(c / 100);
export const num = (n: number | null | undefined) => (n == null ? '—' : new Intl.NumberFormat('en-PH').format(n));
const tz = 'Asia/Manila';
export const dt = (s?: string | null) =>
  s ? new Intl.DateTimeFormat('en-PH', { timeZone: tz, dateStyle: 'medium', timeStyle: 'short' }).format(new Date(s)) : '—';
export const d = (s?: string | null) =>
  s ? new Intl.DateTimeFormat('en-PH', { timeZone: tz, dateStyle: 'medium' }).format(new Date(s)) : '—';
export const shortDay = (s: string) =>
  new Intl.DateTimeFormat('en-PH', { timeZone: tz, month: 'short', day: 'numeric' }).format(new Date(s + 'T00:00:00'));
export const label = (s?: string | null) => (s ? s.replace(/_/g, ' ') : '—');
export const shortId = (id: string) => id.slice(0, 8);
/** Agreed ride fee rule (reference only; NOT used to compute stored values). */
export const agreedRideFeeCentavos = (km: number) => Math.min(3000, Math.max(500, Math.round(km * 200)));
