'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { attachVerificationDocument, attachVehicleDocument } from '@/app/actions';

const MAX = 10 * 1024 * 1024;
const TYPES = ['application/pdf', 'image/jpeg', 'image/png'];
const extension = (name: string) => {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  return /^[a-z0-9]{1,5}$/.test(ext) ? ext : 'bin';
};
const input = 'mt-1 w-full rounded-md border border-line bg-white px-2.5 py-1.5 text-sm text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-sea';

/**
 * Uploads one file straight to a private bucket under `profileId`, then asks the
 * audited RPC to attach it. Replacement resets the file to pending in the
 * database; this form only moves bytes.
 */
export function DocumentUpload({
  profileId,
  kind,
  targetId,
  types,
}: {
  profileId: string;
  kind: 'verification' | 'vehicle';
  targetId: string;
  types: [string, string][];
}) {
  const router = useRouter();
  const [documentType, setDocumentType] = useState(types[0]?.[0] ?? 'other');
  const [file, setFile] = useState<File | null>(null);
  const [label, setLabel] = useState('');
  const [number, setNumber] = useState('');
  const [expires, setExpires] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null); setOk(null);
    if (!file) return setError('Choose a file to upload.');
    if (file.size > MAX) return setError('Documents must be 10 MB or smaller.');
    if (!TYPES.includes(file.type)) return setError('Documents must be a PDF, JPEG or PNG.');

    setBusy(true);
    try {
      const bucket = kind === 'vehicle' ? 'vehicle-documents' : 'verification-documents';
      const path = `${profileId}/${kind}-${documentType}-${Date.now()}.${extension(file.name)}`;
      const { error: uploadError } = await createClient().storage
        .from(bucket)
        .upload(path, file, { contentType: file.type });
      if (uploadError) { setError(uploadError.message); return; }

      const fd = new FormData();
      fd.set('document_type', documentType);
      fd.set('storage_path', path);
      fd.set('document_number', number);
      fd.set('expires_at', expires);
      fd.set('label', label);
      if (kind === 'verification') fd.set('application_id', targetId);
      else fd.set('vehicle_id', targetId);

      const result = kind === 'verification'
        ? await attachVerificationDocument(null, fd)
        : await attachVehicleDocument(null, fd);
      if (result?.error) { setError(result.error); return; }

      setFile(null); setLabel(''); setNumber(''); setExpires('');
      setOk('Attached. It stays pending until a reviewer approves it.');
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Upload failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="mt-3 space-y-2 rounded-md border border-dashed border-line bg-paper p-3">
      <div className="grid gap-2 sm:grid-cols-2">
        <label className="text-xs text-ink-500">Document type
          <select value={documentType} onChange={(e) => setDocumentType(e.target.value)} className={input}>
            {types.map(([value, text]) => <option key={value} value={value}>{text}</option>)}
          </select>
        </label>
        <label className="text-xs text-ink-500">File (PDF/JPEG/PNG, max 10 MB)
          <input type="file" accept="application/pdf,image/jpeg,image/png" onChange={(e) => setFile(e.target.files?.[0] ?? null)} className="mt-1 block w-full text-sm" />
        </label>
        <label className="text-xs text-ink-500">Display name (optional)
          <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder={types.find(([v]) => v === documentType)?.[1]} className={input} />
        </label>
        <label className="text-xs text-ink-500">Document number (optional)
          <input value={number} onChange={(e) => setNumber(e.target.value)} className={input} />
        </label>
        <label className="text-xs text-ink-500">Expires (optional)
          <input type="date" value={expires} onChange={(e) => setExpires(e.target.value)} className={input} />
        </label>
      </div>
      <div className="flex items-center gap-3">
        <button disabled={busy} className="rounded-md bg-ink px-3 py-1.5 text-sm font-medium text-white hover:bg-ink-700 disabled:opacity-50">
          {busy ? 'Uploading…' : 'Upload and attach'}
        </button>
        {error && <span role="alert" className="text-xs text-coral">{error}</span>}
        {ok && <span role="status" className="text-xs text-moss">{ok}</span>}
      </div>
    </form>
  );
}
