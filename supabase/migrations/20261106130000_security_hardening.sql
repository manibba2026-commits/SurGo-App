-- Least-privilege hardening for the deployed SurGo schema.
--
-- Layered on top of the baseline migrations. It does not create, drop or
-- recreate tables, and it does not touch business data. The rules are:
--   * anon gets no table access and no helper EXECUTE;
--   * authenticated gets SELECT only, plus EXECUTE on the helpers that RLS
--     policies call. Writes stay behind future reviewed RPCs.
--
-- Supabase's default privileges grant ALL on new public tables and EXECUTE on
-- new public functions to anon, authenticated and service_role. The baseline
-- migration revoked EXECUTE from PUBLIC only, so those explicit anon grants
-- survived; this migration removes them and fixes the defaults for future
-- objects.

-- 1. Trigger helper: pin search_path and drop direct EXECUTE. Trigger
--    invocation does not require the privilege, so existing triggers keep
--    firing.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = pg_catalog.now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Sets updated_at on row updates. search_path pinned and no direct EXECUTE.';

revoke all on function public.set_updated_at() from public, anon, authenticated;

-- 2. RLS helpers. Policies execute these as the calling role, so authenticated
--    must keep EXECUTE. They return booleans only and never expose row data.
revoke all on function public.has_approved_role(public.user_role_type)
  from public, anon;
revoke all on function public.is_approved_provider(uuid) from public, anon;
revoke all on function public.owns_vehicle(uuid) from public, anon;
revoke all on function public.owns_verification_application(uuid)
  from public, anon;
revoke all on function public.owns_wallet_account(uuid) from public, anon;
revoke all on function public.can_access_ride(uuid) from public, anon;
revoke all on function public.can_access_rental(uuid) from public, anon;
revoke all on function public.can_access_service_request(uuid)
  from public, anon;

grant execute on function public.has_approved_role(public.user_role_type)
  to authenticated, service_role;
grant execute on function public.is_approved_provider(uuid)
  to authenticated, service_role;
grant execute on function public.owns_vehicle(uuid)
  to authenticated, service_role;
grant execute on function public.owns_verification_application(uuid)
  to authenticated, service_role;
grant execute on function public.owns_wallet_account(uuid)
  to authenticated, service_role;
grant execute on function public.can_access_ride(uuid)
  to authenticated, service_role;
grant execute on function public.can_access_rental(uuid)
  to authenticated, service_role;
grant execute on function public.can_access_service_request(uuid)
  to authenticated, service_role;

-- 3. Trigger functions on auth.users are not callable over the API at all.
revoke all on function public.handle_new_auth_user()
  from public, anon, authenticated;
revoke all on function public.handle_auth_user_updated()
  from public, anon, authenticated;

-- 4. Existing tables: authenticated keeps SELECT (RLS still filters rows and
--    no table has a write policy); anon loses every privilege. The audit log
--    is service_role only, so it keeps no client grant at all.
do $$
declare
  v_table regclass;
begin
  for v_table in
    select c.oid::regclass
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
  loop
    execute format('revoke all on table %s from anon', v_table);
    execute format('revoke all on table %s from authenticated', v_table);
    if v_table <> 'public.admin_audit_logs'::regclass then
      execute format('grant select on table %s to authenticated', v_table);
    end if;
  end loop;
end;
$$;

-- 5. Future objects created by migrations (role postgres): no anon access,
--    SELECT-only for authenticated, and EXECUTE must be granted explicitly.
alter default privileges for role postgres in schema public
  revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke all on tables from authenticated;
alter default privileges for role postgres in schema public
  grant select on tables to authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon;
alter default privileges for role postgres in schema public
  revoke execute on functions from authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke all on sequences from authenticated;
alter default privileges for role postgres in schema public
  grant all on tables to service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to service_role;
alter default privileges for role postgres in schema public
  grant execute on functions to service_role;
