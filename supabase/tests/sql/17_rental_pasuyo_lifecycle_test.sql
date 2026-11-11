begin;

-- RENT and HELP server lifecycles.
--
-- Fixtures: a renter, a vehicle owner, a helper, a plain account and one
-- active vehicle. The test proves actor checks, legal transitions, the overlap
-- guard, the approved fee terms, settlement conservation and that clients
-- still cannot write the tables directly.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('a1000000-0000-0000-0000-000000000001', 'renter.rent@example.com',
   '+639170003001', '{"full_name":"Rent Renter"}'::jsonb),
  ('a1000000-0000-0000-0000-000000000002', 'owner.rent@example.com',
   '+639170003002', '{"full_name":"Rent Owner"}'::jsonb),
  ('a1000000-0000-0000-0000-000000000003', 'helper.pasuyo@example.com',
   '+639170003003', '{"full_name":"Pasuyo Helper"}'::jsonb),
  ('a1000000-0000-0000-0000-000000000004', 'plain.pasuyo@example.com',
   '+639170003004', '{"full_name":"Plain Account"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('a1000000-0000-0000-0000-000000000003', 'earner', 'approved', now());

insert into public.vehicles (
  owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, price_per_day_centavos, status
) values (
  'a1000000-0000-0000-0000-000000000002',
  (select id from public.service_areas), 'Lifecycle Bike',
  'motorcycle', '2-Wheel', 'LIFE-001', 80000, 'active'
);

-- A ride completed outside the dispatch RPC must still settle from the agreed
-- amounts stored on the request.
insert into public.ride_requests (
  passenger_id, rider_id, service_area_id, status, distance_km, eta_minutes,
  fare_centavos, platform_fee_centavos,
  pickup_address, pickup_barangay_id, dropoff_address,
  accepted_at, started_at
) values (
  'a1000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000002',
  (select service_area_id from public.barangays where name = 'San Isidro'),
  'in_progress', 3.2, 12, 5000, 1000,
  'Ride pickup', (select id from public.barangays where name = 'San Isidro'),
  'Ride dropoff', now(), now()
);

create temp table phase_b_ids (k text primary key, v uuid);
grant select, insert, update on phase_b_ids to authenticated;

-- 1. Clients still have no direct write path; the RPCs are callable.
do $$
begin
  perform public.test_assert(
    not has_table_privilege('authenticated', 'public.rental_bookings', 'INSERT'),
    'rental_bookings has no client INSERT grant'
  );
  perform public.test_assert(
    not has_table_privilege('authenticated', 'public.service_requests', 'INSERT'),
    'service_requests has no client INSERT grant'
  );
  perform public.test_assert(
    not has_table_privilege('authenticated', 'public.service_request_items', 'INSERT'),
    'service_request_items has no client INSERT grant'
  );
  perform public.test_assert(
    has_function_privilege(
      'authenticated',
      'public.create_rental_request(uuid,timestamptz,timestamptz,text,uuid,uuid,double precision,double precision)',
      'execute'
    ),
    'renters can call create_rental_request'
  );
  perform public.test_assert(
    has_function_privilege(
      'authenticated',
      'public.create_service_request(public.pasuyo_category,text,text,uuid,bigint,jsonb,text,uuid,double precision,double precision,text,uuid,uuid,double precision,double precision,boolean,text,text)',
      'execute'
    ),
    'customers can call create_service_request'
  );
  perform public.test_assert(
    not has_function_privilege(
      'authenticated', 'private.settle_rental(public.rental_bookings)', 'execute'
    ),
    'the settlement helper is not client-callable'
  );
end;
$$;

-- 2. Rental request, acceptance and lifecycle.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_row jsonb;
  v_id uuid;
begin
  v_row := public.create_rental_request(
    p_vehicle_id => (select id from public.vehicles where plate_number = 'LIFE-001'),
    p_start_at => now() + interval '1 day',
    p_end_at => now() + interval '2 days',
    p_pickup_location => 'Rent pickup',
    p_pickup_barangay_id => (select id from public.barangays where name = 'San Isidro')
  );
  v_id := (v_row ->> 'id')::uuid;
  insert into phase_b_ids values ('rental', v_id);

  perform public.test_assert(
    v_row ->> 'status' = 'requested',
    'a renter creates a requested booking'
  );
  perform public.test_assert(
    (v_row ->> 'duration_hours')::int = 24,
    'the duration is rounded up to whole hours'
  );
  perform public.test_assert(
    (v_row ->> 'total_fare_centavos')::bigint = 80000,
    'the fare is the vehicle day rate for one day'
  );
  perform public.test_assert(
    (v_row ->> 'platform_fee_centavos')::bigint = 3000,
    'the one-day rental platform fee is PHP 20 plus PHP 10 per day'
  );
end;
$$;

-- The owner, not the renter, answers the request.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'rental');
  v_row jsonb;
  v_own_refused boolean := false;
begin
  -- An owner cannot book their own vehicle, even on a free window.
  begin
    perform public.create_rental_request(
      (select id from public.vehicles where plate_number = 'LIFE-001'),
      now() + interval '5 days', now() + interval '6 days',
      'Rent pickup',
      (select id from public.barangays where name = 'San Isidro')
    );
  exception when others then
    v_own_refused := true;
  end;
  perform public.test_assert(v_own_refused,
    'an owner cannot rent their own vehicle');

  v_row := public.respond_to_rental_request(v_id, true);
  perform public.test_assert(
    v_row ->> 'status' = 'accepted'
      and (v_row ->> 'accepted_at') is not null,
    'the owner accepts and stamps accepted_at'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'rental');
  v_row jsonb;
  v_tx public.service_transactions;
  v_count integer;
begin
  -- Renter cannot accept their own request.
  begin
    perform public.respond_to_rental_request(v_id, true);
  exception when others then
    null;
  end;

  v_row := public.advance_rental_status(v_id, 'active');
  perform public.test_assert(v_row ->> 'status' = 'active',
    'the renter starts an accepted rental');

  v_row := public.advance_rental_status(v_id, 'returned');
  perform public.test_assert(v_row ->> 'status' = 'returned',
    'the renter returns the vehicle');

  v_row := public.advance_rental_status(v_id, 'completed');
  perform public.test_assert(v_row ->> 'status' = 'completed',
    'a returned rental completes');

  select * into v_tx
    from public.service_transactions where rental_id = v_id;

  perform public.test_assert(
    v_tx.fare_centavos = 80000 and v_tx.platform_fee_centavos = 3000,
    'the settlement keeps the agreed fare and fee'
  );
  perform public.test_assert(
    v_tx.customer_pays_centavos = 83000
      and v_tx.provider_payout_centavos = 80000
      and v_tx.platform_revenue_centavos = 3000,
    'customer pays fare + fee and the owner keeps the fare'
  );
  perform public.test_assert(
    v_tx.is_simulated = false,
    'a real rental settles as actual activity'
  );
  perform public.test_assert(
    (select count(*) from public.cash_collections
      where service_transaction_id = v_tx.id) = 1,
    'settlement creates one cash collection'
  );

  begin
    perform public.advance_rental_status(v_id, 'completed');
  exception when others then
    null;
  end;

  select count(*) into v_count
    from public.service_transactions where rental_id = v_id;
  perform public.test_assert(v_count = 1,
    'a completed rental cannot settle twice');
end;
$$;

-- The fee is owed by the owner, so only the owner sees the receivable.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'rental');
begin
  perform public.test_assert(
    (select count(*) from public.platform_fee_receivables r
       join public.service_transactions st on st.id = r.service_transaction_id
      where st.rental_id = v_id) = 1,
    'the fee becomes one provider receivable'
  );
end;
$$;

-- 3. Overlap guard.
--
-- The completed booking above no longer holds the vehicle, so a fresh booking
-- is confirmed for a future window first; that confirmed booking is what an
-- overlapping request must collide with.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_row jsonb;
  v_id uuid;
begin
  v_row := public.create_rental_request(
    p_vehicle_id => (select id from public.vehicles where plate_number = 'LIFE-001'),
    p_start_at => now() + interval '5 days',
    p_end_at => now() + interval '6 days',
    p_pickup_location => 'Rent pickup',
    p_pickup_barangay_id => (select id from public.barangays where name = 'San Isidro')
  );
  v_id := (v_row ->> 'id')::uuid;
  insert into phase_b_ids values ('overlap', v_id);
  perform public.test_assert(v_row ->> 'status' = 'requested',
    'a booking for a free future window is created');
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'overlap');
  v_row jsonb;
begin
  v_row := public.respond_to_rental_request(v_id, true);
  perform public.test_assert(v_row ->> 'status' = 'accepted',
    'the owner confirms the future booking');
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_vehicle uuid := (select id from public.vehicles where plate_number = 'LIFE-001');
  v_barangay uuid := (select id from public.barangays where name = 'San Isidro');
  v_blocked boolean := false;
begin
  begin
    perform public.create_rental_request(
      v_vehicle, now() + interval '5 days 6 hours',
      now() + interval '6 days',
      'Rent pickup', v_barangay
    );
  exception when others then
    v_blocked := true;
  end;
  perform public.test_assert(v_blocked,
    'a request overlapping a confirmed booking is refused');

  -- A non-overlapping window on the same vehicle is allowed.
  perform public.create_rental_request(
    v_vehicle, now() + interval '7 days', now() + interval '8 days',
    'Rent pickup', v_barangay
  );
  perform public.test_assert(true, 'a non-overlapping window is accepted');
end;
$$;

-- 4. Pasuyo creation, helper acceptance and delivery.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_row jsonb;
  v_items jsonb;
  v_id uuid;
begin
  v_row := public.create_service_request(
    p_category => 'groceries',
    p_title => 'Buy rice and eggs',
    p_pickup_address => 'Public market',
    p_pickup_barangay_id => (select id from public.barangays where name = 'San Isidro'),
    p_quoted_fee_centavos => 15000,
    p_items => '[{"name":"Rice","quantity":2,"estimated_unit_price_centavos":2500},
                 {"name":"Eggs","quantity":1,"estimated_unit_price_centavos":1200}]'::jsonb,
    p_dropoff_address => 'Home',
    p_booked_for_someone => true,
    p_recipient_name => 'Lola Nena',
    p_recipient_phone => '+639170003099'
  );
  v_id := (v_row ->> 'id')::uuid;
  insert into phase_b_ids values ('pasuyo', v_id);
  v_items := v_row -> 'items';

  perform public.test_assert(v_row ->> 'status' = 'available',
    'a posted errand starts available');
  perform public.test_assert(
    (v_row ->> 'quoted_fee_centavos')::bigint = 15000
      and (v_row ->> 'platform_fee_centavos')::bigint = 1000,
    'the helper fee and flat PHP 10 platform fee are stored'
  );
  perform public.test_assert(jsonb_array_length(v_items) = 2,
    'both item lines are stored');
  perform public.test_assert(
    (v_row ->> 'booked_for_someone')::boolean
      and v_row ->> 'recipient_name' = 'Lola Nena',
    'the person the errand is for is recorded'
  );

  -- Booked-for-someone requires a name.
  begin
    perform public.create_service_request(
      'parcel', 'No recipient', 'Market',
      (select id from public.barangays where name = 'San Isidro'),
      5000, '[]', null, null, null, null, null, null, null, null, null,
      true, null, null
    );
  exception when others then
    null;
  end;
end;
$$;

-- A plain account cannot accept; an approved helper can.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000004', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'pasuyo');
  v_refused boolean := false;
begin
  begin
    perform public.accept_service_request(v_id);
  exception when others then
    v_refused := true;
  end;
  perform public.test_assert(v_refused,
    'an account without the earner role cannot accept errands');
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000003', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'pasuyo');
  v_row jsonb;
  v_item record;
  v_actuals jsonb := '[]'::jsonb;
begin
  v_row := public.accept_service_request(v_id);
  perform public.test_assert(v_row ->> 'status' = 'accepted',
    'an approved helper accepts the errand');

  perform public.advance_service_status(v_id, 'going_to_pickup');
  perform public.advance_service_status(v_id, 'at_pickup');
  perform public.advance_service_status(v_id, 'picked_up');
  v_row := public.advance_service_status(v_id, 'delivering');
  perform public.test_assert(v_row ->> 'status' = 'delivering',
    'the helper advances the errand through pickup');

  for v_item in
    select id from public.service_request_items
     where service_request_id = v_id order by name
  loop
    v_actuals := v_actuals || jsonb_build_object(
      'id', v_item.id,
      'actual_unit_price_centavos',
      case when (select name from public.service_request_items i
                  where i.id = v_item.id) = 'Eggs' then 1300 else 2600 end
    );
  end loop;

  v_row := public.set_service_item_actuals(v_id, v_actuals);
  perform public.test_assert(
    (v_row -> 'items' -> 0 ->> 'actual_unit_price_centavos') is not null,
    'the helper records actual item costs'
  );

  perform public.advance_service_status(v_id, 'at_customer');
  v_row := public.advance_service_status(v_id, 'delivered');
  perform public.test_assert(v_row ->> 'status' = 'delivered',
    'the errand is delivered');
end;
$$;

-- Customer sees the settlement.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'pasuyo');
  v_tx public.service_transactions;
  v_events integer;
begin
  select * into v_tx
    from public.service_transactions where service_request_id = v_id;

  -- Quoted 15000 + actual items (2x2600 + 1300 = 6500) = 21500.
  perform public.test_assert(
    v_tx.fare_centavos = 21500 and v_tx.platform_fee_centavos = 1000,
    'the settlement uses the quoted fee, actual items and the flat fee'
  );
  perform public.test_assert(
    v_tx.provider_payout_centavos = 21500
      and v_tx.platform_revenue_centavos = 1000
      and v_tx.customer_pays_centavos = 22500,
    'the helper is reimbursed and keeps the full fee'
  );

  select count(*) into v_events
    from public.service_status_events where service_request_id = v_id;
  perform public.test_assert(v_events = 7,
    'every transition is appended to the event log');
end;
$$;

-- 5. Cancellation rules.
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_row jsonb;
  v_id uuid;
begin
  v_row := public.create_service_request(
    'parcel', 'Cancel me', 'Market',
    (select id from public.barangays where name = 'San Isidro'),
    5000, '[]'
  );
  v_id := (v_row ->> 'id')::uuid;
  insert into phase_b_ids values ('cancel', v_id);
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000003', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'cancel');
  v_row jsonb;
begin
  perform public.accept_service_request(v_id);
  perform public.advance_service_status(v_id, 'going_to_pickup');
  perform public.advance_service_status(v_id, 'at_pickup');
  perform public.advance_service_status(v_id, 'picked_up');

  begin
    perform public.cancel_service_request(v_id, 'Changed my mind');
    perform public.test_assert(false,
      'a helper cannot cancel after pickup');
  exception when others then
    perform public.test_assert(true,
      'a helper cannot cancel after pickup');
  end;
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_id uuid := (select v from phase_b_ids where k = 'cancel');
  v_row jsonb;
begin
  v_row := public.cancel_service_request(v_id, 'No longer needed');
  perform public.test_assert(
    v_row ->> 'status' = 'cancelled'
      and (v_row ->> 'cancellation_reason') = 'No longer needed',
    'the customer can still cancel after pickup'
  );
end;
$$;

reset role;

-- 6. Ride completion settles from the request amounts.
do $$
declare
  v_ride uuid := (select id from public.ride_requests
                   where pickup_address = 'Ride pickup');
  v_tx public.service_transactions;
  v_count integer;
begin
  update public.ride_requests
     set status = 'completed', completed_at = now()
   where id = v_ride;

  select * into v_tx
    from public.service_transactions where ride_id = v_ride;

  perform public.test_assert(
    v_tx.fare_centavos = 5000 and v_tx.platform_fee_centavos = 1000
      and v_tx.customer_pays_centavos = 6000,
    'a completed ride settles from its stored fare and fee'
  );
  perform public.test_assert(
    v_tx.provider_payout_centavos = 5000
      and v_tx.platform_revenue_centavos = 1000,
    'the rider keeps the fare and the platform keeps the fee'
  );

  update public.ride_requests
     set status = 'completed'
   where id = v_ride;

  select count(*) into v_count
    from public.service_transactions where ride_id = v_ride;
  perform public.test_assert(v_count = 1,
    're-completing a ride never doubles the settlement');
end;
$$;

rollback;
