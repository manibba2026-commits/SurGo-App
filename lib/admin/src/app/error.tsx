'use client';
export default function Error({ error, reset }: { error: Error; reset: () => void }) {
  return (
    <div className="mx-auto mt-20 max-w-lg rounded-lg border border-coral/30 bg-coral-100 p-6">
      <h1 className="text-lg font-semibold text-coral">This page could not load</h1>
      <p className="mt-2 break-words text-sm text-ink">{error.message}</p>
      <p className="mt-2 text-xs text-ink-500">Live data is never replaced with sample data. Check your connection and that your account has the administrator role.</p>
      <button onClick={reset} className="mt-4 rounded-md bg-ink px-3 py-2 text-sm font-medium text-white">Try again</button>
    </div>
  );
}
