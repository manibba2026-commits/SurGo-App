'use client';
import { useFormState, useFormStatus } from 'react-dom';
import type { ActionState } from '@/app/actions';

function Submit({ label, tone }: { label: string; tone: 'primary' | 'danger' | 'quiet' }) {
  const { pending } = useFormStatus();
  const cls = {
    primary: 'bg-sea text-white hover:bg-sea-600',
    danger: 'bg-coral text-white hover:opacity-90',
    quiet: 'border border-line bg-white text-ink hover:bg-paper',
  }[tone];
  return (
    <button disabled={pending} className={`rounded-md px-3 py-1.5 text-sm font-medium disabled:opacity-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sea ${cls}`}>
      {pending ? 'Saving…' : label}
    </button>
  );
}

/** Small inline form wired to a server action; shows the server's result next to the button.
 *  `disabledReason` renders the action as unavailable with the reason beside it,
 *  for decisions the database would refuse anyway. */
export function ActionForm({
  action, label, tone = 'primary', hidden, children, confirm, disabledReason, className = '',
}: {
  action: (s: ActionState, f: FormData) => Promise<ActionState>;
  label: string; tone?: 'primary' | 'danger' | 'quiet';
  hidden: Record<string, string>; children?: React.ReactNode; confirm?: string;
  disabledReason?: string | null; className?: string;
}) {
  const [state, formAction] = useFormState(action, null);
  if (disabledReason) {
    return (
      <div className={`flex flex-wrap items-center gap-2 ${className}`}>
        <button
          type="button"
          disabled
          title={disabledReason}
          className="cursor-not-allowed rounded-md border border-line bg-paper px-3 py-1.5 text-sm font-medium text-ink-300"
        >
          {label}
        </button>
        <span className="text-xs text-coral">{disabledReason}</span>
      </div>
    );
  }
  return (
    <form action={formAction} className={`flex flex-wrap items-center gap-2 ${className}`}
      onSubmit={(e) => { if (confirm && !window.confirm(confirm)) e.preventDefault(); }}>
      {Object.entries(hidden).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
      {children}
      <Submit label={label} tone={tone} />
      {state?.error && <span role="alert" className="text-sm text-coral">{state.error}</span>}
      {state?.ok && <span role="status" className="text-sm text-moss">{state.ok}</span>}
    </form>
  );
}
