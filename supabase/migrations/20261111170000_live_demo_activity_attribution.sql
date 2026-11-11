-- Attribute activity created *after* seeding to the same demo/real split.
--
-- 20261111160000 flagged the seeded history rows. New rows created through the
-- app still defaulted to is_simulated = false, so a ride booked by a demo
-- account during a presentation looked like real activity (it never created
-- revenue, but it polluted the "real" ride counts).
--
-- These BEFORE INSERT OR UPDATE triggers derive the flag from the trusted
-- auth.users app_metadata marker set by provisioning. The marker is written
-- with the service role only, so a client cannot make a demo action look real
-- by omitting a field, and cannot make a real action look simulated either.
--
-- A row is simulated when either party is a demo identity. That is deliberate:
-- a real passenger riding with a demo rider is still demonstration activity.
-- The flag only ever turns on; it never clears on update.

-- ---------------------------------------------------------------------------
-- 1. Identity check
-- ---------------------------------------------------------------------------

create or replace function private.is_demo_identity(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from auth.users u
     where u.id = p_profile_id
       and coalesce(u.raw_app_meta_data ->> 'surgo_demo', 'false') = 'true'
  );
$$;

comment on function private.is_demo_identity(uuid) is
  'True when the profile is a provisioned demonstration identity. Service-role metadata only.';

revoke all on function private.is_demo_identity(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Generic trigger for tables that name both parties as profile columns
-- ---------------------------------------------------------------------------

create or replace function private.mark_simulated_parties()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_column text;
  v_profile uuid;
  v_demo boolean := false;
begin
  foreach v_column in array tg_argv loop
    v_profile := nullif(to_jsonb(new) ->> v_column, '')::uuid;
    if v_profile is not null
       and private.is_demo_identity(v_profile) then
      v_demo := true;
      exit;
    end if;
  end loop;

  new.is_simulated := coalesce(new.is_simulated, false) or v_demo;
  return new;
end;
$$;

comment on function private.mark_simulated_parties() is
  'Sets is_simulated when any profile column named in TG_ARGV is a demo identity.';

revoke all on function private.mark_simulated_parties()
  from public, anon, authenticated, service_role;

create trigger ride_requests_demo_attribution
  before insert or update of passenger_id, rider_id on public.ride_requests
  for each row execute function private.mark_simulated_parties(
    'passenger_id', 'rider_id'
  );

create trigger rental_bookings_demo_attribution
  before insert or update of renter_id, owner_id on public.rental_bookings
  for each row execute function private.mark_simulated_parties(
    'renter_id', 'owner_id'
  );

create trigger service_requests_demo_attribution
  before insert or update of customer_id, provider_id on public.service_requests
  for each row execute function private.mark_simulated_parties(
    'customer_id', 'provider_id'
  );

create trigger service_transactions_demo_attribution
  before insert or update of customer_id, provider_id
  on public.service_transactions
  for each row execute function private.mark_simulated_parties(
    'customer_id', 'provider_id'
  );

create trigger ride_status_events_demo_attribution
  before insert or update of actor_profile_id on public.ride_status_events
  for each row execute function private.mark_simulated_parties(
    'actor_profile_id'
  );

create trigger service_status_events_demo_attribution
  before insert or update of actor_profile_id on public.service_status_events
  for each row execute function private.mark_simulated_parties(
    'actor_profile_id'
  );

create trigger ride_ratings_demo_attribution
  before insert or update of rater_id, ratee_id on public.ride_ratings
  for each row execute function private.mark_simulated_parties(
    'rater_id', 'ratee_id'
  );

create trigger notifications_demo_attribution
  before insert or update of profile_id on public.notifications
  for each row execute function private.mark_simulated_parties('profile_id');

-- ---------------------------------------------------------------------------
-- 3. Wallet rows reach the profile through their account
-- ---------------------------------------------------------------------------

create or replace function private.mark_simulated_wallet()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
begin
  select wa.profile_id into v_profile
    from public.wallet_accounts wa
   where wa.id = new.wallet_account_id;

  new.is_simulated := coalesce(new.is_simulated, false)
    or coalesce(private.is_demo_identity(v_profile), false);
  return new;
end;
$$;

revoke all on function private.mark_simulated_wallet()
  from public, anon, authenticated, service_role;

create trigger wallet_transactions_demo_attribution
  before insert or update of wallet_account_id on public.wallet_transactions
  for each row execute function private.mark_simulated_wallet();
