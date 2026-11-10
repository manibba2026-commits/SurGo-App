import { NextResponse } from 'next/server';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { createServiceClient } from '@/lib/supabase/service';

export const runtime = 'nodejs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$/;
const PHONE = /^\+?[0-9][0-9 ()-]{6,19}$/;
const text = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null);
const fail = (error: string, status = 400) => NextResponse.json({ error }, { status });

/**
 * Changes the address the person signs in with. The Auth row is updated through
 * the Admin API (never the browser); a database trigger mirrors the values onto
 * public.profiles, and an audited RPC then records the change. Blank fields keep
 * the existing value.
 */
export async function PATCH(req: Request, { params }: { params: { id: string } }) {
  const db = createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) return fail('Sign in first.', 401);
  const { data: isAdmin } = await db.rpc('is_admin');
  if (isAdmin !== true) return fail('Administrator role required.', 403);
  if (!UUID.test(params.id)) return fail('Unknown account.');

  let body: { email?: unknown; phone?: unknown };
  try {
    body = (await req.json()) as { email?: unknown; phone?: unknown };
  } catch {
    return fail('Invalid request body.');
  }

  let service: ReturnType<typeof createServiceClient>;
  try {
    service = createServiceClient();
  } catch (error) {
    return fail(error instanceof Error ? error.message : 'Service role is not configured.', 500);
  }

  const { data: current, error: readError } = await service
    .from('profiles')
    .select('id,email,phone')
    .eq('id', params.id)
    .maybeSingle();
  if (readError) return fail(readError.message, 500);
  if (!current) return fail('Account not found.', 404);

  const typedEmail = text(body.email)?.toLowerCase() ?? null;
  const typedPhone = text(body.phone);
  const email = typedEmail ?? (current.email ?? null);
  const phone = typedPhone ?? (current.phone ?? null);

  if (!email && !phone) return fail('Keep at least an email address or a phone number.');
  if (email && !EMAIL.test(email)) return fail('Enter a valid email address.');
  if (phone && !PHONE.test(phone)) return fail('Enter a valid phone number, e.g. +639171234567.');

  const emailChanged = !!email && email !== (current.email ?? '').toLowerCase();
  const phoneChanged = !!phone && phone !== (current.phone ?? null);
  if (!emailChanged && !phoneChanged) {
    return NextResponse.json({ ok: true, changed: false });
  }

  if (emailChanged) {
    const { data, error } = await service
      .from('profiles').select('id').ilike('email', email).neq('id', params.id).limit(1);
    if (error) return fail(error.message, 500);
    if (data?.length) return fail(`${email} is already used by another account.`, 409);
  }
  if (phoneChanged) {
    const { data, error } = await service
      .from('profiles').select('id').eq('phone', phone).neq('id', params.id).limit(1);
    if (error) return fail(error.message, 500);
    if (data?.length) return fail(`${phone} is already used by another account.`, 409);
  }

  const patch: { email?: string; phone?: string; email_confirm?: boolean; phone_confirm?: boolean } = {};
  if (emailChanged) { patch.email = email!; patch.email_confirm = true; }
  if (phoneChanged) { patch.phone = phone!; patch.phone_confirm = true; }

  const { error: authError } = await service.auth.admin.updateUserById(params.id, patch);
  if (authError) {
    const conflict = /already|exists|registered/i.test(authError.message);
    return fail(authError.message, conflict ? 409 : 400);
  }

  const { error: profileError } = await db.rpc('admin_update_profile_contact', {
    p_profile_id: params.id,
    p_email: email,
    p_phone: phone,
  });
  if (profileError) {
    // Best effort: put the Auth identity back so the two stores agree again.
    await service.auth.admin.updateUserById(params.id, {
      email: current.email ?? undefined,
      phone: current.phone ?? undefined,
      email_confirm: !!current.email,
      phone_confirm: !!current.phone,
    });
    return fail(profileError.message, 400);
  }

  revalidatePath('/users', 'layout');
  return NextResponse.json({ ok: true, changed: true });
}
