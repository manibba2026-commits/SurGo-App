import type { SupabaseClient } from '@supabase/supabase-js';
import { okOrMissing, type Row } from './query.ts';
import { fileStates, type FileState } from './verification.ts';

/** Private bucket added by `20261111120000_attachments.sql`. */
export const ATTACHMENT_BUCKET = 'attachments';

/** Mirrors the bucket limit and the `attachments_size_check` constraint. */
export const ATTACHMENT_MAX_BYTES = 20 * 1024 * 1024;

/** The one allowlist. The bucket, the table check and the RPCs carry the same
 *  set; this copy keeps the browser from starting a doomed upload. SVG is
 *  deliberately absent: a signed URL can render it as an active document. */
export const ATTACHMENT_MIME_BY_EXTENSION: Record<string, string> = {
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  rtf: 'application/rtf',
  txt: 'text/plain',
  xls: 'application/vnd.ms-excel',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  csv: 'text/csv',
  ppt: 'application/vnd.ms-powerpoint',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  gif: 'image/gif',
  heic: 'image/heic',
  heif: 'image/heif',
  bmp: 'image/bmp',
  tiff: 'image/tiff',
  tif: 'image/tiff',
  zip: 'application/zip',
  mp3: 'audio/mpeg',
  m4a: 'audio/mp4',
  aac: 'audio/aac',
  ogg: 'audio/ogg',
  wav: 'audio/wav',
  flac: 'audio/flac',
  weba: 'audio/webm',
  mp4: 'video/mp4',
  webm: 'video/webm',
  mov: 'video/quicktime',
  avi: 'video/x-msvideo',
  mkv: 'video/x-matroska',
  mpeg: 'video/mpeg',
  mpg: 'video/mpeg',
  '3gp': 'video/3gpp',
};

export const ATTACHMENT_EXTENSIONS = Object.keys(ATTACHMENT_MIME_BY_EXTENSION);

/** What the file input offers. Browsers fall back to all files when a type is
 *  unknown, so the server-side extension check still runs. */
export const ATTACHMENT_ACCEPT = ATTACHMENT_EXTENSIONS.map((ext) => `.${ext}`).join(',');

export const attachmentExtension = (name: string): string => {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  return /^[a-z0-9]{1,5}$/.test(ext) ? ext : '';
};

/** MIME from the extension, or null when the type is not allowed. The browser's
 *  `File.type` is not trusted: it is empty for several allowed types (CSV, HEIC)
 *  and can be forged. */
export const attachmentMimeType = (name: string): string | null =>
  ATTACHMENT_MIME_BY_EXTENSION[attachmentExtension(name)] ?? null;

/** A fresh object name inside the owner's folder. The database repeats the
 *  folder check, so a tampered path cannot file bytes under another account. */
export function newAttachmentPath(profileId: string, fileName: string): string {
  const token = typeof globalThis.crypto?.randomUUID === 'function'
    ? globalThis.crypto.randomUUID().slice(0, 8)
    : Math.random().toString(16).slice(2, 10);
  return `${profileId}/${Date.now()}-${token}.${attachmentExtension(fileName) || 'bin'}`;
}

/** A short reason the file cannot be uploaded, or null when it can. */
export function attachmentRejection(file: { name: string; size: number }): string | null {
  if (file.size < 1) return `${file.name} is empty.`;
  if (file.size > ATTACHMENT_MAX_BYTES) {
    return `${file.name} is larger than 20 MB.`;
  }
  if (!attachmentMimeType(file.name)) {
    return `${file.name} is not a supported file type.`;
  }
  return null;
}

/** Same grouping the database generates into `attachments.category`. */
export function attachmentCategory(mime: string): string {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('audio/')) return 'audio';
  if (mime.startsWith('video/')) return 'video';
  if (mime === 'application/zip' || mime === 'application/x-zip-compressed') return 'archive';
  if (['application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'text/csv', 'application/csv'].includes(mime)) return 'spreadsheet';
  if (['application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'].includes(mime)) return 'presentation';
  if (['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/rtf', 'text/rtf', 'text/plain'].includes(mime)) return 'document';
  return 'other';
}

export function attachmentSizeLabel(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(bytes >= 10 * 1024 ? 0 : 1)} KB`;
  return `${bytes} B`;
}

export type AttachmentBundle = {
  rows: Row[];
  files: Map<string, FileState>;
};

/**
 * Every attachment row for one account, plus the honest state of each object.
 * `null` means the attachments migration has not been applied to this project
 * yet; the panel says so instead of taking the page down.
 */
export async function attachmentsForProfile(db: SupabaseClient, profileId: string): Promise<AttachmentBundle | null> {
  const result = await db
    .from('attachments')
    .select('id,owner_profile_id,bucket_id,storage_path,file_name,mime_type,size_bytes,category,label,uploaded_by,created_at,updated_at')
    .eq('owner_profile_id', profileId)
    .order('created_at', { ascending: false });
  const rows = okOrMissing<Row[]>(result as any, 'Attachments');
  if (rows === null) return null;

  let files = new Map<string, FileState>();
  if (rows.length) {
    try {
      files = await fileStates(db, ATTACHMENT_BUCKET, rows.map((row) => row.storage_path));
    } catch {
      // A listing failure is reported per row as "preview unavailable" rather
      // than hiding the metadata that did load.
      rows.forEach((row) => files.set(row.storage_path, { present: false, url: null }));
    }
  }
  return { rows, files };
}

/** What the panel says about one row's bytes. Null means a signed URL is ready. */
export function attachmentFileState(row: Row, file?: FileState): { text: string; hint: string } | null {
  if (!row.storage_path) return { text: 'No file on record', hint: 'The row does not name a stored object.' };
  if (file?.url) return null;
  if (file?.present === false) {
    return { text: 'No file on record', hint: `The row references ${row.storage_path}, but that object is not in the bucket.` };
  }
  return { text: 'Preview unavailable', hint: 'The file listing did not answer.' };
}
