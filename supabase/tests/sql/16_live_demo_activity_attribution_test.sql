begin;

-- Live demo attribution: rows created after seeding must carry is_simulated
-- when either party is a provisioned demo identity.
--
-- The marker lives in auth.users.raw_app_meta_data and is written with the
-- service role only. These tests prove:
--   * demo-to-real and real-to-demo activity is simulated;
--   * real-to-real activity stays real;
--   * the flag is sticky when a demo rider/owner/provider is assigned later;
--   * wallet rows inherit the account owner's identity;
--   * clients cannot call the private helpers.

insert into auth.users (id, email, phone, raw_user_meta_data, raw_app_meta_data)
values
  ('f0000000-0000-0000-0000-000000000001', 'demo.passenger@surgo-demo.test',
   '+639170002001', '{"full_name":"Demo Passenger"}'::jsonb,
   '{"surgo_demo":true}'::jsonb),
  ('f0000000-0000-0000-0000-000000000002', 'demo.rider@surgo-demo.test',
   '+639170002002', '{"full_name":"Demo Rider"}'::jsonb,
   '{"surgo_demo":true}'::jsonb),
  ('f0000000-0000-0000-0000-000000000003', 'real.customer@example.com',
   '+639170002003', '{"full_name":"Real Customer"}'::jsonb, '{}'::jsonb),
  ('f0000000-0000-0000-0000-000000000004', 'real.provider@example.com',
   '+639170002004', '{"full_name":"Real Provider"}'::jsonb, '{}'::jsonb);

-- 1. Only service-role metadata marks an identity as demo.
do $$
begin
  perform public.test_assert(
    private.is_demo_identity('f0000000-0000-0000-0000-000000000001'),
    'a provisioned demo identity is recognised'
  );
  perform public.test_assert(
    not private.is_demo_identity('f0000000-0000-0000-0000-000000000003'),
    'a real identity is not demo'
  );
  perform public.test_assert(
    not has_function_privilege(
      'authenticated', 'private.is_demo_identity(uuid)', 'execute'
    ),
    'clients cannot execute the demo identity helper'
  );
  perform public.test_assert(
    not has_function_privilege(
      'authenticated', 'private.mark_simulated_parties()', 'execute'
    ),
    'clients cannot execute the attribution trigger function'
  );
end;
$$;

-- 2. Rides: demo passenger -> simulated even with a real rider.
do $$
declare
  v_demo_ride uuid;
  v_real_ride uuid;
  v_area uuid := (select service_area_id from public.barangays
                   where name = 'San Isidro');
  v_barangay uuid := (select id from public.barangays
                       where name = 'San Isidro');
begin
  insert into public.ride_requests (
    passenger_id, rider_id, service_area_id, status,
    pickup_address, pickup_barangay_id, dropoff_address, is_simulated
  ) values (
    'f0000000-0000-0000-0000-000000000001',
    'f0000000-0000-0000-0000-000000000004',
    v_area, 'searching', 'Demo pickup', v_barangay, 'Demo dropoff', false
  ) returning id into v_demo_ride;

  perform public.test_assert(
    (select is_simulated from public.ride_requests where id = v_demo_ride),
    'a demo passenger ride is simulated even when inserted with false'
  );

  insert into public.ride_requests (
    passenger_id, rider_id, service_area_id, status,
    pickup_address, pickup_barangay_id, dropoff_address
  ) values (
    'f0000000-0000-0000-0000-000000000003',
    'f0000000-0000-0000-0000-000000000004',
    v_area, 'searching', 'Real pickup', v_barangay, 'Real dropoff'
  ) returning id into v_real_ride;

  perform public.test_assert(
    not (select is_simulated from public.ride_requests where id = v_real_ride),
    'a real-to-real ride stays actual'
  );

  update public.ride_requests
     set rider_id = 'f0000000-0000-0000-0000-000000000002'
   where id = v_real_ride;

  perform public.test_assert(
    (select is_simulated from public.ride_requests where id = v_real_ride),
    'assigning a demo rider later marks the ride simulated'
  );
end;
$$;

-- 3. Rentals: a demo owner makes the booking simulated.
do $$
declare
  v_vehicle uuid;
  v_area uuid := (select service_area_id from public.barangays
                   where name = 'San Isidro');
  v_rental uuid;
begin
  insert into public.vehicles (
    owner_profile_id, service_area_id, name, vehicle_type, category,
    plate_number, price_per_day_centavos, status
  ) values (
    'f0000000-0000-0000-0000-000000000002', v_area, 'Attribution Bike',
    'motorcycle', '2-Wheel', 'ATTR-001', 80000, 'active'
  ) returning id into v_vehicle;

  insert into public.rental_bookings (
    renter_id, owner_id, vehicle_id, service_area_id, status,
    start_at, end_at, total_fare_centavos
  ) values (
    'f0000000-0000-0000-0000-000000000003',
    'f0000000-0000-0000-0000-000000000002',
    v_vehicle, v_area, 'requested', now() + interval '1 day',
    now() + interval '2 days', 80000
  ) returning id into v_rental;

  perform public.test_assert(
    (select is_simulated from public.rental_bookings where id = v_rental),
    'a rental with a demo owner is simulated'
  );
end;
$$;

-- 4. Pasuyo: demo customer and later demo provider both attribute.
do $$
declare
  v_area uuid := (select service_area_id from public.barangays
                   where name = 'San Isidro');
  v_barangay uuid := (select id from public.barangays
                       where name = 'San Isidro');
  v_demo_request uuid;
  v_real_request uuid;
begin
  insert into public.service_requests (
    customer_id, service_area_id, category, status, title,
    pickup_address, pickup_barangay_id
  ) values (
    'f0000000-0000-0000-0000-000000000001', v_area, 'groceries',
    'available', 'Demo errand', 'Demo pickup', v_barangay
  ) returning id into v_demo_request;

  perform public.test_assert(
    (select is_simulated from public.service_requests
      where id = v_demo_request),
    'a demo customer errand is simulated'
  );

  insert into public.service_requests (
    customer_id, service_area_id, category, status, title,
    pickup_address, pickup_barangay_id
  ) values (
    'f0000000-0000-0000-0000-000000000003', v_area, 'parcel',
    'available', 'Real errand', 'Real pickup', v_barangay
  ) returning id into v_real_request;

  perform public.test_assert(
    not (select is_simulated from public.service_requests
          where id = v_real_request),
    'a real customer errand stays actual'
  );

  update public.service_requests
     set provider_id = 'f0000000-0000-0000-0000-000000000002',
         status = 'accepted', accepted_at = now()
   where id = v_real_request;

  perform public.test_assert(
    (select is_simulated from public.service_requests
      where id = v_real_request),
    'accepting with a demo helper marks the errand simulated'
  );
end;
$$;

-- 5. Events, notifications, ratings, settlements and wallet rows.
do $$
declare
  v_area uuid := (select service_area_id from public.barangays
                   where name = 'San Isidro');
  v_barangay uuid := (select id from public.barangays
                       where name = 'San Isidro');
  v_ride uuid;
  v_event uuid;
  v_rating uuid;
  v_notification uuid;
  v_tx uuid;
  v_demo_wallet uuid;
  v_real_wallet uuid;
  v_wallet_tx uuid;
begin
  insert into public.ride_requests (
    passenger_id, rider_id, service_area_id, status,
    pickup_address, pickup_barangay_id, dropoff_address
  ) values (
    'f0000000-0000-0000-0000-000000000003',
    'f0000000-0000-0000-0000-000000000004',
    v_area, 'searching', 'Event pickup', v_barangay, 'Event dropoff'
  ) returning id into v_ride;

  insert into public.ride_status_events (ride_id, status, actor_profile_id)
  values (v_ride, 'searching', 'f0000000-0000-0000-0000-000000000001')
  returning id into v_event;

  perform public.test_assert(
    (select is_simulated from public.ride_status_events where id = v_event),
    'a demo actor status event is simulated'
  );

  insert into public.ride_ratings (ride_id, rater_id, ratee_id, stars)
  values (v_ride, 'f0000000-0000-0000-0000-000000000001',
          'f0000000-0000-0000-0000-000000000004', 5)
  returning id into v_rating;

  perform public.test_assert(
    (select is_simulated from public.ride_ratings where id = v_rating),
    'a demo rater rating is simulated'
  );

  insert into public.notifications (profile_id, notification_type, title, body)
  values ('f0000000-0000-0000-0000-000000000002', 'system',
          'Demo notice', 'Body')
  returning id into v_notification;

  perform public.test_assert(
    (select is_simulated from public.notifications
      where id = v_notification),
    'a notification for a demo account is simulated'
  );

  insert into public.service_transactions (
    service_type, ride_id, customer_id, provider_id,
    fare_centavos, platform_fee_centavos, customer_pays_centavos,
    provider_payout_centavos, platform_revenue_centavos, status, settled_at
  ) values (
    'ride', v_ride,
    'f0000000-0000-0000-0000-000000000003',
    'f0000000-0000-0000-0000-000000000002',
    5000, 1000, 6000, 5000, 1000, 'completed', now()
  ) returning id into v_tx;

  perform public.test_assert(
    (select is_simulated from public.service_transactions where id = v_tx),
    'a settlement paid to a demo provider is simulated'
  );

  insert into public.wallet_accounts (profile_id, account_type)
  values ('f0000000-0000-0000-0000-000000000001', 'passenger')
  returning id into v_demo_wallet;

  insert into public.wallet_accounts (profile_id, account_type)
  values ('f0000000-0000-0000-0000-000000000003', 'passenger')
  returning id into v_real_wallet;

  insert into public.wallet_transactions (
    wallet_account_id, transaction_type, direction, amount_centavos,
    balance_after_centavos
  ) values (
    v_demo_wallet, 'adjustment', 'credit', 10000, 10000
  ) returning id into v_wallet_tx;

  perform public.test_assert(
    (select is_simulated from public.wallet_transactions
      where id = v_wallet_tx),
    'a ledger row on a demo wallet is simulated'
  );

  insert into public.wallet_transactions (
    wallet_account_id, transaction_type, direction, amount_centavos,
    balance_after_centavos
  ) values (
    v_real_wallet, 'adjustment', 'credit', 10000, 10000
  ) returning id into v_wallet_tx;

  perform public.test_assert(
    not (select is_simulated from public.wallet_transactions
          where id = v_wallet_tx),
    'a ledger row on a real wallet stays actual'
  );
end;
$$;

rollback;
