'use client';
import { useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import {
  ATTACHMENT_ACCEPT,
  ATTACHMENT_BUCKET,
  attachmentFileState,
  attachmentMimeType,
  attachmentRejection,
  attachmentSizeLabel,
  newAttachmentPath,
} from '@/lib/attachments';
import type { Row } from '@/lib/query';
import type { FileState } from '@/lib/verification';
import { deleteAttachment, registerAttachment, replaceAttachment } from '@/app/actions';

const input = 'mt-1 w-full rounded-md border border-line bg-white px-2.5 py-1.5 text-sm text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-sea';

/**
 * Admin-side file management for one account.
 *
 * Bytes go from the browser straight to the private `attachments` bucket under
 * the account's own folder, using the administrator's session (the storage
 * policy grants admins any folder). The server action then asks the audited RPC
 * to record the row; if that is refused, the uploaded object is removed again.
 * Nothing is shown as uploaded until the metadata write succeeds.
 */
export function AttachmentsManager({
  profileId,
  rows,
  files,
}: {
  profileId: string;
  rows: Row[];
  files: Record<string, FileState>;
}) {
  const router = useRouter();
  const [selected, setSelected] = useState<FileList | null>(null);
  const [label, setLabel] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  async function upload(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setOk(null);
    const list = Array.from(selected ?? []);
    if (!list.length) return setError('Choose at least one file.');

    for (const file of list) {
      const rejection = attachmentRejection(file);
      if (rejection) return setError(rejection);
    }

    setBusy('Uploading…');
    let added = 0;
    let firstError: string | null = null;
    const db = createClient();

    for (const file of list) {
      const mime = attachmentMimeType(file.name);
      if (!mime) {
        firstError ??= `${file.name} is not a supported file type.`;
        continue;
      }
      const path = newAttachmentPath(profileId, file.name);
      const { error: uploadError } = await db.storage
        .from(ATTACHMENT_BUCKET)
        .upload(path, file, { contentType: mime, upsert: false });
      if (uploadError) {
        firstError ??= `${file.name}: ${uploadError.message}`;
        continue;
      }

      setBusy(`Saving ${file.name}…`);
      const fd = new FormData();
      fd.set('id', profileId);
      fd.set('storage_path', path);
      fd.set('file_name', file.name);
      fd.set('mime_type', mime);
      fd.set('size_bytes', String(file.size));
      fd.set('label', label);
      const result = await registerAttachment(null, fd);
      if (result?.error) {
        // The row was not recorded, so the object must not stay behind.
        await db.storage.from(ATTACHMENT_BUCKET).remove([path]);
        firstError ??= `${file.name}: ${result.error}`;
      } else {
        added += 1;
      }
    }

    setBusy(null);
    setSelected(null);
    setLabel('');
    if (fileInput.current) fileInput.current.value = '';
    if (added) {
      setOk(added === 1 ? 'File added.' : `${added} files added.`);
      router.refresh();
    }
    if (firstError) setError(firstError);
  }

  return (
    <div className="space-y-4">
      <form onSubmit={upload} className="space-y-2 rounded-md border border-dashed border-line bg-paper p-3">
        <div className="grid gap-2 sm:grid-cols-2">
          <label className="text-xs text-ink-500">
            Files (max 20 MB each)
            <input
              ref={fileInput}
              type="file"
              multiple
              accept={ATTACHMENT_ACCEPT}
              onChange={(e) => setSelected(e.target.files)}
              className="mt-1 block w-full text-sm"
            />
          </label>
          <label className="text-xs text-ink-500">
            Display label (optional)
            <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. Signed contract" className={input} />
          </label>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          <button
            disabled={!!busy}
            className="rounded-md bg-ink px-3 py-1.5 text-sm font-medium text-white hover:bg-ink-700 disabled:opacity-50"
          >
            {busy ? 'Working…' : 'Upload files'}
          </button>
          {busy && <span className="text-xs text-ink-500">{busy}</span>}
          {error && <span role="alert" className="text-xs text-coral">{error}</span>}
          {ok && <span role="status" className="text-xs text-moss">{ok}</span>}
        </div>
        {busy && (
          <div className="h-1 w-full overflow-hidden rounded bg-line">
            <div className="h-1 w-1/2 animate-pulse rounded bg-sea" />
          </div>
        )}
      </form>

      {rows.length === 0 ? (
        <p className="text-sm text-ink-500">No files on this account yet.</p>
      ) : (
        <ul className="divide-y divide-line rounded-md border border-line">
          {rows.map((row) => (
            <AttachmentRow
              key={row.id}
              profileId={profileId}
              row={row}
              file={files[row.storage_path]}
              disabled={!!busy}
              onBusy={setBusy}
              onDone={(message) => {
                setError(null);
                setOk(message);
                router.refresh();
              }}
              onError={(message) => {
                setOk(null);
                setError(message);
              }}
            />
          ))}
        </ul>
      )}
    </div>
  );
}

function AttachmentRow({
  profileId,
  row,
  file,
  disabled,
  onBusy,
  onDone,
  onError,
}: {
  profileId: string;
  row: Row;
  file?: FileState;
  disabled: boolean;
  onBusy: (message: string | null) => void;
  onDone: (message: string) => void;
  onError: (message: string) => void;
}) {
  const replaceInput = useRef<HTMLInputElement>(null);
  const state = attachmentFileState(row, file);
  const url = file?.url ?? null;

  async function replace(fileList: FileList | null) {
    const next = fileList?.[0];
    if (!next) return;
    const rejection = attachmentRejection(next);
    if (rejection) return onError(rejection);
    const mime = attachmentMimeType(next.name);
    if (!mime) return onError('That file type is not supported.');

    onBusy(`Uploading ${next.name}…`);
    const db = createClient();
    const path = newAttachmentPath(profileId, next.name);
    const { error: uploadError } = await db.storage
      .from(ATTACHMENT_BUCKET)
      .upload(path, next, { contentType: mime, upsert: false });
    if (uploadError) {
      onBusy(null);
      return onError(`${next.name}: ${uploadError.message}`);
    }

    onBusy(`Saving ${next.name}…`);
    const fd = new FormData();
    fd.set('id', row.id);
    fd.set('owner_id', profileId);
    fd.set('storage_path', path);
    fd.set('file_name', next.name);
    fd.set('mime_type', mime);
    fd.set('size_bytes', String(next.size));
    const result = await replaceAttachment(null, fd);
    if (result?.error) {
      await db.storage.from(ATTACHMENT_BUCKET).remove([path]);
      onBusy(null);
      return onError(result.error);
    }
    onBusy(null);
    if (replaceInput.current) replaceInput.current.value = '';
    onDone(result?.ok ?? 'File replaced.');
  }

  async function remove() {
    if (!window.confirm(`Delete ${row.label ?? row.file_name}? This cannot be undone.`)) return;
    onBusy('Deleting…');
    const fd = new FormData();
    fd.set('id', row.id);
    fd.set('owner_id', profileId);
    const result = await deleteAttachment(null, fd);
    onBusy(null);
    if (result?.error) return onError(result.error);
    onDone(result?.ok ?? 'File deleted.');
  }

  return (
    <li className="flex flex-wrap items-start justify-between gap-3 px-3 py-3 text-sm">
      <div className="min-w-0">
        <div className="truncate font-medium text-ink">{row.label ?? row.file_name}</div>
        <div className="mt-0.5 text-xs text-ink-500">
          {[row.category, attachmentSizeLabel(Number(row.size_bytes)), row.created_at ? new Date(row.created_at).toLocaleString() : null]
            .filter(Boolean)
            .join(' · ')}
        </div>
        {row.label && <div className="truncate text-xs text-ink-300">{row.file_name}</div>}
        {state ? (
          <div className="mt-1 text-xs text-ink-300" title={state.hint}>{state.text}</div>
        ) : (
          <a href={url ?? undefined} target="_blank" rel="noreferrer" className="mt-1 inline-block text-xs font-medium text-sea-600 hover:underline">
            Open file
          </a>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <input
          ref={replaceInput}
          type="file"
          accept={ATTACHMENT_ACCEPT}
          className="hidden"
          onChange={(e) => {
            replace(e.target.files);
            e.target.value = '';
          }}
        />
        <button
          type="button"
          disabled={disabled}
          onClick={() => replaceInput.current?.click()}
          className="rounded-md border border-line bg-white px-2.5 py-1 text-xs font-medium text-ink hover:bg-paper disabled:opacity-50"
        >
          Replace
        </button>
        <button
          type="button"
          disabled={disabled}
          onClick={remove}
          className="rounded-md border border-line bg-white px-2.5 py-1 text-xs font-medium text-coral hover:bg-paper disabled:opacity-50"
        >
          Delete
        </button>
      </div>
    </li>
  );
}
