-- Rider presence, live rider discovery and the ride dispatch lifecycle.
--
-- The app previously had read-only ride history: no table said whether a rider
-- was online, where they were, or whether they were free to take a trip. A
-- hosted passenger therefore had no honest candidate to match against, and the
-- Find a Ride screen was blocked.
--
-- This migration adds:
--   * rider_presence — the online/available flag and last known position for an
--     approved ride provider. Demo rows are marked is_simulated = true.
--   * discovery — a SECURITY DEFINER function that returns only the safe fields
--     a passenger needs to choose a rider.
--   * dispatch — create/assign/respond/cancel/advance functions. The client
--     never gets INSERT/UPDATE grants on ride_requests; every write is checked
--     against auth.uid() inside a function.
--
-- Approval: an approved `earner` with the `rides` capability is a ride provider.
-- Most demo riders carry `rider: pending`, so requiring the newer `rider` role
-- would keep the whole demo fleet invisible. The helper below is the single
-- source of truth for that rule, and can_access_ride uses it too.

-- ---------------------------------------------------------------------------
-- 1. Eligibility
-- ---------------------------------------------------------------------------

create or replace function public.is_approved_ride_provider(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.profiles p
     where p.id = p_profile_id
       and p.account_status = 'active'
       and (
         -- The newer rider role is self-sufficient. The seeded demo fleet mostly
         -- predates it and carries an approved earner role plus the rides
         -- capability instead.
         exists (
           select 1
             from public.user_roles ur
            where ur.profile_id = p.id
              and ur.role = 'rider'
              and ur.status = 'approved'
         )
         or exists (
           select 1
             from public.provider_profiles pp
             join public.user_roles ur
               on ur.profile_id = pp.profile_id
              and ur.role in ('earner', 'rider')
              and ur.status = 'approved'
            where pp.profile_id = p.id
              and pp.provider_type = 'earner'
              and 'rides'::public.earner_capability = any (pp.capabilities)
         )
       )
  );
$$;

revoke all on function public.is_approved_ride_provider(uuid) from public, anon;
grant execute on function public.is_approved_ride_provider(uuid)
  to authenticated, service_role;

-- An open ride is visible to any approved ride provider, not only accounts
-- carrying the newer `rider` role. Assigned riders and the passenger keep
-- seeing their own trip through the first two branches.
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
           and public.is_approved_ride_provider(auth.uid())
         )
       )
  );
$$;

revoke all on function public.can_access_ride(uuid) from public, anon;
grant execute on function public.can_access_ride(uuid)
  to authenticated, service_role;

-- Ride participants may read the other party's profile row. The app only ever
-- selects name/rating/avatar, and this keeps the counterpart name available to
-- the history screens without a service-role read.
create or replace function public.shares_ride_with(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.ride_requests rr
     where (rr.passenger_id = auth.uid() and rr.rider_id = p_profile_id)
        or (rr.rider_id = auth.uid() and rr.passenger_id = p_profile_id)
  );
$$;

revoke all on function public.shares_ride_with(uuid) from public, anon;
grant execute on function public.shares_ride_with(uuid)
  to authenticated, service_role;

drop policy if exists profiles_read_ride_counterparties on public.profiles;
create policy profiles_read_ride_counterparties
  on public.profiles for select to authenticated
  using (public.shares_ride_with(id));

-- Whether a rider is already committed to a request or trip. Discovery and the
-- availability flag use this so a rider can never be offered two trips at once.
create or replace function public.rider_has_active_ride(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.ride_requests rr
     where rr.rider_id = p_profile_id
       and rr.status in (
         'awaiting_acceptance', 'accepted', 'heading_to_pickup',
         'arrived', 'in_progress'
       )
  );
$$;

revoke all on function public.rider_has_active_ride(uuid) from public, anon;
grant execute on function public.rider_has_active_ride(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Presence table
-- ---------------------------------------------------------------------------

create table public.rider_presence (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  is_online boolean not null default false,
  is_available boolean not null default false,
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  heading_degrees double precision
    check (heading_degrees is null or heading_degrees between 0 and 360),
  barangay_id uuid references public.barangays (id) on delete set null,
  -- Display snapshot for dispatch. A rider may not own a rental vehicle row,
  -- so the vehicle shown to the passenger lives with the presence row.
  vehicle_type text,
  vehicle_label text,
  vehicle_plate text,
  is_simulated boolean not null default false,
  source text not null default 'app'
    check (source in ('app', 'demo', 'admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.rider_presence is
  'Online/available state and last known position for an approved ride provider. Demo rows are simulated and marked as such.';

create index rider_presence_online_idx
  on public.rider_presence (is_online, is_available)
  where is_online;

create index rider_presence_barangay_idx
  on public.rider_presence (barangay_id)
  where barangay_id is not null;

create trigger rider_presence_set_updated_at
  before update on public.rider_presence
  for each row execute function public.set_updated_at();

alter table public.rider_presence enable row level security;

-- A passenger sees every online rider plus their own row. Offline riders are
-- not readable, which is also what keeps them off the map and out of matching.
drop policy if exists rider_presence_read_online on public.rider_presence;
create policy rider_presence_read_online
  on public.rider_presence for select to authenticated
  using (
    profile_id = auth.uid()
    or (
      is_online
      and public.is_approved_ride_provider(profile_id)
    )
    or public.has_approved_role('admin')
  );

revoke all on public.rider_presence from public, anon, authenticated;
grant select on public.rider_presence to authenticated;
grant all on public.rider_presence to service_role;

-- Publish presence so a map or rider inbox can react without a manual reload.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.rider_presence;
    exception
      when duplicate_object then null;
      when undefined_table then null;
    end;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Presence writer
-- ---------------------------------------------------------------------------

create or replace function public.set_rider_presence(
  p_is_online boolean,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_heading_degrees double precision default null,
  p_barangay_id uuid default null,
  p_is_simulated boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid := auth.uid();
  v_existing public.rider_presence%rowtype;
  v_lat double precision := p_latitude;
  v_lng double precision := p_longitude;
  v_new_fix boolean := p_latitude is not null and p_longitude is not null;
  v_simulated boolean;
  v_source text;
  v_available boolean;
  v_row public.rider_presence%rowtype;
begin
  if v_profile_id is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;

  if not public.is_approved_ride_provider(v_profile_id) then
    raise exception 'This account is not an approved ride provider.'
      using errcode = '42501';
  end if;

  select * into v_existing
    from public.rider_presence
   where profile_id = v_profile_id;

  if p_is_online then
    -- Going online without a new fix is allowed when the rider already shared
    -- one; inventing coordinates here would be worse than refusing.
    v_lat := coalesce(v_lat, v_existing.latitude);
    v_lng := coalesce(v_lng, v_existing.longitude);
    if v_lat is null or v_lng is null then
      raise exception 'Share your location before going online.'
        using errcode = '22023';
    end if;
  end if;

  -- A demo row keeps its simulated marker when the rider only flips the switch:
  -- the stored coordinates are still the seeded demo fix, not a device reading.
  -- A new fix replaces that story because it came from the device.
  v_simulated := coalesce(
    p_is_simulated,
    case when v_new_fix then false else v_existing.is_simulated end,
    false
  );
  v_source := case
    when p_is_simulated is true then 'demo'
    when v_new_fix then 'app'
    when v_existing.source is not null then v_existing.source
    else 'app'
  end;

  -- Going online while already on a trip keeps the rider visible on the map but
  -- not available for a second request.
  v_available := p_is_online
    and not public.rider_has_active_ride(v_profile_id);

  insert into public.rider_presence as rp (
    profile_id, is_online, is_available, latitude, longitude, heading_degrees,
    barangay_id, is_simulated, source, updated_at
  ) values (
    v_profile_id, p_is_online, v_available, v_lat, v_lng, p_heading_degrees,
    p_barangay_id, v_simulated, v_source, now()
  )
  on conflict (profile_id) do update set
    is_online = excluded.is_online,
    is_available = excluded.is_available,
    latitude = coalesce(excluded.latitude, rp.latitude),
    longitude = coalesce(excluded.longitude, rp.longitude),
    heading_degrees = coalesce(excluded.heading_degrees, rp.heading_degrees),
    barangay_id = coalesce(excluded.barangay_id, rp.barangay_id),
    is_simulated = excluded.is_simulated,
    source = excluded.source,
    updated_at = now()
  returning * into v_row;

  update public.provider_profiles
     set is_available = v_row.is_available
   where profile_id = v_profile_id;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.set_rider_presence(
  boolean, double precision, double precision, double precision, uuid, boolean
) from public, anon;
grant execute on function public.set_rider_presence(
  boolean, double precision, double precision, double precision, uuid, boolean
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Discovery
-- ---------------------------------------------------------------------------

create or replace function public.find_available_riders(
  p_service_area_id uuid default null,
  p_pickup_latitude double precision default null,
  p_pickup_longitude double precision default null,
  p_exclude_profile_id uuid default null,
  p_limit integer default 20
)
returns table (
  profile_id uuid,
  full_name text,
  avatar_path text,
  rating numeric,
  total_trips integer,
  vehicle_type text,
  vehicle_label text,
  vehicle_plate text,
  barangay_id uuid,
  barangay_name text,
  latitude double precision,
  longitude double precision,
  heading_degrees double precision,
  is_simulated boolean,
  distance_km double precision,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    p.full_name,
    p.avatar_path,
    coalesce(pp.rating, p.rating),
    coalesce(pp.total_trips, p.total_rides),
    rp.vehicle_type,
    rp.vehicle_label,
    rp.vehicle_plate,
    rp.barangay_id,
    b.name,
    rp.latitude,
    rp.longitude,
    rp.heading_degrees,
    rp.is_simulated,
    case
      when p_pickup_latitude is null or p_pickup_longitude is null then null
      else 6371.0 * 2 * asin(sqrt(
        power(sin(radians(rp.latitude - p_pickup_latitude) / 2), 2)
        + cos(radians(p_pickup_latitude)) * cos(radians(rp.latitude))
          * power(sin(radians(rp.longitude - p_pickup_longitude) / 2), 2)
      ))
    end as distance_km,
    rp.updated_at
  from public.rider_presence rp
  join public.profiles p on p.id = rp.profile_id
  left join public.provider_profiles pp on pp.profile_id = p.id
  left join public.barangays b on b.id = rp.barangay_id
  where rp.is_online
    and rp.is_available
    and rp.latitude is not null
    and rp.longitude is not null
    and p.account_status = 'active'
    and p.id <> auth.uid()
    and (p_exclude_profile_id is null or p.id <> p_exclude_profile_id)
    and public.is_approved_ride_provider(p.id)
    and (
      p_service_area_id is null
      or pp.service_area_id is null
      or pp.service_area_id = p_service_area_id
    )
  order by distance_km nulls last, pp.rating desc, p.full_name
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;

revoke all on function public.find_available_riders(
  uuid, double precision, double precision, uuid, integer
) from public, anon;
grant execute on function public.find_available_riders(
  uuid, double precision, double precision, uuid, integer
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Request creation helpers
-- ---------------------------------------------------------------------------

create or replace function public.resolve_service_area(p_service_area_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    p_service_area_id,
    (select id from public.service_areas where is_active
      order by created_at limit 1)
  );
$$;

create or replace function public.resolve_barangay(
  p_service_area_id uuid,
  p_name text
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select b.id
    from public.barangays b
   where b.service_area_id = p_service_area_id
     and p_name is not null
     and length(trim(p_name)) > 0
     and (
       lower(b.name) = lower(trim(p_name))
       or lower(b.name) = lower(regexp_replace(trim(p_name), '^barangay\s+', '', 'i'))
       or lower(trim(p_name)) like '%' || lower(b.name) || '%'
       or lower(b.name) like '%'
            || lower(regexp_replace(trim(p_name), '^barangay\s+', '', 'i'))
            || '%'
     )
   order by
     (lower(b.name) = lower(trim(p_name))) desc,
     (lower(b.name) = lower(regexp_replace(trim(p_name), '^barangay\s+', '', 'i'))) desc,
     length(b.name),
     b.name
   limit 1;
$$;

create or replace function public.resolve_purok(
  p_barangay_id uuid,
  p_name text
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select pr.id
    from public.puroks pr
   where pr.barangay_id = p_barangay_id
     and p_name is not null
     and (
       lower(pr.name) = lower(trim(p_name))
       or lower(pr.name) = lower(split_part(trim(p_name), ',', 1))
     )
   order by length(pr.name), pr.name
   limit 1;
$$;

revoke all on function public.resolve_service_area(uuid) from public, anon, authenticated;
revoke all on function public.resolve_barangay(uuid, text) from public, anon, authenticated;
revoke all on function public.resolve_purok(uuid, text) from public, anon, authenticated;
grant execute on function public.resolve_service_area(uuid) to service_role;
grant execute on function public.resolve_barangay(uuid, text) to service_role;
grant execute on function public.resolve_purok(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Create a request
-- ---------------------------------------------------------------------------

create or replace function public.create_ride_request(
  p_pickup_address text,
  p_pickup_barangay text default null,
  p_pickup_purok text default null,
  p_pickup_latitude double precision default null,
  p_pickup_longitude double precision default null,
  p_dropoff_address text default null,
  p_dropoff_barangay text default null,
  p_dropoff_purok text default null,
  p_dropoff_latitude double precision default null,
  p_dropoff_longitude double precision default null,
  p_distance_km numeric default 0,
  p_eta_minutes integer default 0,
  p_fare_centavos bigint default 0,
  p_platform_fee_centavos bigint default 0,
  p_note text default null,
  p_service_area_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid := auth.uid();
  v_service_area_id uuid;
  v_pickup_barangay_id uuid;
  v_pickup_purok_id uuid;
  v_dropoff_barangay_id uuid;
  v_dropoff_purok_id uuid;
  v_row public.ride_requests%rowtype;
begin
  if v_profile_id is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.profiles
     where id = v_profile_id and account_status = 'active'
  ) then
    raise exception 'This account is not active.' using errcode = '42501';
  end if;

  v_service_area_id := public.resolve_service_area(p_service_area_id);
  if v_service_area_id is null then
    raise exception 'No active service area is configured.' using errcode = '22023';
  end if;

  v_pickup_barangay_id := coalesce(
    public.resolve_barangay(v_service_area_id, p_pickup_barangay),
    (select id from public.barangays
      where service_area_id = v_service_area_id order by name limit 1)
  );
  if v_pickup_barangay_id is null then
    raise exception 'No barangay is configured for this service area.'
      using errcode = '22023';
  end if;

  v_pickup_purok_id := public.resolve_purok(
    v_pickup_barangay_id, p_pickup_purok
  );

  if p_dropoff_barangay is not null
     and length(trim(p_dropoff_barangay)) > 0 then
    v_dropoff_barangay_id := public.resolve_barangay(
      v_service_area_id, p_dropoff_barangay
    );
    if v_dropoff_barangay_id is not null then
      v_dropoff_purok_id := public.resolve_purok(
        v_dropoff_barangay_id, p_dropoff_purok
      );
    end if;
  end if;

  insert into public.ride_requests (
    passenger_id, service_area_id, status,
    pickup_address, pickup_barangay_id, pickup_purok_id,
    pickup_latitude, pickup_longitude,
    dropoff_address, dropoff_barangay_id, dropoff_purok_id,
    dropoff_latitude, dropoff_longitude,
    distance_km, eta_minutes, fare_centavos, platform_fee_centavos,
    payment_method, note
  ) values (
    v_profile_id, v_service_area_id, 'searching',
    coalesce(nullif(trim(p_pickup_address), ''), 'Pickup'),
    v_pickup_barangay_id, v_pickup_purok_id,
    p_pickup_latitude, p_pickup_longitude,
    coalesce(nullif(trim(p_dropoff_address), ''), 'Destination'),
    v_dropoff_barangay_id, v_dropoff_purok_id,
    p_dropoff_latitude, p_dropoff_longitude,
    greatest(coalesce(p_distance_km, 0), 0),
    greatest(coalesce(p_eta_minutes, 0), 0),
    greatest(coalesce(p_fare_centavos, 0), 0),
    greatest(coalesce(p_platform_fee_centavos, 0), 0),
    'cash',
    nullif(trim(p_note), '')
  )
  returning * into v_row;

  insert into public.ride_status_events (ride_id, status, actor_profile_id, note)
  values (v_row.id, 'searching', v_profile_id, 'Ride requested from the app');

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.create_ride_request(
  text, text, text, double precision, double precision,
  text, text, text, double precision, double precision,
  numeric, integer, bigint, bigint, text, uuid
) from public, anon;
grant execute on function public.create_ride_request(
  text, text, text, double precision, double precision,
  text, text, text, double precision, double precision,
  numeric, integer, bigint, bigint, text, uuid
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Assign a rider
-- ---------------------------------------------------------------------------

create or replace function public.assign_ride_request(
  p_ride_id uuid,
  p_rider_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid := auth.uid();
  v_row public.ride_requests%rowtype;
  v_passenger_name text;
  v_rider_name text;
begin
  if v_profile_id is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;

  select * into v_row
    from public.ride_requests
   where id = p_ride_id
   for update;

  if not found then
    raise exception 'Ride not found.' using errcode = 'P0002';
  end if;
  if v_row.passenger_id <> v_profile_id then
    raise exception 'Only the passenger can choose a rider.'
      using errcode = '42501';
  end if;
  if v_row.status <> 'searching' then
    raise exception 'This ride is no longer open.' using errcode = '22023';
  end if;
  if p_rider_id = v_profile_id then
    raise exception 'You cannot book yourself.' using errcode = '22023';
  end if;
  if not public.is_approved_ride_provider(p_rider_id) then
    raise exception 'That rider is not approved for rides.'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.rider_presence
     where profile_id = p_rider_id and is_online and is_available
  ) then
    raise exception 'That rider is no longer online.' using errcode = '22023';
  end if;

  update public.ride_requests
     set rider_id = p_rider_id,
         status = 'awaiting_acceptance'
   where id = p_ride_id
   returning * into v_row;

  -- Hold the rider for this request: they stay online for the map, but a second
  -- passenger cannot assign them while they decide.
  update public.rider_presence
     set is_available = false, updated_at = now()
   where profile_id = p_rider_id;
  update public.provider_profiles
     set is_available = false
   where profile_id = p_rider_id;

  insert into public.ride_status_events (ride_id, status, actor_profile_id, note)
  values (p_ride_id, 'awaiting_acceptance', v_profile_id,
          'Passenger selected a rider');

  select full_name into v_passenger_name
    from public.profiles where id = v_row.passenger_id;
  select full_name into v_rider_name
    from public.profiles where id = p_rider_id;

  insert into public.notifications (
    profile_id, notification_type, title, body, data
  ) values (
    p_rider_id,
    'ride',
    'New ride request',
    coalesce(v_passenger_name, 'A passenger')
      || ' selected you for a ride: '
      || v_row.pickup_address || ' → ' || v_row.dropoff_address || '.',
    jsonb_build_object(
      'ride_id', p_ride_id,
      'kind', 'ride_request',
      'passenger_name', v_passenger_name,
      'rider_name', v_rider_name
    )
  );

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.assign_ride_request(uuid, uuid) from public, anon;
grant execute on function public.assign_ride_request(uuid, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Rider answer
-- ---------------------------------------------------------------------------

create or replace function public.respond_to_ride_request(
  p_ride_id uuid,
  p_accept boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid := auth.uid();
  v_row public.ride_requests%rowtype;
  v_rider_name text;
begin
  if v_profile_id is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;

  select * into v_row
    from public.ride_requests
   where id = p_ride_id
   for update;

  if not found then
    raise exception 'Ride not found.' using errcode = 'P0002';
  end if;
  if v_row.rider_id is distinct from v_profile_id then
    raise exception 'This request was not sent to you.' using errcode = '42501';
  end if;
  if v_row.status <> 'awaiting_acceptance' then
    raise exception 'This request is no longer waiting for an answer.'
      using errcode = '22023';
  end if;

  select full_name into v_rider_name
    from public.profiles where id = v_profile_id;

  if p_accept then
    update public.ride_requests
       set status = 'accepted',
           accepted_at = now()
     where id = p_ride_id
     returning * into v_row;

    insert into public.ride_status_events (ride_id, status, actor_profile_id, note)
    values (p_ride_id, 'accepted', v_profile_id, 'Rider accepted the request');

    -- A rider on a trip is still online for the map, but no longer free for a
    -- second request.
    update public.rider_presence
       set is_available = false, updated_at = now()
     where profile_id = v_profile_id;
    update public.provider_profiles
       set is_available = false
     where profile_id = v_profile_id;

    insert into public.notifications (
      profile_id, notification_type, title, body, data
    ) values (
      v_row.passenger_id,
      'ride',
      coalesce(v_rider_name, 'Your rider') || ' accepted your ride',
      'Your trip from ' || v_row.pickup_address || ' to '
        || v_row.dropoff_address || ' is confirmed.',
      jsonb_build_object(
        'ride_id', p_ride_id,
        'kind', 'ride_accepted',
        'rider_name', v_rider_name
      )
    );
  else
    update public.ride_requests
       set rider_id = null,
           status = 'searching'
     where id = p_ride_id
     returning * into v_row;

    -- Declining frees the rider for another request unless they are already
    -- holding or running a different one.
    update public.rider_presence
       set is_available = is_online
         and not public.rider_has_active_ride(v_profile_id),
           updated_at = now()
     where profile_id = v_profile_id;
    update public.provider_profiles
       set is_available = exists (
         select 1 from public.rider_presence
          where profile_id = v_profile_id and is_available
       )
     where profile_id = v_profile_id;

    insert into public.ride_status_events (ride_id, status, actor_profile_id, note)
    values (p_ride_id, 'searching', v_profile_id,
            'Rider declined; request reopened');

    insert into public.notifications (
      profile_id, notification_type, title, body, data
    ) values (
      v_row.passenger_id,
      'ride',
      coalesce(v_rider_name, 'Your rider') || ' declined your ride',
      'The request for ' || v_row.pickup_address || ' → '
        || v_row.dropoff_address || ' was declined. Book again to find another rider.',
      jsonb_build_object(
        'ride_id', p_ride_id,
        'kind', 'ride_declined',
        'rider_name', v_rider_name
      )
    );
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.respond_to_ride_request(uuid, boolean)
  from public, anon;
grant execute on function public.respond_to_ride_request(uuid, boolean)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Cancel
-- ---------------------------------------------------------------------------

create or replace function public.cancel_ride_request(
  p_ride_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid := auth.uid();
  v_row public.ride_requests%rowtype;
  v_counterparty uuid;
  v_actor_name text;
begin
  if v_profile_id is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;

  select * into v_row
    from public.ride_requests
   where id = p_ride_id
   for update;

  if not found then
    raise exception 'Ride not found.' using errcode = 'P0002';
  end if;
  if v_profile_id not in (v_row.passenger_id, coalesce(v_row.rider_id, v_row.passenger_id)) then
    raise exception 'Only a participant can cancel this ride.'
      using errcode = '42501';
  end if;
  if v_row.status in ('completed', 'cancelled') then
    raise exception 'This ride has already ended.' using errcode = '22023';
  end if;

  update public.ride_requests
     set status = 'cancelled',
         cancelled_at = now(),
         cancellation_reason = coalesce(nullif(trim(p_reason), ''),
                                        'Cancelled from the app')
   where id = p_ride_id
   returning * into v_row;

  insert into public.ride_status_events (ride_id, status, actor_profile_id, note)
  values (p_ride_id, 'cancelled', v_profile_id,
          coalesce(nullif(trim(p_reason), ''), 'Cancelled from the app'));

  -- A rider who was on this trip becomes free again, but stays online, unless
  -- they are already holding or running another request.
  if v_row.rider_id is not null then
    update public.rider_presence
       set is_available = is_online
         and not public.rider_has_active_ride(v_row.rider_id),
           updated_at = now()
     where profile_id = v_row.rider_id;
    update public.provider_profiles
       set is_available = exists (
         select 1 from public.rider_presence
          where profile_id = v_row.rider_id and is_available
       )
     where profile_id = v_row.rider_id;
  end if;

  v_counterparty := case
    when v_profile_id = v_row.passenger_id then v_row.rider_id
    else v_row.passenger_id
  end;
  select full_name into v_actor_name
    from public.profiles where id = v_profile_id;

  if v_counterparty is not null then
    insert into public.notifications (
      profile_id, notification_type, title, body, data
    ) values (
      v_counterparty,
      'ride',
      'Ride cancelled',
      coalesce(v_actor_name, 'The other party') || ' cancelled the ride: '
        || v_row.pickup_address || ' → ' || v_row.dropoff_address || '.',
      jsonb_build_object('ride_id', p_ride_id, 'kind', 'ride_cancelled')
    );
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.cancel_ride_request(uuid, text) from public, anon;
grant execute on function public.cancel_ride_request(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Advance a trip
-- ---------------------------------------------------------------------------

create or replace function public.advance_ride_status(
  p_ride_id uuid,
  p_status public.ride_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid := auth.uid();
  v_row public.ride_requests%rowtype;
  v_allowed boolean := false;
begin
  if v_profile_id is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;

  select * into v_row
    from public.ride_requests
   where id = p_ride_id
   for update;

  if not found then
    raise exception 'Ride not found.' using errcode = 'P0002';
  end if;
  if v_profile_id not in (v_row.passenger_id, coalesce(v_row.rider_id, v_row.passenger_id)) then
    raise exception 'Only a participant can advance this ride.'
      using errcode = '42501';
  end if;

  v_allowed := case
    when v_row.status = 'accepted' and p_status = 'heading_to_pickup' then true
    when v_row.status = 'heading_to_pickup' and p_status = 'arrived' then true
    when v_row.status = 'arrived' and p_status = 'in_progress' then true
    when v_row.status = 'in_progress' and p_status = 'completed' then true
    else false
  end;

  if not v_allowed then
    raise exception 'Cannot move a ride from % to %.',
      v_row.status, p_status using errcode = '22023';
  end if;

  update public.ride_requests
     set status = p_status,
         started_at = case
           when p_status = 'in_progress' then coalesce(started_at, now())
           else started_at
         end,
         completed_at = case
           when p_status = 'completed' then now()
           else completed_at
         end
   where id = p_ride_id
   returning * into v_row;

  insert into public.ride_status_events (ride_id, status, actor_profile_id, note)
  values (p_ride_id, p_status, v_profile_id, 'Status advanced from the app');

  if p_status = 'completed' then
    if v_row.rider_id is not null then
      update public.rider_presence
         set is_available = is_online
           and not public.rider_has_active_ride(v_row.rider_id),
             updated_at = now()
       where profile_id = v_row.rider_id;
      update public.provider_profiles
         set total_trips = total_trips + 1,
             is_available = exists (
               select 1 from public.rider_presence
                where profile_id = v_row.rider_id and is_available
             )
       where profile_id = v_row.rider_id;
    end if;

    update public.profiles
       set total_rides = total_rides + 1
     where id = v_row.passenger_id;

    insert into public.notifications (
      profile_id, notification_type, title, body, data
    ) values (
      v_row.passenger_id,
      'ride',
      'Trip completed',
      'Your trip from ' || v_row.pickup_address || ' to '
        || v_row.dropoff_address || ' is complete.',
      jsonb_build_object('ride_id', p_ride_id, 'kind', 'ride_completed')
    );
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.advance_ride_status(uuid, public.ride_status)
  from public, anon;
grant execute on function public.advance_ride_status(uuid, public.ride_status)
  to authenticated, service_role;
