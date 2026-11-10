-- Demo-account PIN access.
--
-- The 19 fictional demo people sign in with a Philippine mobile number plus a
-- per-account PIN. Their emails exist for the auth row and the dashboard only;
-- no email password is ever issued.
--
-- Security shape:
--   * PIN hashes live in the private schema. anon/authenticated have no usage
--     on the schema and no privileges on the table.
--   * Hashing and comparison happen in the demo-login Edge Function with
--     PBKDF2-SHA256. A 6-digit PIN is only safe because the hash never leaves
--     the server and verification is rate limited.
--   * The three demo_login_* RPCs are SECURITY DEFINER and executable by
--     service_role only. They never touch profiles.account_status, so a
--     suspended demo person (Junel Ramos) stays suspended.
--   * Lockout is five consecutive failures, then 15 minutes. A success resets
--     the counter. An expired lock starts a fresh count instead of re-locking
--     on the next miss.
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
  -- Refuse any user the demo provisioning did not mark. This keeps an
  -- operator or real account from ever receiving a demo PIN by mistake.
  if not exists (
    select 1 from auth.users u
     where u.id = p_user_id
       and u.raw_user_meta_data ->> 'surgo_demo' = 'true'
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

-- 2. Lookup by phone for the demo-login function -------------------------

create or replace function public.demo_login_lookup(p_phone text)
returns table (
  user_id uuid,
  email text,
  pin_hash text,
  failed_attempts integer,
  locked_until timestamptz,
  account_status public.account_status
)
language sql
stable
security definer
set search_path = ''
as $$
  select d.user_id,
         u.email,
         d.pin_hash,
         d.failed_attempts,
         d.locked_until,
         p.account_status
    from auth.users u
    join private.demo_access d on d.user_id = u.id
    join public.profiles p on p.id = u.id
   where p_phone ~ '^\+639[0-9]{9}$'
     and (u.phone = p_phone or p.phone = p_phone)
   limit 1;
$$;

comment on function public.demo_login_lookup(text) is
  'Returns the PIN record for a demo phone number. service_role only; the Edge Function verifies the hash.';

-- 3. Lockout bookkeeping --------------------------------------------------

create or replace function public.demo_login_record_failure(p_user_id uuid)
returns table (failed_attempts integer, locked_until timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempts integer;
  v_locked timestamptz;
begin
  select d.failed_attempts, d.locked_until
    into v_attempts, v_locked
    from private.demo_access d
   where d.user_id = p_user_id
   for update;

  if not found then
    return;
  end if;

  -- Already locked: keep the original window instead of extending it, so a
  -- caller that retries while locked cannot push the unlock time out.
  if v_locked is not null and v_locked > now() then
    return query select v_attempts, v_locked;
    return;
  end if;

  -- An expired lock starts a fresh count.
  if v_locked is not null and v_locked <= now() then
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
   where d.user_id = p_user_id;

  return query select v_attempts, v_locked;
end;
$$;

comment on function public.demo_login_record_failure(uuid) is
  'Increments the demo PIN failure count and locks for 15 minutes at five. service_role only.';

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

-- 4. EXECUTE boundary ----------------------------------------------------

revoke all on function public.set_demo_access(uuid, text)
  from public, anon, authenticated;
revoke all on function public.demo_login_lookup(text)
  from public, anon, authenticated;
revoke all on function public.demo_login_record_failure(uuid)
  from public, anon, authenticated;
revoke all on function public.demo_login_record_success(uuid)
  from public, anon, authenticated;

grant execute on function public.set_demo_access(uuid, text) to service_role;
grant execute on function public.demo_login_lookup(text) to service_role;
grant execute on function public.demo_login_record_failure(uuid) to service_role;
grant execute on function public.demo_login_record_success(uuid) to service_role;
