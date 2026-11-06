import Link from 'next/link';
import type { ReactNode } from 'react';
import { label } from '@/lib/format';

export function PageHeader({ title, sub, actions }: { title: string; sub?: string; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-ink">{title}</h1>
        {sub && <p className="mt-1 max-w-2xl text-sm text-ink-500">{sub}</p>}
      </div>
      {actions}
    </div>
  );
}

export const Panel = ({ title, aside, children, className = '' }: { title?: string; aside?: ReactNode; children: ReactNode; className?: string }) => (
  <section className={`rounded-lg border border-line bg-white ${className}`}>
    {title && (
      <header className="flex items-center justify-between border-b border-line px-4 py-3">
        <h2 className="text-sm font-semibold text-ink">{title}</h2>{aside}
      </header>
    )}
    <div className="p-4">{children}</div>
  </section>
);

export function Stat({ name, value, hint, tone }: { name: string; value: ReactNode; hint?: string; tone?: 'warn' | 'bad' }) {
  const c = tone === 'bad' ? 'text-coral' : tone === 'warn' ? 'text-amber' : 'text-ink';
  return (
    <div className="rounded-lg border border-line bg-white px-4 py-3">
      <div className="text-xs text-ink-500">{name}</div>
      <div className={`mt-1 text-2xl font-semibold tabular-nums ${c}`}>{value}</div>
      {hint && <div className="mt-0.5 text-xs text-ink-300">{hint}</div>}
    </div>
  );
}

const TONES: Record<string, string> = {
  good: 'bg-moss-100 text-moss', warn: 'bg-amber-100 text-amber', bad: 'bg-coral-100 text-coral',
  info: 'bg-sea-100 text-sea-600', mute: 'bg-paper text-ink-500 border border-line',
};
const STATUS_TONE: Record<string, string> = {
  completed: 'good', approved: 'good', active: 'good', remitted: 'good', delivered: 'good', returned: 'good',
  cancelled: 'mute', declined: 'mute', waived: 'mute', draft: 'mute', inactive: 'mute', voided: 'mute',
  rejected: 'bad', suspended: 'bad', overdue: 'bad', failed: 'bad', expired: 'bad', revoked: 'bad',
  pending: 'warn', submitted: 'warn', under_review: 'warn', needs_resubmission: 'warn', pending_verification: 'warn',
  searching: 'warn', awaiting_acceptance: 'warn', requested: 'warn', awaiting_owner: 'warn', available: 'warn',
};
export const Badge = ({ status, tone }: { status: string | null | undefined; tone?: keyof typeof TONES }) => (
  <span className={`inline-block whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium capitalize ${TONES[tone ?? STATUS_TONE[status ?? ''] ?? 'info']}`}>
    {label(status)}
  </span>
);

export const Empty = ({ title, hint }: { title: string; hint?: string }) => (
  <div className="rounded-lg border border-dashed border-line bg-white px-6 py-12 text-center">
    <p className="font-medium text-ink">{title}</p>
    {hint && <p className="mx-auto mt-1 max-w-md text-sm text-ink-500">{hint}</p>}
  </div>
);

export const Unavailable = ({ children }: { children: ReactNode }) => (
  <span className="text-sm text-ink-300" title="Not available from current records">{children ?? 'Unavailable'}</span>
);

export function Table({ head, children, empty }: { head: string[]; children: ReactNode[] | ReactNode; empty?: ReactNode }) {
  const rows = Array.isArray(children) ? children : [children];
  if (!rows.length || (rows.length === 1 && !rows[0])) return <>{empty ?? <Empty title="No records" />}</>;
  return (
    <div className="overflow-x-auto rounded-lg border border-line bg-white">
      <table className="w-full text-left text-sm">
        <thead className="border-b border-line bg-paper text-xs text-ink-500">
          <tr>{head.map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 font-medium">{h}</th>)}</tr>
        </thead>
        <tbody className="divide-y divide-line [&_td]:px-3 [&_td]:py-2.5 [&_td]:align-top">{children}</tbody>
      </table>
    </div>
  );
}

export function Filters({ children, action }: { children: ReactNode; action: string }) {
  return (
    <form action={action} className="mb-4 flex flex-wrap items-end gap-3 rounded-lg border border-line bg-white p-3">
      {children}
      <button className="rounded-md bg-ink px-3 py-2 text-sm font-medium text-white hover:bg-ink-700">Apply</button>
      <Link href={action} className="py-2 text-sm text-ink-500 hover:text-ink">Reset</Link>
    </form>
  );
}
export const Field = ({ name, label: l, children }: { name?: string; label: string; children: ReactNode }) => (
  <label className="flex flex-col gap-1 text-xs text-ink-500" htmlFor={name}>{l}{children}</label>
);
const base = 'rounded-md border border-line bg-white px-2.5 py-2 text-sm text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-sea';
export const Input = (p: React.InputHTMLAttributes<HTMLInputElement>) => <input id={p.name} {...p} className={`${base} ${p.className ?? ''}`} />;
export const Select = ({ options, ...p }: React.SelectHTMLAttributes<HTMLSelectElement> & { options: [string, string][] }) => (
  <select id={p.name} {...p} className={base}>{options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
);

export function Pager({ base: href, params, page, count }: { base: string; params: Record<string, string | undefined>; page: number; count: number }) {
  const pages = Math.max(1, Math.ceil(count / 25));
  const mk = (p: number) => {
    const q = new URLSearchParams(Object.entries(params).filter(([, v]) => v) as [string, string][]);
    q.set('page', String(p)); return `${href}?${q}`;
  };
  return (
    <div className="mt-3 flex items-center justify-between text-sm text-ink-500">
      <span>{count.toLocaleString()} record{count === 1 ? '' : 's'}</span>
      <div className="flex items-center gap-3">
        {page > 1 && <Link className="hover:text-ink" href={mk(page - 1)}>Previous</Link>}
        <span>Page {page} of {pages}</span>
        {page < pages && <Link className="hover:text-ink" href={mk(page + 1)}>Next</Link>}
      </div>
    </div>
  );
}
export const Who = ({ p, id, href }: { p?: { full_name?: string } | null; id?: string | null; href?: boolean }) =>
  p?.full_name ? (href && id ? <Link className="text-sea-600 hover:underline" href={`/users/${id}`}>{p.full_name}</Link> : <>{p.full_name}</>) : <span className="text-ink-300">Unassigned</span>;
