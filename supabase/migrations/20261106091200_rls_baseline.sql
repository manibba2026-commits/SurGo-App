-- Baseline Row Level Security.
--
-- Read-own / read-catalog rules only. No INSERT/UPDATE/DELETE policies are
-- created: mobile writes will go through reviewed RPCs (or the admin dashboard
-- via service_role) once Flutter is connected.

create or replace function public.has_approved_role(
  p_role public.user_role_type
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.user_roles ur
     where ur.profile_id = auth.uid()
       and ur.role = p_role
       and ur.status = 'approved'
  );
$$;

create or replace function public.is_approved_provider(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.user_roles ur
     where ur.profile_id = p_profile_id
       and ur.role in ('earner', 'rider', 'vehicle_owner')
       and ur.status = 'approved'
  );
$$;

create or replace function public.owns_vehicle(p_vehicle_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.vehicles v
     where v.id = p_vehicle_id
       and v.owner_profile_id = auth.uid()
  );
$$;

create or replace function public.owns_verification_application(
  p_application_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.verification_applications va
     where va.id = p_application_id
       and va.profile_id = auth.uid()
  );
$$;

create or replace function public.owns_wallet_account(p_account_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.wallet_accounts wa
     where wa.id = p_account_id
       and wa.profile_id = auth.uid()
  );
$$;

create or replace function public.can_access_ride(p_ride_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.ride_requests rr
     where rr.id = p_ride_id
       and (
         rr.passenger_id = auth.uid()
         or rr.rider_id = auth.uid()
         or (
           rr.status in ('searching', 'awaiting_acceptance')
           and public.has_approved_role('rider')
         )
       )
  );
$$;

create or replace function public.can_access_rental(p_rental_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.rental_bookings rb
     where rb.id = p_rental_id
       and (rb.renter_id = auth.uid() or rb.owner_id = auth.uid())
  );
$$;

create or replace function public.can_access_service_request(p_request_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.service_requests sr
     where sr.id = p_request_id
       and (
         sr.customer_id = auth.uid()
         or sr.provider_id = auth.uid()
         or (sr.status = 'available' and public.has_approved_role('earner'))
       )
  );
$$;

revoke all on function public.has_approved_role(public.user_role_type)
  from public;
revoke all on function public.is_approved_provider(uuid) from public;
revoke all on function public.owns_vehicle(uuid) from public;
revoke all on function public.owns_verification_application(uuid) from public;
revoke all on function public.owns_wallet_account(uuid) from public;
revoke all on function public.can_access_ride(uuid) from public;
revoke all on function public.can_access_rental(uuid) from public;
revoke all on function public.can_access_service_request(uuid) from public;

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

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'public.service_areas',
    'public.barangays',
    'public.puroks',
    'public.pricing_policies',
    'public.profiles',
    'public.user_roles',
    'public.provider_profiles',
    'public.vehicles',
    'public.vehicle_documents',
    'public.verification_applications',
    'public.verification_documents',
    'public.ride_requests',
    'public.ride_status_events',
    'public.ride_locations',
    'public.ride_ratings',
    'public.rental_bookings',
    'public.service_requests',
    'public.service_request_items',
    'public.service_status_events',
    'public.service_transactions',
    'public.wallet_accounts',
    'public.wallet_transactions',
    'public.cash_fee_remittances',
    'public.notifications',
    'public.device_tokens',
    'public.admin_audit_logs'
  ]
  loop
    execute format('alter table %s enable row level security', v_table);
  end loop;
end;
$$;

-- Catalog is readable by any signed-in user.
create policy service_areas_read_authenticated
  on public.service_areas for select to authenticated using (true);

create policy barangays_read_authenticated
  on public.barangays for select to authenticated using (true);

create policy puroks_read_authenticated
  on public.puroks for select to authenticated using (true);

-- Only the active, approved policy is visible to app users.
create policy pricing_policies_read_active
  on public.pricing_policies for select to authenticated using (is_active);

-- Identity.
create policy profiles_read_own
  on public.profiles for select to authenticated
  using (id = auth.uid() or public.has_approved_role('admin'));

create policy user_roles_read_own
  on public.user_roles for select to authenticated
  using (profile_id = auth.uid() or public.has_approved_role('admin'));

create policy provider_profiles_read
  on public.provider_profiles for select to authenticated
  using (
    profile_id = auth.uid()
    or public.is_approved_provider(profile_id)
    or public.has_approved_role('admin')
  );

create policy vehicles_read_listed_or_own
  on public.vehicles for select to authenticated
  using (
    status = 'active'
    or owner_profile_id = auth.uid()
    or public.has_approved_role('admin')
  );

create policy vehicle_documents_read_own
  on public.vehicle_documents for select to authenticated
  using (public.owns_vehicle(vehicle_id) or public.has_approved_role('admin'));

create policy verification_applications_read_own
  on public.verification_applications for select to authenticated
  using (profile_id = auth.uid() or public.has_approved_role('admin'));

create policy verification_documents_read_own
  on public.verification_documents for select to authenticated
  using (
    public.owns_verification_application(application_id)
    or public.has_approved_role('admin')
  );

-- Rides.
create policy ride_requests_read_participants
  on public.ride_requests for select to authenticated
  using (public.can_access_ride(id));

create policy ride_status_events_read_participants
  on public.ride_status_events for select to authenticated
  using (public.can_access_ride(ride_id));

create policy ride_locations_read_participants
  on public.ride_locations for select to authenticated
  using (public.can_access_ride(ride_id));

create policy ride_ratings_read_participants
  on public.ride_ratings for select to authenticated
  using (rater_id = auth.uid() or ratee_id = auth.uid()
    or public.has_approved_role('admin'));

-- Rentals.
create policy rental_bookings_read_participants
  on public.rental_bookings for select to authenticated
  using (public.can_access_rental(id));

-- Pasuyo.
create policy service_requests_read_participants
  on public.service_requests for select to authenticated
  using (public.can_access_service_request(id));

create policy service_request_items_read_participants
  on public.service_request_items for select to authenticated
  using (public.can_access_service_request(service_request_id));

create policy service_status_events_read_participants
  on public.service_status_events for select to authenticated
  using (public.can_access_service_request(service_request_id));

-- Money.
create policy service_transactions_read_participants
  on public.service_transactions for select to authenticated
  using (customer_id = auth.uid() or provider_id = auth.uid()
    or public.has_approved_role('admin'));

create policy wallet_accounts_read_own
  on public.wallet_accounts for select to authenticated
  using (profile_id = auth.uid() or public.has_approved_role('admin'));

create policy wallet_transactions_read_own
  on public.wallet_transactions for select to authenticated
  using (public.owns_wallet_account(wallet_account_id)
    or public.has_approved_role('admin'));

create policy cash_fee_remittances_read_own
  on public.cash_fee_remittances for select to authenticated
  using (provider_id = auth.uid() or public.has_approved_role('admin'));

-- Engagement.
create policy notifications_read_own
  on public.notifications for select to authenticated
  using (profile_id = auth.uid());

create policy device_tokens_read_own
  on public.device_tokens for select to authenticated
  using (profile_id = auth.uid());

-- admin_audit_logs intentionally has no policies: service_role only.
