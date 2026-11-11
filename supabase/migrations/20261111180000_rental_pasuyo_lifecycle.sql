-- RENT and HELP transactions, end to end, on the server.
--
-- The app previously wrote rentals and Pasuyo errands into memory only. This
-- migration gives both flows the same shape as ride dispatch: the client calls
-- a SECURITY DEFINER function, the function checks the actor and the state
-- transition, and every row lands in Postgres with a settlement.
--
-- Commercial terms applied here (approved for the presentation build):
--   * provider keeps 100% of the agreed fare;
--   * the platform fee is a customer add-on, never a deduction;
--   * rental fee = clamp(PHP 20 + PHP 10 per started day, PHP 20, PHP 150);
--   * Pasuyo fee = PHP 10 flat per errand;
--   * Pasuyo item cost is a pass-through and is not charged a platform fee.
--
-- Completion writes one service_transactions row per booking. The row keeps
-- the agreed fare instead of recomputing it, so a later pricing-policy change
-- cannot rewrite what the parties agreed. Rides settle the same way through a
-- completion trigger, because advance_ride_status only moves the status.
--
-- No payment is captured here. Every settlement is cash, provider_payout equals
-- the fare, and the platform fee becomes a receivable the provider remits.

-- ---------------------------------------------------------------------------
-- 1. Fee terms and notification helper
-- ---------------------------------------------------------------------------

create or replace function private.rental_platform_fee(
  p_duration_hours integer
)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select least(
    15000,
    greatest(2000, 2000 + (1000 * greatest(1, ceil(
      coalesce(p_duration_hours, 1)::numeric / 24
    )::int)))
  );
$$;

create or replace function private.pasuyo_platform_fee()
returns bigint
language sql
immutable
set search_path = ''
as $$
  select 1000::bigint;
$$;

revoke all on function private.rental_platform_fee(integer)
  from public, anon, authenticated, service_role;
revoke all on function private.pasuyo_platform_fee()
  from public, anon, authenticated, service_role;

create or replace function private.notify(
  p_profile_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_data jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notifications (
    profile_id, notification_type, title, body, data
  ) values (
    p_profile_id, p_type, p_title, p_body, coalesce(p_data, '{}'::jsonb)
  );
$$;

revoke all on function private.notify(uuid, text, text, text, jsonb)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Recipient details for Pasuyo booked for someone else
-- ---------------------------------------------------------------------------

alter table public.service_requests
  add column if not exists booked_for_someone boolean not null default false,
  add column if not exists recipient_name text,
  add column if not exists recipient_phone text;

alter table public.service_requests
  drop constraint if exists service_requests_recipient_check;
alter table public.service_requests
  add constraint service_requests_recipient_check check (
    not booked_for_someone
    or (recipient_name is not null and length(trim(recipient_name)) > 0)
  );

comment on column public.service_requests.booked_for_someone is
  'True when the customer ordered the errand for another person.';
comment on column public.service_requests.recipient_name is
  'The person who receives the errand, when different from the customer.';

-- ---------------------------------------------------------------------------
-- 3. Rental pricing and settlement
-- ---------------------------------------------------------------------------

create or replace function private.settle_rental(p_rental public.rental_bookings)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fare bigint := coalesce(p_rental.total_fare_centavos, 0);
  v_fee bigint := coalesce(p_rental.platform_fee_centavos, 0);
  v_tx_id uuid;
  v_snapshot jsonb;
begin
  if v_fare <= 0 then
    raise exception 'Rental fare must be positive before settlement'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.service_transactions st
     where st.rental_id = p_rental.id
  ) then
    return;
  end if;

  v_snapshot := jsonb_build_object(
    'source', 'rental_agreed_fare',
    'rental_id', p_rental.id,
    'vehicle_id', p_rental.vehicle_id,
    'duration_hours', p_rental.duration_hours,
    'fare_centavos', v_fare,
    'platform_fee_centavos', v_fee,
    'fee_rule', 'customer_addon: 20 + 10 per started day, capped at 150',
    'currency', 'PHP',
    'captured_at', to_jsonb(now())
  );

  insert into public.service_transactions (
    service_type, rental_id, customer_id, provider_id,
    fare_centavos, platform_fee_centavos, customer_pays_centavos,
    provider_payout_centavos, platform_revenue_centavos,
    payment_method, status, settled_at,
    fee_mode, fee_type, duration_minutes, pricing_snapshot
  ) values (
    'rental', p_rental.id, p_rental.renter_id, p_rental.owner_id,
    v_fare, v_fee, v_fare + v_fee, v_fare, v_fee,
    'cash', 'completed', now(),
    'customer_addon', 'fixed',
    greatest(0, coalesce(p_rental.duration_hours, 0) * 60),
    v_snapshot
  )
  on conflict (rental_id) where rental_id is not null do nothing
  returning id into v_tx_id;

  if v_tx_id is not null then
    perform public.ensure_transaction_accounts(v_tx_id);
  end if;
end;
$$;

revoke all on function private.settle_rental(public.rental_bookings)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Rental lifecycle
-- ---------------------------------------------------------------------------

create or replace function public.create_rental_request(
  p_vehicle_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_pickup_location text,
  p_pickup_barangay_id uuid,
  p_pickup_purok_id uuid default null,
  p_pickup_latitude double precision default null,
  p_pickup_longitude double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_vehicle public.vehicles;
  v_hours integer;
  v_days integer;
  v_area uuid;
  v_fee bigint;
  v_row public.rental_bookings;
begin
  if v_actor is null then
    raise exception 'Sign in to request a rental' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.profiles p
     where p.id = v_actor and p.account_status = 'active'
  ) then
    raise exception 'This account cannot book a rental'
      using errcode = '42501';
  end if;

  if p_vehicle_id is null or p_start_at is null or p_end_at is null then
    raise exception 'Vehicle, start and end are required'
      using errcode = '22023';
  end if;

  if p_end_at <= p_start_at then
    raise exception 'The return must be after the pickup'
      using errcode = '22023';
  end if;

  if p_start_at < now() - interval '1 hour' then
    raise exception 'The pickup cannot be in the past'
      using errcode = '22023';
  end if;

  if p_end_at > p_start_at + interval '30 days' then
    raise exception 'A rental cannot exceed 30 days'
      using errcode = '22023';
  end if;

  select * into v_vehicle
    from public.vehicles v
   where v.id = p_vehicle_id
   for update;

  if not found or v_vehicle.status <> 'active' then
    raise exception 'This vehicle is not available' using errcode = 'P0002';
  end if;

  if v_vehicle.owner_profile_id = v_actor then
    raise exception 'You cannot rent your own vehicle'
      using errcode = '22023';
  end if;

  v_area := v_vehicle.service_area_id;
  if v_area is null then
    raise exception 'This vehicle has no service area' using errcode = 'P0002';
  end if;

  if p_pickup_barangay_id is null or not exists (
    select 1 from public.barangays b
     where b.id = p_pickup_barangay_id and b.service_area_id = v_area
  ) then
    raise exception 'Choose a pickup barangay in the vehicle service area'
      using errcode = '22023';
  end if;

  v_hours := greatest(
    1, ceil(extract(epoch from (p_end_at - p_start_at)) / 3600)::int
  );
  v_days := greatest(1, ceil(v_hours::numeric / 24)::int);

  -- Serialize concurrent requests for the same vehicle, then reject an
  -- overlap. There is no exclusion constraint because seeded history contains
  -- a legitimate overlapping pair that must remain readable.
  perform pg_advisory_xact_lock(hashtext(v_vehicle.id::text));

  if exists (
    select 1 from public.rental_bookings rb
     where rb.vehicle_id = v_vehicle.id
       and rb.status in ('requested', 'awaiting_owner', 'accepted', 'active')
       and tstzrange(rb.start_at, rb.end_at, '[)')
           && tstzrange(p_start_at, p_end_at, '[)')
  ) then
    raise exception 'This vehicle is already booked for those dates'
      using errcode = 'P0001';
  end if;

  v_fee := private.rental_platform_fee(v_hours);

  insert into public.rental_bookings (
    renter_id, owner_id, vehicle_id, service_area_id, status,
    start_at, end_at, duration_hours,
    pickup_location, pickup_barangay_id, pickup_purok_id,
    pickup_latitude, pickup_longitude,
    total_fare_centavos, platform_fee_centavos, payment_method
  ) values (
    v_actor, v_vehicle.owner_profile_id, v_vehicle.id, v_area, 'requested',
    p_start_at, p_end_at, v_hours,
    nullif(trim(p_pickup_location), ''), p_pickup_barangay_id,
    p_pickup_purok_id, p_pickup_latitude, p_pickup_longitude,
    v_vehicle.price_per_day_centavos * v_days, v_fee, 'cash'
  ) returning * into v_row;

  perform private.notify(
    v_vehicle.owner_profile_id,
    'rental',
    'New rental request',
    'A renter requested ' || v_vehicle.name || '.',
    jsonb_build_object('rental_id', v_row.id, 'kind', 'rental_request')
  );

  return to_jsonb(v_row) || jsonb_build_object(
    'vehicle_name', v_vehicle.name,
    'plate_number', v_vehicle.plate_number
  );
end;
$$;

create or replace function public.respond_to_rental_request(
  p_rental_id uuid,
  p_accept boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.rental_bookings;
  v_vehicle public.vehicles;
begin
  select * into v_row
    from public.rental_bookings rb
   where rb.id = p_rental_id
   for update;

  if not found then
    raise exception 'Rental not found' using errcode = 'P0002';
  end if;

  if v_row.owner_id <> v_actor then
    raise exception 'Only the vehicle owner can answer this request'
      using errcode = '42501';
  end if;

  if v_row.status not in ('requested', 'awaiting_owner') then
    raise exception 'This request is already %', v_row.status
      using errcode = 'P0001';
  end if;

  if not p_accept then
    update public.rental_bookings
       set status = 'declined', declined_at = now()
     where id = v_row.id
     returning * into v_row;

    perform private.notify(
      v_row.renter_id, 'rental', 'Rental declined',
      'The owner declined this rental request.',
      jsonb_build_object('rental_id', v_row.id, 'kind', 'rental_declined')
    );
    return to_jsonb(v_row);
  end if;

  perform pg_advisory_xact_lock(hashtext(v_row.vehicle_id::text));

  if exists (
    select 1 from public.rental_bookings rb
     where rb.vehicle_id = v_row.vehicle_id
       and rb.id <> v_row.id
       and rb.status in ('accepted', 'active')
       and tstzrange(rb.start_at, rb.end_at, '[)')
           && tstzrange(v_row.start_at, v_row.end_at, '[)')
  ) then
    raise exception 'Another confirmed booking covers those dates'
      using errcode = 'P0001';
  end if;

  select * into v_vehicle
    from public.vehicles v where v.id = v_row.vehicle_id;

  update public.rental_bookings
     set status = 'accepted', accepted_at = now()
   where id = v_row.id
   returning * into v_row;

  perform private.notify(
    v_row.renter_id, 'rental', 'Rental accepted',
    coalesce(v_vehicle.name, 'Your rental') || ' is confirmed.',
    jsonb_build_object('rental_id', v_row.id, 'kind', 'rental_accepted')
  );

  return to_jsonb(v_row);
end;
$$;

create or replace function public.advance_rental_status(
  p_rental_id uuid,
  p_status public.rental_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.rental_bookings;
  v_allowed boolean;
begin
  select * into v_row
    from public.rental_bookings rb
   where rb.id = p_rental_id
   for update;

  if not found then
    raise exception 'Rental not found' using errcode = 'P0002';
  end if;

  if v_actor not in (v_row.renter_id, v_row.owner_id) then
    raise exception 'Only a participant can advance this rental'
      using errcode = '42501';
  end if;

  v_allowed := case
    when v_row.status = 'accepted' and p_status = 'active' then true
    when v_row.status = 'active' and p_status = 'returned' then true
    when v_row.status = 'returned' and p_status = 'completed' then true
    else false
  end;

  if not v_allowed then
    raise exception 'Cannot move a rental from % to %',
      v_row.status, p_status using errcode = '22023';
  end if;

  update public.rental_bookings
     set status = p_status,
         started_at = case
           when p_status = 'active' then coalesce(started_at, now())
           else started_at
         end,
         returned_at = case
           when p_status = 'returned' then coalesce(returned_at, now())
           else returned_at
         end,
         completed_at = case
           when p_status = 'completed' then coalesce(completed_at, now())
           else completed_at
         end
   where id = v_row.id
   returning * into v_row;

  if p_status = 'completed' then
    perform private.settle_rental(v_row);

    update public.vehicles
       set total_rentals = total_rentals + 1
     where id = v_row.vehicle_id;

    perform private.notify(
      v_row.renter_id, 'rental', 'Rental completed',
      'Your rental is complete.',
      jsonb_build_object('rental_id', v_row.id, 'kind', 'rental_completed')
    );
    perform private.notify(
      v_row.owner_id, 'rental', 'Rental completed',
      'The vehicle has been returned.',
      jsonb_build_object('rental_id', v_row.id, 'kind', 'rental_completed')
    );
  end if;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.cancel_rental_request(
  p_rental_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.rental_bookings;
begin
  select * into v_row
    from public.rental_bookings rb
   where rb.id = p_rental_id
   for update;

  if not found then
    raise exception 'Rental not found' using errcode = 'P0002';
  end if;

  if v_actor not in (v_row.renter_id, v_row.owner_id) then
    raise exception 'Only a participant can cancel this rental'
      using errcode = '42501';
  end if;

  if v_row.status not in ('requested', 'awaiting_owner', 'accepted', 'active') then
    raise exception 'A % rental cannot be cancelled', v_row.status
      using errcode = 'P0001';
  end if;

  update public.rental_bookings
     set status = 'cancelled',
         cancelled_at = now(),
         cancellation_reason = coalesce(
           nullif(trim(p_reason), ''), 'Cancelled from the app'
         )
   where id = v_row.id
   returning * into v_row;

  perform private.notify(
    case when v_actor = v_row.renter_id
      then v_row.owner_id else v_row.renter_id end,
    'rental', 'Rental cancelled',
    'The rental was cancelled.',
    jsonb_build_object('rental_id', v_row.id, 'kind', 'rental_cancelled')
  );

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Pasuyo pricing and settlement
-- ---------------------------------------------------------------------------

create or replace function private.settle_pasuyo(
  p_request public.service_requests
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_items bigint;
  v_fare bigint;
  v_fee bigint := coalesce(p_request.platform_fee_centavos, 0);
  v_tx_id uuid;
  v_snapshot jsonb;
begin
  if p_request.provider_id is null then
    raise exception 'An errand cannot settle without a helper'
      using errcode = 'P0001';
  end if;

  select coalesce(round(sum(
    i.quantity * coalesce(
      i.actual_unit_price_centavos,
      i.estimated_unit_price_centavos,
      0
    )
  )), 0)::bigint
    into v_items
    from public.service_request_items i
   where i.service_request_id = p_request.id;

  v_fare := coalesce(p_request.quoted_fee_centavos, 0) + v_items;
  if v_fare <= 0 then
    raise exception 'The errand has no charge to settle'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.service_transactions st
     where st.service_request_id = p_request.id
  ) then
    return;
  end if;

  v_snapshot := jsonb_build_object(
    'source', 'pasuyo_agreed_fee',
    'service_request_id', p_request.id,
    'quoted_fee_centavos', p_request.quoted_fee_centavos,
    'item_cost_centavos', v_items,
    'fare_centavos', v_fare,
    'platform_fee_centavos', v_fee,
    'fee_rule', 'flat 10 per errand, customer add-on',
    'booked_for_someone', p_request.booked_for_someone,
    'recipient_name', p_request.recipient_name,
    'currency', 'PHP',
    'captured_at', to_jsonb(now())
  );

  insert into public.service_transactions (
    service_type, service_request_id, customer_id, provider_id,
    fare_centavos, platform_fee_centavos, customer_pays_centavos,
    provider_payout_centavos, platform_revenue_centavos,
    payment_method, status, settled_at,
    fee_mode, fee_type, pricing_snapshot
  ) values (
    'pasuyo', p_request.id, p_request.customer_id, p_request.provider_id,
    v_fare, v_fee, v_fare + v_fee, v_fare, v_fee,
    'cash', 'completed', now(),
    'customer_addon', 'fixed', v_snapshot
  )
  on conflict (service_request_id) where service_request_id is not null
  do nothing
  returning id into v_tx_id;

  if v_tx_id is not null then
    perform public.ensure_transaction_accounts(v_tx_id);
  end if;
end;
$$;

revoke all on function private.settle_pasuyo(public.service_requests)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Pasuyo lifecycle
-- ---------------------------------------------------------------------------

create or replace function public.create_service_request(
  p_category public.pasuyo_category,
  p_title text,
  p_pickup_address text,
  p_pickup_barangay_id uuid,
  p_quoted_fee_centavos bigint,
  p_items jsonb default '[]'::jsonb,
  p_description text default null,
  p_pickup_purok_id uuid default null,
  p_pickup_latitude double precision default null,
  p_pickup_longitude double precision default null,
  p_dropoff_address text default null,
  p_dropoff_barangay_id uuid default null,
  p_dropoff_purok_id uuid default null,
  p_dropoff_latitude double precision default null,
  p_dropoff_longitude double precision default null,
  p_booked_for_someone boolean default false,
  p_recipient_name text default null,
  p_recipient_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_area uuid;
  v_row public.service_requests;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'Sign in to post an errand' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.profiles p
     where p.id = v_actor and p.account_status = 'active'
  ) then
    raise exception 'This account cannot post an errand'
      using errcode = '42501';
  end if;

  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'A title is required' using errcode = '22023';
  end if;

  if p_pickup_address is null or length(trim(p_pickup_address)) = 0 then
    raise exception 'A pickup address is required' using errcode = '22023';
  end if;

  if p_quoted_fee_centavos is null or p_quoted_fee_centavos <= 0 then
    raise exception 'The helper fee must be positive' using errcode = '22023';
  end if;

  if p_items is null then
    v_items := '[]'::jsonb;
  elsif jsonb_typeof(p_items) <> 'array' then
    raise exception 'Items must be a JSON array' using errcode = '22023';
  else
    v_items := p_items;
  end if;

  if p_booked_for_someone
     and (p_recipient_name is null
          or length(trim(p_recipient_name)) = 0) then
    raise exception 'Name the person this errand is for'
      using errcode = '22023';
  end if;

  select b.service_area_id into v_area
    from public.barangays b
   where b.id = p_pickup_barangay_id;

  if v_area is null then
    raise exception 'Choose a pickup barangay' using errcode = '22023';
  end if;

  if p_dropoff_barangay_id is not null and not exists (
    select 1 from public.barangays b
     where b.id = p_dropoff_barangay_id and b.service_area_id = v_area
  ) then
    raise exception 'The drop-off must be in the same service area'
      using errcode = '22023';
  end if;

  insert into public.service_requests (
    customer_id, service_area_id, category, status, title, description,
    pickup_address, pickup_barangay_id, pickup_purok_id,
    pickup_latitude, pickup_longitude,
    dropoff_address, dropoff_barangay_id, dropoff_purok_id,
    dropoff_latitude, dropoff_longitude,
    budget_centavos, quoted_fee_centavos, platform_fee_centavos,
    payment_method, booked_for_someone, recipient_name, recipient_phone
  ) values (
    v_actor, v_area, p_category, 'available',
    trim(p_title), nullif(trim(p_description), ''),
    trim(p_pickup_address), p_pickup_barangay_id, p_pickup_purok_id,
    p_pickup_latitude, p_pickup_longitude,
    nullif(trim(p_dropoff_address), ''), p_dropoff_barangay_id,
    p_dropoff_purok_id, p_dropoff_latitude, p_dropoff_longitude,
    p_quoted_fee_centavos, p_quoted_fee_centavos, private.pasuyo_platform_fee(),
    'cash', coalesce(p_booked_for_someone, false),
    nullif(trim(p_recipient_name), ''), nullif(trim(p_recipient_phone), '')
  ) returning * into v_row;

  insert into public.service_request_items (
    service_request_id, name, quantity, unit,
    estimated_unit_price_centavos, notes
  )
  select v_row.id, x.name, coalesce(x.quantity, 1), x.unit,
         x.estimated_unit_price_centavos, x.notes
    from jsonb_to_recordset(v_items) as x(
      name text, quantity numeric, unit text,
      estimated_unit_price_centavos bigint, notes text
    )
   where x.name is not null and length(trim(x.name)) > 0
     and coalesce(x.quantity, 1) > 0;

  return to_jsonb(v_row) || jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from public.service_request_items i
       where i.service_request_id = v_row.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.accept_service_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.service_requests;
begin
  if v_actor is null then
    raise exception 'Sign in to accept an errand' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.profiles p
     where p.id = v_actor and p.account_status = 'active'
  ) or not public.has_approved_role('earner') then
    raise exception 'Only an approved helper can accept errands'
      using errcode = '42501';
  end if;

  select * into v_row
    from public.service_requests sr
   where sr.id = p_request_id
   for update;

  if not found then
    raise exception 'Errand not found' using errcode = 'P0002';
  end if;

  if v_row.status <> 'available' then
    raise exception 'This errand is already %', v_row.status
      using errcode = 'P0001';
  end if;

  if v_row.customer_id = v_actor then
    raise exception 'You cannot accept your own errand'
      using errcode = '22023';
  end if;

  update public.service_requests
     set provider_id = v_actor, status = 'accepted', accepted_at = now()
   where id = v_row.id
   returning * into v_row;

  insert into public.service_status_events (
    service_request_id, status, actor_profile_id, note
  ) values (v_row.id, 'accepted', v_actor, 'Helper accepted the errand');

  perform private.notify(
    v_row.customer_id, 'pasuyo', 'Helper accepted your errand',
    'A helper is on the way.',
    jsonb_build_object('request_id', v_row.id, 'kind', 'pasuyo_accepted')
  );

  return to_jsonb(v_row);
end;
$$;

create or replace function public.advance_service_status(
  p_request_id uuid,
  p_status public.pasuyo_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.service_requests;
  v_allowed boolean;
begin
  select * into v_row
    from public.service_requests sr
   where sr.id = p_request_id
   for update;

  if not found then
    raise exception 'Errand not found' using errcode = 'P0002';
  end if;

  if v_row.provider_id is distinct from v_actor then
    raise exception 'Only the assigned helper can advance this errand'
      using errcode = '42501';
  end if;

  v_allowed := case
    when v_row.status = 'accepted'
      and p_status = 'going_to_pickup' then true
    when v_row.status = 'going_to_pickup'
      and p_status = 'at_pickup' then true
    when v_row.status = 'at_pickup'
      and p_status = 'picked_up' then true
    when v_row.status = 'picked_up'
      and p_status = 'delivering' then true
    when v_row.status = 'delivering'
      and p_status = 'at_customer' then true
    when v_row.status = 'at_customer'
      and p_status = 'delivered' then true
    else false
  end;

  if not v_allowed then
    raise exception 'Cannot move an errand from % to %',
      v_row.status, p_status using errcode = '22023';
  end if;

  update public.service_requests
     set status = p_status,
         picked_up_at = case
           when p_status = 'picked_up' then coalesce(picked_up_at, now())
           else picked_up_at
         end,
         delivered_at = case
           when p_status = 'delivered' then coalesce(delivered_at, now())
           else delivered_at
         end
   where id = v_row.id
   returning * into v_row;

  insert into public.service_status_events (
    service_request_id, status, actor_profile_id, note
  ) values (v_row.id, p_status, v_actor, 'Status advanced from the app');

  if p_status = 'delivered' then
    perform private.settle_pasuyo(v_row);

    perform private.notify(
      v_row.customer_id, 'pasuyo', 'Errand delivered',
      'Your errand was delivered.',
      jsonb_build_object('request_id', v_row.id, 'kind', 'pasuyo_delivered')
    );
  end if;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.set_service_item_actuals(
  p_request_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.service_requests;
begin
  select * into v_row
    from public.service_requests sr
   where sr.id = p_request_id
   for update;

  if not found then
    raise exception 'Errand not found' using errcode = 'P0002';
  end if;

  if v_row.provider_id is distinct from v_actor then
    raise exception 'Only the assigned helper can record item costs'
      using errcode = '42501';
  end if;

  if v_row.status not in ('accepted', 'going_to_pickup', 'at_pickup',
                          'picked_up', 'delivering', 'at_customer') then
    raise exception 'Item costs cannot change at %', v_row.status
      using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Items must be a JSON array' using errcode = '22023';
  end if;

  update public.service_request_items i
     set actual_unit_price_centavos = x.actual_unit_price_centavos,
         quantity = coalesce(x.quantity, i.quantity)
    from jsonb_to_recordset(p_items) as x(
      id uuid, actual_unit_price_centavos bigint, quantity numeric
    )
   where i.id = x.id
     and i.service_request_id = v_row.id
     and x.actual_unit_price_centavos >= 0;

  return to_jsonb(v_row) || jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at)
        from public.service_request_items i
       where i.service_request_id = v_row.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.cancel_service_request(
  p_request_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.service_requests;
  v_cancelled_by_customer boolean;
begin
  select * into v_row
    from public.service_requests sr
   where sr.id = p_request_id
   for update;

  if not found then
    raise exception 'Errand not found' using errcode = 'P0002';
  end if;

  if v_actor not in (v_row.customer_id, v_row.provider_id) then
    raise exception 'Only a participant can cancel this errand'
      using errcode = '42501';
  end if;

  if v_row.status in ('delivered', 'cancelled') then
    raise exception 'A % errand cannot be cancelled', v_row.status
      using errcode = 'P0001';
  end if;

  -- Once the helper has the items, only the customer's agreement keeps the
  -- errand cancellable; the helper can no longer drop it unilaterally.
  v_cancelled_by_customer := v_actor = v_row.customer_id;
  if not v_cancelled_by_customer
     and v_row.status in ('picked_up', 'delivering', 'at_customer') then
    raise exception 'The helper cannot cancel after pickup'
      using errcode = 'P0001';
  end if;

  update public.service_requests
     set status = 'cancelled',
         cancelled_at = now(),
         cancellation_reason = coalesce(
           nullif(trim(p_reason), ''), 'Cancelled from the app'
         )
   where id = v_row.id
   returning * into v_row;

  insert into public.service_status_events (
    service_request_id, status, actor_profile_id, note
  ) values (v_row.id, 'cancelled', v_actor,
            coalesce(nullif(trim(p_reason), ''), 'Cancelled from the app'));

  if v_actor = v_row.customer_id and v_row.provider_id is not null then
    perform private.notify(
      v_row.provider_id, 'pasuyo', 'Errand cancelled',
      'The customer cancelled the errand.',
      jsonb_build_object('request_id', v_row.id, 'kind', 'pasuyo_cancelled')
    );
  elsif v_actor <> v_row.customer_id then
    perform private.notify(
      v_row.customer_id, 'pasuyo', 'Errand cancelled',
      'The helper cancelled the errand.',
      jsonb_build_object('request_id', v_row.id, 'kind', 'pasuyo_cancelled')
    );
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Ride completion settlement
-- ---------------------------------------------------------------------------

create or replace function private.settle_completed_ride()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fare bigint := coalesce(new.fare_centavos, 0);
  v_fee bigint := coalesce(new.platform_fee_centavos, 0);
  v_tx_id uuid;
  v_snapshot jsonb;
begin
  if new.rider_id is null or (v_fare = 0 and v_fee = 0) then
    return new;
  end if;

  if exists (
    select 1 from public.service_transactions st where st.ride_id = new.id
  ) then
    return new;
  end if;

  v_snapshot := jsonb_build_object(
    'source', 'ride_request_fare',
    'ride_id', new.id,
    'fare_centavos', v_fare,
    'platform_fee_centavos', v_fee,
    'distance_km', new.distance_km,
    'duration_minutes', new.eta_minutes,
    'currency', 'PHP',
    'captured_at', to_jsonb(now())
  );

  insert into public.service_transactions (
    service_type, ride_id, customer_id, provider_id,
    fare_centavos, platform_fee_centavos, customer_pays_centavos,
    provider_payout_centavos, platform_revenue_centavos,
    payment_method, status, settled_at,
    fee_mode, fee_type, distance_km, duration_minutes, pricing_snapshot
  ) values (
    'ride', new.id, new.passenger_id, new.rider_id,
    v_fare, v_fee, v_fare + v_fee, v_fare, v_fee,
    'cash', 'completed', now(),
    'customer_addon', 'fixed',
    new.distance_km, new.eta_minutes, v_snapshot
  )
  on conflict (ride_id) where ride_id is not null do nothing
  returning id into v_tx_id;

  if v_tx_id is not null then
    perform public.ensure_transaction_accounts(v_tx_id);
  end if;

  return new;
end;
$$;

revoke all on function private.settle_completed_ride()
  from public, anon, authenticated, service_role;

create trigger ride_requests_settle_on_completion
  after update of status on public.ride_requests
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function private.settle_completed_ride();

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.create_rental_request(uuid,timestamptz,timestamptz,text,uuid,uuid,double precision,double precision)',
    'public.respond_to_rental_request(uuid,boolean)',
    'public.advance_rental_status(uuid,public.rental_status)',
    'public.cancel_rental_request(uuid,text)',
    'public.create_service_request(public.pasuyo_category,text,text,uuid,bigint,jsonb,text,uuid,double precision,double precision,text,uuid,uuid,double precision,double precision,boolean,text,text)',
    'public.accept_service_request(uuid)',
    'public.advance_service_status(uuid,public.pasuyo_status)',
    'public.set_service_item_actuals(uuid,jsonb)',
    'public.cancel_service_request(uuid,text)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_signature);
    execute format(
      'grant execute on function %s to authenticated, service_role',
      v_signature
    );
  end loop;
end;
$$;

revoke all on function private.notify(uuid, text, text, text, jsonb)
  from public, anon, authenticated, service_role;
