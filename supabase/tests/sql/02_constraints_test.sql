begin;

-- Auth trigger: profile + approved passenger role.
insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com',
   '+639170000001', '{"full_name":"Alice Passenger"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com',
   '+639170000002', '{"full_name":"Bob Rider"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'carol@example.com',
   '+639170000003', '{}'::jsonb),
  ('44444444-4444-4444-4444-444444444444', 'dave@example.com',
   '+639170000004',
   '{"given_name":"Dave","family_name":"Owner"}'::jsonb);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.profiles) = 4,
    'auth trigger must create one profile per user'
  );
  perform public.test_assert(
    (select full_name from public.profiles
      where id = '33333333-3333-3333-3333-333333333333') = 'carol',
    'profile name should fall back to the email local part'
  );
  perform public.test_assert(
    (select full_name from public.profiles
      where id = '44444444-4444-4444-4444-444444444444') = 'Dave Owner',
    'profile name should combine given_name and family_name'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles
      where role = 'passenger' and status = 'approved') = 4,
    'every new user must get an approved passenger role'
  );
end;
$$;

-- Duplicate role is rejected.
do $$
begin
  begin
    insert into public.user_roles (profile_id, role, status, approved_at)
    values ('11111111-1111-1111-1111-111111111111', 'passenger',
      'approved', now());
    raise exception 'expected duplicate role rejection';
  exception when unique_violation then null;
  end;
end;
$$;

-- An approved role must carry a timestamp.
do $$
begin
  begin
    insert into public.user_roles (profile_id, role, status)
    values ('11111111-1111-1111-1111-111111111111', 'rider', 'approved');
    raise exception 'expected approved_at check rejection';
  exception when check_violation then null;
  end;
end;
$$;

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('22222222-2222-2222-2222-222222222222', 'rider', 'approved', now()),
  ('44444444-4444-4444-4444-444444444444', 'vehicle_owner', 'approved', now());

-- Provider capabilities.
do $$
begin
  begin
    insert into public.provider_profiles (profile_id, provider_type)
    values ('22222222-2222-2222-2222-222222222222', 'earner');
    raise exception 'expected empty earner capabilities rejection';
  exception when check_violation then null;
  end;

  insert into public.provider_profiles
    (profile_id, provider_type, service_area_id, capabilities)
  values (
    '22222222-2222-2222-2222-222222222222', 'earner',
    (select id from public.service_areas where city = 'Tandag City'), array['rides']::public.earner_capability[]
  );
end;
$$;

-- Geography references.
do $$
declare
  v_area uuid := (select id from public.service_areas where city = 'Tandag City');
  v_brgy uuid := (select id from public.barangays where name = 'Awasian');
  v_purok uuid := (
    select p.id from public.puroks p
     where p.barangay_id = v_brgy and p.name = 'Purok 1'
  );
  v_brgy2 uuid := (select id from public.barangays where name = 'Bioto');
  v_other_area uuid := '99999999-9999-9999-9999-999999999999';
  v_other_brgy uuid := '88888888-8888-8888-8888-888888888888';
begin
  insert into public.service_areas
    (id, name, city, province, center_latitude, center_longitude)
  values (v_other_area, 'Other', 'Other City', 'Other Province', 1, 1);

  insert into public.barangays (id, service_area_id, name)
  values (v_other_brgy, v_other_area, 'Other Barangay');

  -- Barangay outside the ride's service area.
  begin
    insert into public.ride_requests (
      passenger_id, service_area_id, pickup_address, pickup_barangay_id,
      dropoff_address, fare_centavos
    ) values (
      '11111111-1111-1111-1111-111111111111', v_area, 'Pickup',
      v_other_brgy, 'Dropoff', 10000
    );
    raise exception 'expected cross-service-area barangay rejection';
  exception when foreign_key_violation then null;
  end;

  -- Purok must belong to the chosen barangay.
  begin
    insert into public.ride_requests (
      passenger_id, service_area_id, pickup_address, pickup_barangay_id,
      pickup_purok_id, dropoff_address, fare_centavos
    ) values (
      '11111111-1111-1111-1111-111111111111', v_area, 'Pickup', v_brgy,
      (select p.id from public.puroks p where p.barangay_id = v_brgy2 limit 1),
      'Dropoff', 10000
    );
    raise exception 'expected purok/barangay mismatch rejection';
  exception when foreign_key_violation then null;
  end;

  -- Money cannot be negative.
  begin
    insert into public.ride_requests (
      passenger_id, service_area_id, pickup_address, pickup_barangay_id,
      dropoff_address, fare_centavos
    ) values (
      '11111111-1111-1111-1111-111111111111', v_area, 'Pickup', v_brgy,
      'Dropoff', -1
    );
    raise exception 'expected negative fare rejection';
  exception when check_violation then null;
  end;

  -- Unknown status values are rejected by the enum.
  begin
    insert into public.ride_requests (
      passenger_id, service_area_id, status, pickup_address,
      pickup_barangay_id, dropoff_address, fare_centavos
    ) values (
      '11111111-1111-1111-1111-111111111111', v_area, 'done',
      'Pickup', v_brgy, 'Dropoff', 10000
    );
    raise exception 'expected invalid ride status rejection';
  exception when invalid_text_representation then null;
  end;

  -- Completed rides need timestamps.
  begin
    insert into public.ride_requests (
      passenger_id, rider_id, service_area_id, status, pickup_address,
      pickup_barangay_id, dropoff_address, fare_centavos
    ) values (
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222', v_area, 'completed',
      'Pickup', v_brgy, 'Dropoff', 10000
    );
    raise exception 'expected completed timestamp rejection';
  exception when check_violation then null;
  end;

  -- Passenger and rider must be different people.
  begin
    insert into public.ride_requests (
      passenger_id, rider_id, service_area_id, status, pickup_address,
      pickup_barangay_id, dropoff_address, fare_centavos, accepted_at
    ) values (
      '11111111-1111-1111-1111-111111111111',
      '11111111-1111-1111-1111-111111111111', v_area, 'accepted',
      'Pickup', v_brgy, 'Dropoff', 10000, now()
    );
    raise exception 'expected self-ride rejection';
  exception when check_violation then null;
  end;
end;
$$;

-- Working rides.
insert into public.ride_requests (
  id, passenger_id, rider_id, service_area_id, status, pickup_address,
  pickup_barangay_id, pickup_purok_id, dropoff_address, dropoff_barangay_id,
  dropoff_purok_id, distance_km, eta_minutes, fare_centavos,
  platform_fee_centavos, accepted_at, started_at, completed_at
) values (
  'aaaaaaaa-0000-0000-0000-000000000001',
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  (select id from public.service_areas where city = 'Tandag City'), 'completed', 'Awasian Purok 1',
  (select id from public.barangays where name = 'Awasian'),
  (select p.id from public.puroks p
    join public.barangays b on b.id = p.barangay_id
   where b.name = 'Awasian' and p.name = 'Purok 1'),
  'Bioto Purok 1',
  (select id from public.barangays where name = 'Bioto'),
  (select p.id from public.puroks p
    join public.barangays b on b.id = p.barangay_id
   where b.name = 'Bioto' and p.name = 'Purok 1'),
  5.5, 12, 15000, 2000, now() - interval '30 minutes',
  now() - interval '25 minutes', now() - interval '5 minutes'
);

insert into public.ride_requests (
  id, passenger_id, service_area_id, status, pickup_address,
  pickup_barangay_id, dropoff_address, fare_centavos
) values (
  'aaaaaaaa-0000-0000-0000-000000000002',
  '33333333-3333-3333-3333-333333333333',
  (select id from public.service_areas where city = 'Tandag City'), 'searching', 'Mabua Purok 1',
  (select id from public.barangays where name = 'Mabua'), 'Telaje Purok 1', 12000
);

-- Ratings.
do $$
begin
  begin
    insert into public.ride_ratings (ride_id, rater_id, ratee_id, stars)
    values (
      'aaaaaaaa-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222', 6
    );
    raise exception 'expected star range rejection';
  exception when check_violation then null;
  end;

  insert into public.ride_ratings (ride_id, rater_id, ratee_id, stars)
  values (
    'aaaaaaaa-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222', 5
  );

  begin
    insert into public.ride_ratings (ride_id, rater_id, ratee_id, stars)
    values (
      'aaaaaaaa-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222', 4
    );
    raise exception 'expected duplicate ride rating rejection';
  exception when unique_violation then null;
  end;
end;
$$;

-- Vehicles and rentals.
insert into public.vehicles (
  id, owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, price_per_day_centavos, status
) values (
  'bbbbbbbb-0000-0000-0000-000000000001',
  '44444444-4444-4444-4444-444444444444',
  (select id from public.service_areas where city = 'Tandag City'), 'Honda Click', 'motorcycle',
  '2-Wheel', 'ABC 1234', 50000, 'active'
);

do $$
declare
  v_area uuid := (select id from public.service_areas where city = 'Tandag City');
  v_vehicle uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  v_start timestamptz := now() + interval '1 day';
begin
  begin
    insert into public.rental_bookings (
      renter_id, owner_id, vehicle_id, service_area_id, start_at, end_at,
      total_fare_centavos
    ) values (
      '22222222-2222-2222-2222-222222222222',
      '33333333-3333-3333-3333-333333333333',
      v_vehicle, v_area, v_start, v_start + interval '1 day', 50000
    );
    raise exception 'expected owner/vehicle mismatch rejection';
  exception when foreign_key_violation then null;
  end;

  begin
    insert into public.rental_bookings (
      renter_id, owner_id, vehicle_id, service_area_id, start_at, end_at,
      total_fare_centavos
    ) values (
      '22222222-2222-2222-2222-222222222222',
      '44444444-4444-4444-4444-444444444444',
      v_vehicle, v_area, v_start, v_start - interval '1 hour', 50000
    );
    raise exception 'expected inverted rental window rejection';
  exception when check_violation then null;
  end;

  begin
    insert into public.rental_bookings (
      renter_id, owner_id, vehicle_id, service_area_id, status, start_at, end_at,
      total_fare_centavos
    ) values (
      '22222222-2222-2222-2222-222222222222',
      '44444444-4444-4444-4444-444444444444',
      v_vehicle, v_area, 'completed', v_start, v_start + interval '1 day', 50000
    );
    raise exception 'expected completed rental timestamp rejection';
  exception when check_violation then null;
  end;

  insert into public.rental_bookings (
    id, renter_id, owner_id, vehicle_id, service_area_id, status, start_at,
    end_at, total_fare_centavos, platform_fee_centavos, accepted_at,
    started_at, returned_at, completed_at
  ) values (
    'cccccccc-0000-0000-0000-000000000001',
    '22222222-2222-2222-2222-222222222222',
    '44444444-4444-4444-4444-444444444444',
    v_vehicle, v_area, 'completed', v_start, v_start + interval '1 day',
    50000, 5000, now(), now(), now(), now()
  );
end;
$$;

-- Pasuyo requests.
do $$
declare
  v_area uuid := (select id from public.service_areas where city = 'Tandag City');
  v_brgy uuid := (select id from public.barangays where name = 'Mabuhay');
  v_purok uuid := (
    select p.id from public.puroks p
     where p.barangay_id = v_brgy and p.name = 'Purok 1'
  );
begin
  begin
    insert into public.service_requests (
      customer_id, service_area_id, category, title, pickup_address,
      pickup_barangay_id, pickup_purok_id, quoted_fee_centavos
    ) values (
      '11111111-1111-1111-1111-111111111111', v_area, 'groceries',
      'Buy rice', 'Mabuhay Purok 1', v_brgy, v_purok, -1
    );
    raise exception 'expected negative pasuyo fee rejection';
  exception when check_violation then null;
  end;

  insert into public.service_requests (
    id, customer_id, provider_id, service_area_id, category, status, title,
    pickup_address, pickup_barangay_id, pickup_purok_id, quoted_fee_centavos,
    platform_fee_centavos, accepted_at, picked_up_at, delivered_at
  ) values (
    'dddddddd-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    v_area, 'groceries', 'delivered', 'Buy rice', 'Mabuhay Purok 1',
    v_brgy, v_purok, 10000, 1500, now(), now(), now()
  );

  insert into public.service_request_items (
    service_request_id, name, quantity, unit, estimated_unit_price_centavos
  ) values (
    'dddddddd-0000-0000-0000-000000000001', 'Rice', 2, 'sack', 5000
  );

  begin
    insert into public.service_request_items (
      service_request_id, name, quantity
    ) values (
      'dddddddd-0000-0000-0000-000000000001', 'Zero', 0
    );
    raise exception 'expected zero quantity rejection';
  exception when check_violation then null;
  end;
end;
$$;

-- Settlement invariants.
do $$
begin
  begin
    insert into public.service_transactions (
      service_type, ride_id, customer_id, provider_id, fare_centavos,
      platform_fee_centavos, customer_pays_centavos,
      provider_payout_centavos, platform_revenue_centavos
    ) values (
      'ride', 'aaaaaaaa-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222',
      15000, 2000, 18000, 15000, 2000
    );
    raise exception 'expected customer total mismatch rejection';
  exception when check_violation then null;
  end;

  begin
    insert into public.service_transactions (
      service_type, rental_id, customer_id, provider_id, fare_centavos,
      platform_fee_centavos, customer_pays_centavos,
      provider_payout_centavos, platform_revenue_centavos
    ) values (
      'rental', 'cccccccc-0000-0000-0000-000000000001',
      '22222222-2222-2222-2222-222222222222',
      '44444444-4444-4444-4444-444444444444',
      50000, 5000, 55000, 51000, 4000
    );
    raise exception 'expected payout-over-fare rejection';
  exception when check_violation then null;
  end;

  begin
    insert into public.service_transactions (
      service_type, ride_id, service_request_id, customer_id, provider_id,
      fare_centavos, platform_fee_centavos, customer_pays_centavos,
      provider_payout_centavos, platform_revenue_centavos
    ) values (
      'ride', 'aaaaaaaa-0000-0000-0000-000000000001',
      'dddddddd-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222',
      15000, 2000, 17000, 15000, 2000
    );
    raise exception 'expected multi-service settlement rejection';
  exception when check_violation then null;
  end;

  insert into public.service_transactions (
    id, service_type, ride_id, customer_id, provider_id, fare_centavos,
    platform_fee_centavos, customer_pays_centavos, provider_payout_centavos,
    platform_revenue_centavos, status, settled_at
  ) values (
    'eeeeeeee-0000-0000-0000-000000000001', 'ride',
    'aaaaaaaa-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    15000, 2000, 17000, 15000, 2000, 'completed', now()
  );

  begin
    insert into public.service_transactions (
      service_type, ride_id, customer_id, provider_id, fare_centavos,
      platform_fee_centavos, customer_pays_centavos,
      provider_payout_centavos, platform_revenue_centavos
    ) values (
      'ride', 'aaaaaaaa-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222',
      15000, 2000, 17000, 15000, 2000
    );
    raise exception 'expected double-settlement rejection';
  exception when unique_violation then null;
  end;
end;
$$;

-- Wallet ledger.
do $$
declare
  v_alice_wallet uuid := 'ffffffff-0000-0000-0000-000000000001';
begin
  insert into public.wallet_accounts
    (id, profile_id, account_type, balance_centavos)
  values (
    'ffffffff-0000-0000-0000-000000000000', null, 'platform', 0
  );

  insert into public.wallet_accounts
    (id, profile_id, account_type, balance_centavos)
  values (
    v_alice_wallet, '11111111-1111-1111-1111-111111111111',
    'passenger', 10000
  );

  begin
    insert into public.wallet_accounts (profile_id, account_type)
    values ('11111111-1111-1111-1111-111111111111', 'passenger');
    raise exception 'expected duplicate wallet account rejection';
  exception when unique_violation then null;
  end;

  begin
    insert into public.wallet_accounts (profile_id, account_type, balance_centavos)
    values ('11111111-1111-1111-1111-111111111111', 'earner', -1);
    raise exception 'expected negative wallet balance rejection';
  exception when check_violation then null;
  end;

  insert into public.wallet_transactions (
    wallet_account_id, transaction_type, direction, amount_centavos,
    balance_after_centavos, service_transaction_id, description
  ) values (
    v_alice_wallet, 'top_up', 'credit', 10000, 10000,
    null, 'Initial top-up'
  );

  begin
    insert into public.wallet_transactions (
      wallet_account_id, transaction_type, direction, amount_centavos,
      balance_after_centavos
    ) values (v_alice_wallet, 'adjustment', 'credit', 0, 10000);
    raise exception 'expected zero wallet movement rejection';
  exception when check_violation then null;
  end;

  begin
    insert into public.wallet_transactions (
      wallet_account_id, transaction_type, direction, amount_centavos,
      balance_after_centavos
    ) values (v_alice_wallet, 'payout', 'debit', 100, -1);
    raise exception 'expected negative balance-after rejection';
  exception when check_violation then null;
  end;
end;
$$;

-- Cash platform-fee remittances (provider owes the platform fee in cash).
do $$
begin
  insert into public.cash_fee_remittances (
    provider_id, service_transaction_id, amount_centavos, due_at
  ) values (
    '22222222-2222-2222-2222-222222222222',
    'eeeeeeee-0000-0000-0000-000000000001', 2000, now() + interval '1 day'
  );

  begin
    insert into public.cash_fee_remittances (
      provider_id, service_transaction_id, amount_centavos, due_at
    ) values (
      '22222222-2222-2222-2222-222222222222',
      'eeeeeeee-0000-0000-0000-000000000001', 3000, now() + interval '1 day'
    );
    raise exception 'expected duplicate remittance rejection';
  exception when unique_violation then null;
  end;

  begin
    insert into public.cash_fee_remittances (
      provider_id, amount_centavos, due_at
    ) values (
      '22222222-2222-2222-2222-222222222222', 0, now() + interval '1 day'
    );
    raise exception 'expected zero remittance rejection';
  exception when check_violation then null;
  end;
end;
$$;

-- Pricing policies: configurable, but activation requires approval.
do $$
begin
  insert into public.pricing_policies (name, service_type)
  values ('Draft ride policy', 'ride');

  begin
    update public.pricing_policies set is_active = true
     where name = 'Draft ride policy';
    raise exception 'expected unapproved policy activation rejection';
  exception when check_violation then null;
  end;

  update public.pricing_policies
     set approved_at = now(), effective_from = now(), is_active = true
   where name = 'Draft ride policy';

  perform public.test_assert(
    (select count(*) from public.pricing_policies where is_active) = 1,
    'approved policy should be active'
  );

  begin
    insert into public.pricing_policies (
      name, service_type, approved_at, effective_from, is_active
    ) values ('Second active ride policy', 'ride', now(), now(), true);
    raise exception 'expected single-active-policy rejection';
  exception when unique_violation then null;
  end;

  insert into public.pricing_policies (
    name, service_type, approved_at, effective_from, is_active
  ) values ('Active rental policy', 'rental', now(), now(), true);
end;
$$;

-- Verification workflow.
do $$
begin
  insert into public.verification_applications (profile_id, capability_type)
  values ('22222222-2222-2222-2222-222222222222', 'rider');

  begin
    insert into public.verification_applications (profile_id, capability_type)
    values ('22222222-2222-2222-2222-222222222222', 'rider');
    raise exception 'expected duplicate open application rejection';
  exception when unique_violation then null;
  end;

  -- A decided application does not block a fresh open one.
  insert into public.verification_applications (
    profile_id, capability_type, status, submitted_at, decided_at
  ) values (
    '22222222-2222-2222-2222-222222222222', 'vehicle_owner',
    'approved', now(), now()
  );

  insert into public.verification_applications (profile_id, capability_type)
  values ('22222222-2222-2222-2222-222222222222', 'vehicle_owner');

  begin
    insert into public.verification_applications (
      profile_id, capability_type, status, submitted_at
    ) values (
      '22222222-2222-2222-2222-222222222222', 'earner', 'approved', now()
    );
    raise exception 'expected missing decision timestamp rejection';
  exception when check_violation then null;
  end;
end;
$$;

-- Vehicle documents require a review timestamp once decided.
do $$
begin
  begin
    insert into public.vehicle_documents (
      vehicle_id, document_type, status
    ) values (
      'bbbbbbbb-0000-0000-0000-000000000001', 'registration', 'approved'
    );
    raise exception 'expected missing document review timestamp rejection';
  exception when check_violation then null;
  end;

  insert into public.vehicle_documents (
    vehicle_id, document_type, document_number, status, reviewed_at
  ) values (
    'bbbbbbbb-0000-0000-0000-000000000001', 'registration',
    'REG-001', 'approved', now()
  );
end;
$$;

-- GPS breadcrumbs.
do $$
begin
  begin
    insert into public.ride_locations (ride_id, latitude, longitude, heading_degrees)
    values (
      'aaaaaaaa-0000-0000-0000-000000000001', 9.0785, 126.1985, 361
    );
    raise exception 'expected heading range rejection';
  exception when check_violation then null;
  end;

  insert into public.ride_locations (ride_id, latitude, longitude, heading_degrees)
  values (
    'aaaaaaaa-0000-0000-0000-000000000001', 9.0785, 126.1985, 90
  );
end;
$$;

-- Auth updates flow back to profiles.
update auth.users
   set email = 'alice.updated@example.com',
       phone = '+639170000099',
       raw_user_meta_data = '{"full_name":"Alice Updated"}'::jsonb
 where id = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.test_assert(
    (select email from public.profiles
      where id = '11111111-1111-1111-1111-111111111111') = 'alice.updated@example.com',
    'auth email update must sync to profiles'
  );
  perform public.test_assert(
    (select full_name from public.profiles
      where id = '11111111-1111-1111-1111-111111111111') = 'Alice Updated',
    'auth name update must sync to profiles'
  );

  -- Duplicate phone is rejected through the profile unique index.
  begin
    update auth.users set phone = '+639170000002'
     where id = '11111111-1111-1111-1111-111111111111';
    raise exception 'expected duplicate phone rejection';
  exception when unique_violation then null;
  end;
end;
$$;

rollback;
