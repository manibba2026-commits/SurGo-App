-- Demo-account PIN access.
--
-- The 19 fictional demo people sign in with a Philippine mobile number plus a
-- per-account PIN. Their emails are reserved .test addresses that exist for the
-- auth row and the dashboard only; no email password is ever issued and no
-- mail can be delivered.
--
-- Security shape:
--   * PIN hashes live in the private schema. anon/authenticated have no usage
--     on the schema and no privileges on the table.
--   * Hashing and comparison happen in the demo-login Edge Function with
--     PBKDF2-SHA256. A 6-digit PIN is only safe because the hash never leaves
--     the server and verification is rate limited.
--   * demo_login_reserve_attempt is the lockout gate. It locks the account row,
--     checks the window, and consumes one attempt atomically *before* the Edge
--     Function verifies the PIN, so parallel requests cannot exceed five
--     verifications per 15-minute window.
--   * The RPCs are SECURITY DEFINER and executable by service_role only. They
--     never touch profiles.account_status, so a suspended demo person
--     (Junel Ramos) stays suspended.
--   * demo_login_clear_lockout is the operator recovery path. It clears only
--     the failure counter and window; it does not rotate the PIN.
--   * surgo_demo is read from raw_app_meta_data, which only the service role
--     can write. A client cannot mark itself as a demo account.
--
-- Nothing here changes Supabase's phone OTP or Google flows for real users.

create schema if not exists private;

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

create table if not exists private.demo_access (
  user_id uuid primary key references auth.users (id) on delete cascade,
  -- PBKDF2-SHA256 encoded string: pbkdf2-sha256$iterations$salt$hash
  pin_hash text not null
    check (pin_hash ~ '^pbkdf2-sha256\$[0-9]{6}\$[A-Za-z0-9_-]{20,64}\$[A-Za-z0-9_-]{40,64}$'),
  pin_updated_at timestamptz not null default now(),
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  locked_until timestamptz,
  last_failed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table private.demo_access is
  'Per-account PIN hash and lockout state for the fictional demo identities. Service-role access only.';

alter table private.demo_access enable row level security;

revoke all on table private.demo_access from public, anon, authenticated;
grant select, insert, update, delete on table private.demo_access to service_role;

-- Superseded by the atomic reservation path. Dropping them keeps a project that
-- ran an earlier draft from keeping callable copies of the old flow.
drop function if exists public.demo_login_lookup(text);
drop function if exists public.demo_login_record_failure(uuid);

-- 1. Set or rotate one account's PIN -------------------------------------

create or replace function public.set_demo_access(
  p_user_id uuid,
  p_pin_hash text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null or p_pin_hash is null then
    raise exception 'user id and pin hash are required' using errcode = '22023';
  end if;
  if p_pin_hash !~ '^pbkdf2-sha256\$[0-9]{6}\$[A-Za-z0-9_-]{20,64}\$[A-Za-z0-9_-]{40,64}$' then
    raise exception 'pin hash must be a pbkdf2-sha256 encoding' using errcode = '22023';
  end if;
  -- Refuse any user the demo provisioning did not mark in app_metadata.
  -- user_metadata is writable by the account holder, so it is not trusted.
  if not exists (
    select 1 from auth.users u
     where u.id = p_user_id
       and u.raw_app_meta_data ->> 'surgo_demo' = 'true'
  ) then
    raise exception 'not a demo account' using errcode = '42501';
  end if;

  insert into private.demo_access (user_id, pin_hash)
  values (p_user_id, p_pin_hash)
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash,
        pin_updated_at = now(),
        failed_attempts = 0,
        locked_until = null,
        last_failed_at = null,
        updated_at = now();
end;
$$;

comment on function public.set_demo_access(uuid, text) is
  'Sets or rotates a fictional demo account PIN hash. service_role only.';

-- 2. Reserve one attempt before verification ------------------------------

create or replace function public.demo_login_reserve_attempt(p_phone text)
returns table (
  user_id uuid,
  email text,
  pin_hash text,
  failed_attempts integer,
  locked_until timestamptz,
  account_status public.account_status,
  was_locked boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_email text;
  v_pin_hash text;
  v_attempts integer;
  v_locked timestamptz;
  v_status public.account_status;
begin
  if p_phone is null or p_phone !~ '^\+639[0-9]{9}$' then
    return;
  end if;

  select d.user_id, u.email, d.pin_hash,
         d.failed_attempts, d.locked_until, p.account_status
    into v_user_id, v_email, v_pin_hash, v_attempts, v_locked, v_status
    from public.profiles p
    join auth.users u on u.id = p.id
    join private.demo_access d on d.user_id = p.id
   where u.phone = p_phone or p.phone = p_phone
   order by (u.phone = p_phone) desc
   limit 1
   for update of d;

  if not found then
    return;
  end if;

  -- A live lock is reported without consuming an attempt or extending the
  -- window, so retries while locked cannot push the unlock time out.
  if v_locked is not null and v_locked > now() then
    return query
      select v_user_id, v_email, v_pin_hash, v_attempts, v_locked, v_status, true;
    return;
  end if;

  -- An expired lock starts a fresh count.
  if v_locked is not null then
    v_attempts := 0;
    v_locked := null;
  end if;

  v_attempts := v_attempts + 1;
  if v_attempts >= 5 then
    v_locked := now() + interval '15 minutes';
  end if;

  update private.demo_access d
     set failed_attempts = v_attempts,
         locked_until = v_locked,
         last_failed_at = now(),
         updated_at = now()
   where d.user_id = v_user_id;

  -- A reservation that sets the lock still allows this verification: the
  -- counter is what the fifth attempt spends, so only a pre-existing lock
  -- reports was_locked.
  return query
    select v_user_id, v_email, v_pin_hash, v_attempts, v_locked, v_status, false;
end;
$$;

comment on function public.demo_login_reserve_attempt(text) is
  'Atomically reserves one PIN attempt and enforces five attempts per 15 minutes. service_role only.';

-- 3. Clear the counter after a verified PIN -------------------------------

create or replace function public.demo_login_record_success(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.demo_access d
     set failed_attempts = 0,
         locked_until = null,
         last_failed_at = null,
         updated_at = now()
   where d.user_id = p_user_id;
end;
$$;

comment on function public.demo_login_record_success(uuid) is
  'Clears the demo PIN failure count after a verified PIN. service_role only.';

-- 4. Operator lockout recovery --------------------------------------------

create or replace function public.demo_login_clear_lockout(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.demo_access d
     set failed_attempts = 0,
         locked_until = null,
         last_failed_at = null,
         updated_at = now()
   where d.user_id = p_user_id;
  return found;
end;
$$;

comment on function public.demo_login_clear_lockout(uuid) is
  'Clears a demo account lockout without rotating its PIN. service_role only.';

-- 5. EXECUTE boundary ----------------------------------------------------

revoke all on function public.set_demo_access(uuid, text)
  from public, anon, authenticated;
revoke all on function public.demo_login_reserve_attempt(text)
  from public, anon, authenticated;
revoke all on function public.demo_login_record_success(uuid)
  from public, anon, authenticated;
revoke all on function public.demo_login_clear_lockout(uuid)
  from public, anon, authenticated;

grant execute on function public.set_demo_access(uuid, text) to service_role;
grant execute on function public.demo_login_reserve_attempt(text) to service_role;
grant execute on function public.demo_login_record_success(uuid) to service_role;
grant execute on function public.demo_login_clear_lockout(uuid) to service_role;
