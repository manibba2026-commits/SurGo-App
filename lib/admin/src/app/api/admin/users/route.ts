import { NextResponse } from 'next/server';
import { revalidatePath } from 'next/cache';
import { randomBytes } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { createServiceClient } from '@/lib/supabase/service';

export const runtime = 'nodejs';

const ROLES = new Set(['passenger', 'earner', 'rider', 'vehicle_owner']);
const EMAIL = /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$/;
const PHONE = /^\+?[0-9][0-9 ()-]{6,19}$/;

const text = (v: unknown, max: number) =>
  typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null;
const fail = (error: string, status = 400) => NextResponse.json({ error }, { status });

/**
 * Creates an Auth account, its profile and the requested roles. The browser
 * never sees the service key: this handler runs on the server and only after
 * re-verifying the signed-in administrator.
 */
export async function POST(req: Request) {
  const db = createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) return fail('Sign in to create accounts.', 401);
  const { data: isAdmin } = await db.rpc('is_admin');
  if (isAdmin !== true) return fail('Administrator role required.', 403);

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return fail('Invalid request body.');
  }

  const fullName = text(body.full_name, 120);
  const firstName = text(body.first_name, 120);
  const email = text(body.email, 254)?.toLowerCase() ?? null;
  const phone = text(body.phone, 20);
  const address = text(body.address, 200);
  const barangay = text(body.barangay, 120);

  if (!fullName) return fail('Full name is required.');
  if (!email && !phone) return fail('Enter an email address or a phone number.');
  if (email && !EMAIL.test(email)) return fail('Enter a valid email address.');
  if (phone && !PHONE.test(phone)) return fail('Enter a valid phone number, e.g. +639171234567.');
  // The profile keeps the administrator's formatting; GoTrue only accepts a
  // compact number, so strip separators before handing it the identity.
  const authPhone = phone?.replace(/[ ()-]/g, '') ?? null;
  if (authPhone && !/^\+?[0-9]{7,15}$/.test(authPhone)) {
    return fail('Enter a valid phone number, e.g. +639171234567.');
  }

  const requested = Array.isArray(body.roles)
    ? body.roles.filter((r): r is string => typeof r === 'string' && ROLES.has(r))
    : [];
  const roles = [...new Set(['passenger', ...requested])];

  let service: ReturnType<typeof createServiceClient>;
  try {
    service = createServiceClient();
  } catch (error) {
    return fail(error instanceof Error ? error.message : 'Service role is not configured.', 500);
  }

  if (email) {
    const { data, error } = await service.from('profiles').select('id').ilike('email', email).limit(1);
    if (error) return fail(error.message, 500);
    if (data?.length) return fail(`${email} is already used by another account.`, 409);
  }
  if (phone) {
    const { data, error } = await service.from('profiles').select('id').eq('phone', phone).limit(1);
    if (error) return fail(error.message, 500);
    if (data?.length) return fail(`${phone} is already used by another account.`, 409);
  }

  // Shown once to the administrator. It is never stored in the repository,
  // the database, or an audit row.
  const tempPassword = randomBytes(18).toString('base64url');
  const { data: created, error: createError } = await service.auth.admin.createUser({
    email: email ?? undefined,
    phone: authPhone ?? undefined,
    password: tempPassword,
    email_confirm: !!email,
    phone_confirm: !!authPhone,
    user_metadata: { full_name: fullName },
  });

  if (createError) {
    const conflict = /already|exists|registered/i.test(createError.message);
    return fail(createError.message, conflict ? 409 : 400);
  }
  const id = created.user?.id;
  if (!id) return fail('The auth service did not return the new account id.', 502);

  // Everything after the auth row goes through the administrator's own session,
  // so each role decision is checked and audited by the database.
  const warnings: string[] = [];

  const profile = await db.rpc('admin_update_profile', {
    p_profile_id: id,
    p_full_name: fullName,
    p_first_name: firstName,
    p_address: address,
    p_barangay: barangay,
  });
  if (profile.error) warnings.push(`Profile details were not saved: ${profile.error.message}`);

  if (email || phone) {
    const contact = await db.rpc('admin_update_profile_contact', {
      p_profile_id: id,
      p_email: email,
      p_phone: phone,
    });
    if (contact.error) warnings.push(`Contact mirror was not saved: ${contact.error.message}`);
  }

  for (const role of roles) {
    const status = role === 'rider' || role === 'vehicle_owner' ? 'pending' : 'approved';
    const { error } = await db.rpc('admin_set_user_role', {
      p_profile_id: id,
      p_role: role,
      p_status: status,
      p_reason: 'Created from the admin dashboard',
    });
    if (error) warnings.push(`${role} role was not assigned: ${error.message}`);
  }

  for (const capability of ['rider', 'vehicle_owner']) {
    if (!roles.includes(capability)) continue;
    const { error } = await db.rpc('admin_ensure_verification_application', {
      p_profile_id: id,
      p_capability: capability,
    });
    if (error) warnings.push(`${capability} verification was not opened: ${error.message}`);
  }

  revalidatePath('/users', 'layout');
  return NextResponse.json({ id, tempPassword, roles, warnings }, { status: 201 });
}
