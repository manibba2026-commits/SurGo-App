'use server';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { createClient } from '@/lib/supabase/server';

export type ActionState = { ok?: string; error?: string } | null;
const s = (f: FormData, k: string) => {
  const v = f.get(k);
  return typeof v === 'string' && v.trim() ? v.trim() : null;
};

/** Every action re-verifies admin server-side, then calls an audited SECURITY DEFINER RPC.
 *  Tables are never written from the browser. */
async function run(rpc: string, args: Record<string, unknown>, paths: string[], okMsg: string): Promise<ActionState> {
  await requireAdmin();
  const { error } = await createClient().rpc(rpc, args);
  if (error) return { error: error.message };
  paths.forEach((p) => revalidatePath(p));
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
    ['/verification'], 'Document updated');
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

export async function signOut() {
  await createClient().auth.signOut();
  const { redirect } = await import('next/navigation');
  redirect('/login');
}
