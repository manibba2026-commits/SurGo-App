begin;

-- Fixtures created as the database owner (bypasses RLS).
insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com',
   '+639170000001', '{"full_name":"Alice"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com',
   '+639170000002', '{"full_name":"Bob"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'carol@example.com',
   '+639170000003', '{"full_name":"Carol"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at)
values (
  '22222222-2222-2222-2222-222222222222', 'rider', 'approved', now()
);

insert into public.ride_requests (
  id, passenger_id, rider_id, service_area_id, status, pickup_address,
  pickup_barangay_id, dropoff_address, fare_centavos, accepted_at,
  started_at, completed_at
) values (
  'aaaaaaaa-0000-0000-0000-000000000001',
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  (select id from public.service_areas), 'completed', 'Awasian',
  (select id from public.barangays where name = 'Awasian'), 'Bioto',
  15000, now(), now(), now()
);

insert into public.ride_requests (
  id, passenger_id, service_area_id, status, pickup_address,
  pickup_barangay_id, dropoff_address, fare_centavos
) values (
  'aaaaaaaa-0000-0000-0000-000000000002',
  '33333333-3333-3333-3333-333333333333',
  (select id from public.service_areas), 'searching', 'Mabua',
  (select id from public.barangays where name = 'Mabua'), 'Telaje', 12000
);

insert into public.service_transactions (
  service_type, ride_id, customer_id, provider_id, fare_centavos,
  platform_fee_centavos, customer_pays_centavos, provider_payout_centavos,
  platform_revenue_centavos, status, settled_at
) values (
  'ride', 'aaaaaaaa-0000-0000-0000-000000000001',
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  15000, 2000, 17000, 15000, 2000, 'completed', now()
);

insert into public.wallet_accounts (id, profile_id, account_type, balance_centavos)
values
  ('ffffffff-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'passenger', 10000),
  ('ffffffff-0000-0000-0000-000000000002',
   '33333333-3333-3333-3333-333333333333', 'passenger', 5000);

insert into public.wallet_transactions (
  wallet_account_id, transaction_type, direction, amount_centavos,
  balance_after_centavos
) values
  ('ffffffff-0000-0000-0000-000000000001', 'top_up', 'credit', 10000, 10000),
  ('ffffffff-0000-0000-0000-000000000002', 'top_up', 'credit', 5000, 5000);

insert into public.pricing_policies (name, service_type)
values ('Inactive ride policy', 'ride');

insert into public.pricing_policies (
  name, service_type, approved_at, effective_from, is_active
) values ('Active ride policy', 'ride', now(), now(), true);

insert into public.vehicles (
  owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, status
) values
  ('11111111-1111-1111-1111-111111111111',
   (select id from public.service_areas), 'Active Bike', 'motorcycle',
   '2-Wheel', 'ACT 111', 'active'),
  ('33333333-3333-3333-3333-333333333333',
   (select id from public.service_areas), 'Inactive Bike', 'motorcycle',
   '2-Wheel', 'INA 222', 'inactive');

insert into public.notifications (profile_id, notification_type, title, body)
values
  ('11111111-1111-1111-1111-111111111111', 'ride', 'Ride done', 'Alice only'),
  ('33333333-3333-3333-3333-333333333333', 'ride', 'Ride done', 'Carol only');

insert into public.admin_audit_logs (action, entity_type)
values ('seed', 'test');

-- Alice's view.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.profiles) = 1,
    'a user must only see their own profile'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles) = 1,
    'a user must only see their own roles'
  );
  perform public.test_assert(
    (select count(*) from public.ride_requests) = 1,
    'Alice must only see her own ride'
  );
  perform public.test_assert(
    not public.can_access_ride('aaaaaaaa-0000-0000-0000-000000000002'),
    'Alice must not see Carol''s open ride'
  );
  perform public.test_assert(
    (select count(*) from public.service_areas) = 1,
    'catalog must be readable by signed-in users'
  );
  perform public.test_assert(
    (select count(*) from public.pricing_policies) = 1,
    'only the active pricing policy may be visible'
  );
  perform public.test_assert(
    (select name from public.pricing_policies) = 'Active ride policy',
    'the hidden policy must be the inactive one'
  );
  perform public.test_assert(
    (select count(*) from public.wallet_accounts) = 1,
    'a user must only see their own wallet'
  );
  perform public.test_assert(
    (select count(*) from public.wallet_transactions) = 1,
    'a user must only see their own wallet ledger'
  );
  perform public.test_assert(
    (select count(*) from public.notifications) = 1,
    'a user must only see their own notifications'
  );
  perform public.test_assert(
    (select count(*) from public.vehicles) = 1,
    'a user sees active listings plus their own vehicles'
  );
  perform public.test_assert(
    (select count(*) from public.service_transactions) = 1,
    'a customer must see their settlement'
  );
  begin
    perform 1 from public.admin_audit_logs limit 1;
    raise exception 'audit logs must not be readable by app users';
  exception when insufficient_privilege then null;
  end;
end;
$$;

do $$
begin
  begin
    insert into public.profiles (id, full_name)
    values ('99999999-9999-9999-9999-999999999999', 'Intruder');
    raise exception 'expected insert denial';
  exception when insufficient_privilege then null;
  end;

  -- Writes are denied at the grant level before RLS is even consulted.
  begin
    update public.profiles set full_name = 'Hacked'
     where id = '11111111-1111-1111-1111-111111111111';
    raise exception 'expected profile update denial';
  exception when insufficient_privilege then null;
  end;

  begin
    delete from public.notifications;
    raise exception 'expected notification delete denial';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- Bob is an approved rider: he sees his own ride and the open pool.
select set_config(
  'request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.ride_requests) = 2,
    'an approved rider must see their ride plus open search rides'
  );
  perform public.test_assert(
    public.can_access_ride('aaaaaaaa-0000-0000-0000-000000000002'),
    'an approved rider must access the open ride'
  );
  perform public.test_assert(
    (select count(*) from public.service_transactions) = 1,
    'a provider must see their settlement'
  );
  perform public.test_assert(
    (select count(*) from public.profiles) = 1,
    'a provider still only sees their own profile'
  );
end;
$$;

-- Carol is not a rider.
select set_config(
  'request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.ride_requests) = 1,
    'a passenger must only see their own ride'
  );
  perform public.test_assert(
    not public.can_access_ride('aaaaaaaa-0000-0000-0000-000000000001'),
    'Carol must not see Alice''s ride'
  );
  perform public.test_assert(
    public.can_access_ride('aaaaaaaa-0000-0000-0000-000000000002'),
    'Carol must see her own open ride'
  );
  perform public.test_assert(
    (select count(*) from public.service_transactions) = 0,
    'Carol must not see someone else''s settlement'
  );
end;
$$;

reset role;

rollback;
