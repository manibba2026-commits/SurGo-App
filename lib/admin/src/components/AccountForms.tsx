'use client';
import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { attachCreatedDocuments, setAvatar } from '@/app/actions';

const AVATAR_MAX = 5 * 1024 * 1024;
const DOCUMENT_MAX = 10 * 1024 * 1024;
const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
const DOCUMENT_TYPES = ['application/pdf', 'image/jpeg', 'image/png'];

const extension = (name: string) => {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  return /^[a-z0-9]{1,5}$/.test(ext) ? ext : 'bin';
};

const ROLE_OPTIONS = [
  { key: 'passenger', label: 'Passenger', hint: 'Baseline role for every account.' },
  { key: 'earner', label: 'Helper', hint: 'Pabili and errand work. No documents required.' },
  { key: 'rider', label: 'Rider', hint: 'Documents must be reviewed before approval.' },
  { key: 'vehicle_owner', label: 'Vehicle owner', hint: 'Documents must be reviewed before approval.' },
];
const DOC_SLOTS = [
  { type: 'government_id', label: 'Government ID' },
  { type: 'drivers_license', label: "Driver's license" },
  { type: 'vehicle_registration', label: 'Vehicle registration' },
];

const input = 'mt-1 w-full rounded-md border border-line bg-white px-2.5 py-2 text-sm text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-sea';

type Created = { id: string; tempPassword: string; warnings: string[] };

/** Create User: the Auth row and roles are made by the server route; files go
 *  straight from this browser to a private bucket under the new account id. */
export function CreateUserForm() {
  const [fields, setFields] = useState({ full_name: '', email: '', phone: '', address: '', barangay: '' });
  const [roles, setRoles] = useState<string[]>(['passenger']);
  const [avatar, setAvatarFile] = useState<File | null>(null);
  const [docs, setDocs] = useState<Record<string, { file: File | null; number: string }>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<Created | null>(null);
  const [copied, setCopied] = useState(false);

  const set = (key: keyof typeof fields) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setFields((f) => ({ ...f, [key]: e.target.value }));
  const toggleRole = (key: string) => {
    if (key === 'passenger') return;
    setRoles((r) => (r.includes(key) ? r.filter((x) => x !== key) : [...r, key]));
  };
  const setDoc = (type: string, patch: Partial<{ file: File | null; number: string }>) =>
    setDocs((d) => {
      const current = d[type] ?? { file: null, number: '' };
      return { ...d, [type]: { ...current, ...patch } };
    });

  const needsDocuments = roles.includes('rider') || roles.includes('vehicle_owner');

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    if (!fields.full_name.trim()) return setError('Full name is required.');
    if (!fields.email.trim() && !fields.phone.trim()) return setError('Enter an email address or a phone number.');
    if (avatar && avatar.size > AVATAR_MAX) return setError('Profile photos must be 5 MB or smaller.');
    if (avatar && !IMAGE_TYPES.includes(avatar.type)) return setError('Profile photos must be JPEG, PNG or WebP.');
    for (const slot of DOC_SLOTS) {
      const file = docs[slot.type]?.file;
      if (!file) continue;
      if (file.size > DOCUMENT_MAX) return setError(`${slot.label} must be 10 MB or smaller.`);
      if (!DOCUMENT_TYPES.includes(file.type)) return setError(`${slot.label} must be a PDF, JPEG or PNG.`);
    }

    setBusy(true);
    try {
      const res = await fetch('/api/admin/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...fields, roles }),
      });
      const data = (await res.json()) as { id?: string; tempPassword?: string; warnings?: string[]; error?: string };
      if (!res.ok || !data.id) {
        setError(data.error ?? 'Account creation failed.');
        return;
      }
      const id = data.id;
      const warnings = [...(data.warnings ?? [])];
      const sb = createClient();

      if (avatar) {
        const path = `${id}/avatar-${Date.now()}.${extension(avatar.name)}`;
        const { error: uploadError } = await sb.storage
          .from('avatars')
          .upload(path, avatar, { contentType: avatar.type });
        if (uploadError) warnings.push(`Profile photo was not uploaded: ${uploadError.message}`);
        else {
          const fd = new FormData();
          fd.set('id', id);
          fd.set('avatar_path', path);
          const result = await setAvatar(null, fd);
          if (result?.error) warnings.push(`Profile photo was not saved: ${result.error}`);
        }
      }

      const uploaded: { type: string; label: string; path: string; number: string | null }[] = [];
      for (const slot of DOC_SLOTS) {
        const entry = docs[slot.type];
        if (!entry?.file) continue;
        const path = `${id}/${slot.type}-${Date.now()}.${extension(entry.file.name)}`;
        const { error: uploadError } = await sb.storage
          .from('verification-documents')
          .upload(path, entry.file, { contentType: entry.file.type });
        if (uploadError) {
          warnings.push(`${slot.label} was not uploaded: ${uploadError.message}`);
          continue;
        }
        uploaded.push({ type: slot.type, label: slot.label, path, number: entry.number.trim() || null });
      }

      const capabilities = roles.filter((r) => r === 'rider' || r === 'vehicle_owner');
      if (uploaded.length && capabilities.length) {
        const fd = new FormData();
        fd.set('id', id);
        fd.set('capabilities', JSON.stringify(capabilities));
        fd.set('documents', JSON.stringify(uploaded));
        const result = await attachCreatedDocuments(null, fd);
        if (result?.error) warnings.push(`Documents were not attached: ${result.error}`);
      }

      setCreated({ id, tempPassword: data.tempPassword!, warnings });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Account creation failed.');
    } finally {
      setBusy(false);
    }
  }

  if (created) {
    return (
      <section className="rounded-lg border border-line bg-white p-5">
        <h2 className="text-lg font-semibold text-ink">Account created</h2>
        <p className="mt-1 text-sm text-ink-500">
          Share the temporary password with the account holder through a private channel. It is shown once and is not stored.
        </p>
        <div className="mt-3 flex flex-wrap items-center gap-2 rounded-md border border-line bg-paper px-3 py-2">
          <code className="text-sm text-ink">{created.tempPassword}</code>
          <button
            type="button"
            className="rounded-md border border-line bg-white px-2 py-1 text-xs font-medium text-ink hover:bg-paper"
            onClick={() => { navigator.clipboard.writeText(created.tempPassword); setCopied(true); }}
          >
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
        {created.warnings.length > 0 && (
          <div className="mt-3 rounded-md border border-line bg-paper p-3">
            <p className="text-xs font-medium text-coral">Account created, but some setup steps need attention:</p>
            <ul className="mt-1 list-disc pl-5 text-xs text-ink-500">
              {created.warnings.map((w) => <li key={w}>{w}</li>)}
            </ul>
          </div>
        )}
        <div className="mt-4 flex flex-wrap gap-3">
          <Link href={`/users/${created.id}`} className="rounded-md bg-sea px-3 py-2 text-sm font-medium text-white hover:bg-sea-600">
            Open account
          </Link>
          <button
            type="button"
            className="rounded-md border border-line bg-white px-3 py-2 text-sm font-medium text-ink hover:bg-paper"
            onClick={() => {
              setCreated(null); setCopied(false); setAvatarFile(null); setDocs({});
              setFields({ full_name: '', email: '', phone: '', address: '', barangay: '' });
              setRoles(['passenger']);
            }}
          >
            Create another
          </button>
        </div>
      </section>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <section className="rounded-lg border border-line bg-white p-4">
        <h2 className="text-sm font-semibold text-ink">Profile details</h2>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="text-xs text-ink-500">Full name *
            <input value={fields.full_name} onChange={set('full_name')} required className={input} />
          </label>
          <label className="text-xs text-ink-500">Email
            <input type="email" value={fields.email} onChange={set('email')} className={input} autoComplete="off" />
          </label>
          <label className="text-xs text-ink-500">Phone
            <input value={fields.phone} onChange={set('phone')} placeholder="+639171234567" className={input} autoComplete="off" />
          </label>
          <label className="text-xs text-ink-500">Barangay
            <input value={fields.barangay} onChange={set('barangay')} className={input} />
          </label>
          <label className="text-xs text-ink-500 sm:col-span-2">Address
            <input value={fields.address} onChange={set('address')} className={input} />
          </label>
        </div>
        <p className="mt-2 text-xs text-ink-300">At least one of email or phone is required. Duplicates are refused.</p>
      </section>

      <section className="rounded-lg border border-line bg-white p-4">
        <h2 className="text-sm font-semibold text-ink">Roles</h2>
        <p className="mt-1 text-xs text-ink-500">
          Creating an account is separate from approving a role. Passenger and Helper are active immediately; Rider and Vehicle owner stay pending until their documents are reviewed.
        </p>
        <ul className="mt-3 space-y-2">
          {ROLE_OPTIONS.map((r) => (
            <li key={r.key} className="flex items-start gap-3">
              <input
                type="checkbox"
                id={`role-${r.key}`}
                checked={roles.includes(r.key)}
                disabled={r.key === 'passenger'}
                onChange={() => toggleRole(r.key)}
                className="mt-1"
              />
              <label htmlFor={`role-${r.key}`} className="text-sm">
                <span className="font-medium text-ink">{r.label}</span>
                <span className="ml-2 text-xs text-ink-500">{r.hint}</span>
              </label>
            </li>
          ))}
        </ul>
      </section>

      <section className="rounded-lg border border-line bg-white p-4">
        <h2 className="text-sm font-semibold text-ink">Photo and documents</h2>
        <p className="mt-1 text-xs text-ink-500">
          Optional at creation. Files are stored in the private document buckets under the new account id.
        </p>
        <label className="mt-3 block text-xs text-ink-500">Profile photo (JPEG/PNG/WebP, max 5 MB)
          <input type="file" accept="image/jpeg,image/png,image/webp" onChange={(e) => setAvatarFile(e.target.files?.[0] ?? null)} className="mt-1 block w-full text-sm" />
        </label>
        {needsDocuments && (
          <div className="mt-4 space-y-3">
            {DOC_SLOTS.map((slot) => (
              <div key={slot.type} className="grid gap-2 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                <label className="text-xs text-ink-500">{slot.label} (PDF/JPEG/PNG, max 10 MB)
                  <input
                    type="file"
                    accept="application/pdf,image/jpeg,image/png"
                    onChange={(e) => setDoc(slot.type, { file: e.target.files?.[0] ?? null })}
                    className="mt-1 block w-full text-sm"
                  />
                </label>
                <label className="text-xs text-ink-500">Document number
                  <input
                    value={docs[slot.type]?.number ?? ''}
                    onChange={(e) => setDoc(slot.type, { number: e.target.value })}
                    className={input}
                  />
                </label>
              </div>
            ))}
            <p className="text-xs text-ink-300">
              Files attach to every Rider and Vehicle owner application opened for this account and start as pending.
            </p>
          </div>
        )}
      </section>

      {error && <p role="alert" className="text-sm text-coral">{error}</p>}
      <div className="flex items-center gap-3">
        <button disabled={busy} className="rounded-md bg-sea px-4 py-2 text-sm font-medium text-white hover:bg-sea-600 disabled:opacity-50">
          {busy ? 'Creating account…' : 'Create account'}
        </button>
        <Link href="/users" className="text-sm text-ink-500 hover:text-ink">Cancel</Link>
      </div>
    </form>
  );
}

/** Contact details live in Auth; the route updates both stores and audits it. */
export function ContactForm({ id, email, phone }: { id: string; email: string | null; phone: string | null }) {
  const router = useRouter();
  const [values, setValues] = useState({ email: email ?? '', phone: phone ?? '' });
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null); setMessage(null);
    try {
      const res = await fetch(`/api/admin/users/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(values),
      });
      const data = (await res.json()) as { ok?: boolean; error?: string };
      if (!res.ok) { setError(data.error ?? 'Contact update failed.'); return; }
      setMessage('Contact details updated.');
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Contact update failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <p className="text-xs text-ink-500">
        Changing the sign-in address also updates the account&apos;s Auth identity. Leave a field blank to keep its current value.
      </p>
      <label className="block text-xs text-ink-500">Email
        <input type="email" value={values.email} onChange={(e) => setValues((v) => ({ ...v, email: e.target.value }))} className={input} />
      </label>
      <label className="block text-xs text-ink-500">Phone
        <input value={values.phone} onChange={(e) => setValues((v) => ({ ...v, phone: e.target.value }))} className={input} />
      </label>
      <div className="flex items-center gap-3">
        <button disabled={busy} className="rounded-md border border-line bg-white px-3 py-1.5 text-sm font-medium text-ink hover:bg-paper disabled:opacity-50">
          {busy ? 'Saving…' : 'Save contact'}
        </button>
        {error && <span role="alert" className="text-sm text-coral">{error}</span>}
        {message && <span role="status" className="text-sm text-moss">{message}</span>}
      </div>
    </form>
  );
}

/** Uploads a new profile photo, then records the path through the audited RPC. */
export function AvatarUpload({ id, hasAvatar }: { id: string; hasAvatar: boolean }) {
  const router = useRouter();
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!file) return setError('Choose an image first.');
    if (file.size > AVATAR_MAX) return setError('Profile photos must be 5 MB or smaller.');
    if (!IMAGE_TYPES.includes(file.type)) return setError('Profile photos must be JPEG, PNG or WebP.');
    setBusy(true); setError(null);
    try {
      const path = `${id}/avatar-${Date.now()}.${extension(file.name)}`;
      const { error: uploadError } = await createClient().storage
        .from('avatars')
        .upload(path, file, { contentType: file.type });
      if (uploadError) { setError(uploadError.message); return; }
      const fd = new FormData();
      fd.set('id', id);
      fd.set('avatar_path', path);
      const result = await setAvatar(null, fd);
      if (result?.error) { setError(result.error); return; }
      setFile(null);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Photo upload failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="space-y-2">
      <input type="file" accept="image/jpeg,image/png,image/webp" onChange={(e) => setFile(e.target.files?.[0] ?? null)} className="block w-full text-sm" />
      <div className="flex items-center gap-3">
        <button disabled={busy} className="rounded-md border border-line bg-white px-3 py-1.5 text-sm font-medium text-ink hover:bg-paper disabled:opacity-50">
          {busy ? 'Uploading…' : hasAvatar ? 'Replace photo' : 'Upload photo'}
        </button>
        {error && <span role="alert" className="text-sm text-coral">{error}</span>}
      </div>
    </form>
  );
}

/** Remove a photo without replacing it. */
export function AvatarClear({ id }: { id: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="mt-2">
      <button
        type="button"
        disabled={busy}
        className="text-xs text-coral hover:underline disabled:opacity-50"
        onClick={async () => {
          setBusy(true); setError(null);
          const fd = new FormData();
          fd.set('id', id);
          const result = await setAvatar(null, fd);
          if (result?.error) setError(result.error);
          else router.refresh();
          setBusy(false);
        }}
      >
        {busy ? 'Removing…' : 'Remove photo'}
      </button>
      {error && <span role="alert" className="ml-2 text-xs text-coral">{error}</span>}
    </div>
  );
}
