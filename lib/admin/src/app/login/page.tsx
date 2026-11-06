'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';

export default function Login() {
  const router = useRouter();
  const [email, setEmail] = useState(''); const [password, setPassword] = useState('');
  const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setErr(null);
    const { error } = await createClient().auth.signInWithPassword({ email, password });
    if (error) { setErr(error.message); setBusy(false); return; }
    router.replace('/dashboard'); router.refresh();
  }
  return (
    <main className="grid min-h-screen lg:grid-cols-[1.1fr_1fr]">
      <section className="hidden flex-col justify-between bg-ink p-12 text-white lg:flex">
        <div className="text-xl font-semibold tracking-tight">SurGo</div>
        <div>
          <p className="max-w-md text-4xl font-semibold leading-tight tracking-tight">Every ride, rental and errand in Tandag City, in one place.</p>
          <p className="mt-4 max-w-md text-ink-300">Review verifications, follow trips, and see which platform fees have actually been remitted.</p>
        </div>
        <svg viewBox="0 0 400 40" className="w-full opacity-60" aria-hidden><path d="M0 24 C 40 6, 80 6, 120 24 S 200 42, 240 24 S 320 6, 400 24" fill="none" stroke="#0E7C86" strokeWidth="2" /></svg>
      </section>
      <section className="flex items-center justify-center p-8">
        <form onSubmit={submit} className="w-full max-w-sm space-y-4">
          <div><h1 className="text-2xl font-semibold tracking-tight">Administrator sign in</h1>
            <p className="mt-1 text-sm text-ink-500">Access requires an approved administrator role.</p></div>
          <label className="block text-sm">Email
            <input type="email" required autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} className="mt-1 w-full rounded-md border border-line bg-white px-3 py-2" /></label>
          <label className="block text-sm">Password
            <input type="password" required autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} className="mt-1 w-full rounded-md border border-line bg-white px-3 py-2" /></label>
          {err && <p role="alert" className="text-sm text-coral">{err}</p>}
          <button disabled={busy} className="w-full rounded-md bg-sea px-3 py-2.5 font-medium text-white hover:bg-sea-600 disabled:opacity-50">{busy ? 'Signing in…' : 'Sign in'}</button>
        </form>
      </section>
    </main>
  );
}
