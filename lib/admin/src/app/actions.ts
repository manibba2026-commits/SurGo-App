'use server';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { createClient } from '@/lib/supabase/server';
import {
  ATTACHMENT_BUCKET,
  ATTACHMENT_MAX_BYTES,
  attachmentMimeType,
} from '@/lib/attachments';

export type ActionState = { ok?: string; error?: string } | null;
const s = (f: FormData, k: string) => {
  const v = f.get(k);
  return typeof v === 'string' && v.trim() ? v.trim() : null;
};

/** Every action re-verifies admin server-side, then calls an audited SECURITY DEFINER RPC.
 *  Tables are never written from the browser. Paths revalidate as layouts so the
 *  per-person page (/users/[id]) refreshes together with its list page. */
async function run(rpc: string, args: Record<string, unknown>, paths: string[], okMsg: string): Promise<ActionState> {
  await requireAdmin();
  const { error } = await createClient().rpc(rpc, args);
  if (error) return { error: error.message };
  paths.forEach((p) => revalidatePath(p, 'layout'));
  return { ok: okMsg };
}

export async function reviewApplication(_: ActionState, f: FormData) {
  return run('admin_review_verification',
    { p_application_id: s(f, 'id'), p_decision: s(f, 'decision'), p_reason: s(f, 'reason') },
    ['/verification', '/dashboard', '/users'], 'Decision saved');
}
export async function reviewDocument(_: ActionState, f: FormData) {
  return run('admin_review_document',
    { p_kind: s(f, 'kind'), p_document_id: s(f, 'id'), p_decision: s(f, 'decision'), p_reason: s(f, 'reason') },
    ['/verification', '/users'], 'Document updated');
}
export async function setAccountStatus(_: ActionState, f: FormData) {
  return run('admin_set_account_status',
    { p_profile_id: s(f, 'id'), p_status: s(f, 'status'), p_reason: s(f, 'reason') },
    ['/users', '/dashboard'], 'Account updated');
}
export async function setVehicleStatus(_: ActionState, f: FormData) {
  return run('admin_set_vehicle_status',
    { p_vehicle_id: s(f, 'id'), p_status: s(f, 'status'), p_reason: s(f, 'reason') },
    ['/vehicles'], 'Vehicle updated');
}
export async function updateRemittance(_: ActionState, f: FormData) {
  return run('admin_update_remittance',
    { p_remittance_id: s(f, 'id'), p_status: s(f, 'status'), p_reference: s(f, 'reference'), p_notes: s(f, 'notes') },
    ['/finance', '/dashboard'], 'Remittance updated');
}

// Attachments -------------------------------------------------------------
// The browser uploads bytes straight to the private bucket; these actions are
// the only path that records them. Each one re-verifies the admin, lets the
// SECURITY DEFINER RPC validate ownership/MIME/size/object existence, and
// removes the object again when the metadata write was refused.

function attachmentInput(f: FormData, ownerId: string) {
  const path = s(f, 'storage_path');
  const fileName = s(f, 'file_name');
  const mime = s(f, 'mime_type');
  const size = Number(s(f, 'size_bytes'));
  const label = s(f, 'label');
  if (!path || !fileName || !mime) return { error: 'Missing file details.' as const };
  if (!Number.isInteger(size) || size < 1 || size > ATTACHMENT_MAX_BYTES) {
    return { error: 'Files must be between 1 byte and 20 MB.' as const };
  }
  if (!path.startsWith(`${ownerId}/`) || path.includes('..') || path.includes('\\')) {
    return { error: 'The upload path is outside this account folder.' as const };
  }
  if (attachmentMimeType(fileName) !== mime) {
    return { error: 'That file type does not match its name.' as const };
  }
  return { path, fileName, mime, size, label };
}

export async function registerAttachment(_: ActionState, f: FormData): Promise<ActionState> {
  await requireAdmin();
  const ownerId = s(f, 'id');
  if (!ownerId) return { error: 'Missing account.' };
  const input = attachmentInput(f, ownerId);
  if ('error' in input) return { error: input.error };

  const db = createClient();
  const { error } = await db.rpc('register_attachment', {
    p_owner_profile_id: ownerId,
    p_storage_path: input.path,
    p_file_name: input.fileName,
    p_mime_type: input.mime,
    p_size_bytes: input.size,
    p_label: input.label,
  });
  if (error) {
    // The row was never written, so the uploaded object is unreferenced.
    await db.storage.from(ATTACHMENT_BUCKET).remove([input.path]);
    return { error: error.message };
  }
  revalidatePath(`/users/${ownerId}`, 'layout');
  revalidatePath('/users', 'layout');
  return { ok: 'File added' };
}

export async function replaceAttachment(_: ActionState, f: FormData): Promise<ActionState> {
  await requireAdmin();
  const ownerId = s(f, 'owner_id');
  const attachmentId = s(f, 'id');
  if (!ownerId || !attachmentId) return { error: 'Missing file.' };
  const input = attachmentInput(f, ownerId);
  if ('error' in input) return { error: input.error };

  const db = createClient();
  const { data, error } = await db.rpc('replace_attachment', {
    p_attachment_id: attachmentId,
    p_storage_path: input.path,
    p_file_name: input.fileName,
    p_mime_type: input.mime,
    p_size_bytes: input.size,
    p_label: input.label,
  });
  if (error) {
    // The row still points at the previous object; remove the new upload.
    await db.storage.from(ATTACHMENT_BUCKET).remove([input.path]);
    return { error: error.message };
  }

  const previous = typeof data === 'string' ? data : null;
  let warning = false;
  if (previous && previous !== input.path) {
    const { error: removeError } = await db.storage.from(ATTACHMENT_BUCKET).remove([previous]);
    warning = !!removeError;
  }
  revalidatePath(`/users/${ownerId}`, 'layout');
  return { ok: warning ? 'File replaced; the previous copy could not be removed.' : 'File replaced' };
}

export async function deleteAttachment(_: ActionState, f: FormData): Promise<ActionState> {
  await requireAdmin();
  const ownerId = s(f, 'owner_id');
  const attachmentId = s(f, 'id');
  if (!ownerId || !attachmentId) return { error: 'Missing file.' };

  const db = createClient();
  const { data, error } = await db.rpc('delete_attachment', { p_attachment_id: attachmentId });
  if (error) return { error: error.message };

  const path = typeof data === 'string' ? data : null;
  let warning = false;
  if (path) {
    const { error: removeError } = await db.storage.from(ATTACHMENT_BUCKET).remove([path]);
    warning = !!removeError;
  }
  revalidatePath(`/users/${ownerId}`, 'layout');
  return { ok: warning ? 'File deleted; the stored copy could not be removed.' : 'File deleted' };
}

export async function signOut() {
  await createClient().auth.signOut();
  const { redirect } = await import('next/navigation');
  redirect('/login');
}
