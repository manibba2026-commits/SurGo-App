begin;

-- Rider presence, discovery and the dispatch lifecycle.
--
-- These fixtures cover the rules the app depends on:
--   * an approved rider role OR an approved earner with the rides capability is
--     a ride provider (the seeded demo fleet uses the latter, with rider:pending);
--   * only online, available, active providers are discovered;
--   * assignment holds the rider, acceptance hides availability, decline and
--     cancellation release it, and completion restores it;
--   * clients have SELECT only on rider_presence and no write grants.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('e0000000-0000-0000-0000-000000000001', 'passenger.dispatch@example.com',
   '+639170001001', '{"full_name":"Dispatch Passenger"}'::jsonb),
  ('e0000000-0000-0000-0000-000000000002', 'rider.one@example.com',
   '+639170001002', '{"full_name":"Dispatch Rider One"}'::jsonb),
  ('e0000000-0000-0000-0000-000000000003', 'rider.two@example.com',
   '+639170001003', '{"full_name":"Dispatch Rider Two"}'::jsonb),
  ('e0000000-0000-0000-0000-000000000004', 'suspended.rider@example.com',
   '+639170001004', '{"full_name":"Suspended Rider"}'::jsonb),
  ('e0000000-0000-0000-0000-000000000005', 'pending.rider@example.com',
   '+639170001005', '{"full_name":"Pending Earner"}'::jsonb),
  ('e0000000-0000-0000-0000-000000000006', 'unapproved@example.com',
   '+639170001006', '{"full_name":"Unapproved Account"}'::jsonb);

update public.profiles
   set account_status = 'suspended'
 where id = 'e0000000-0000-0000-0000-000000000004';

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('e0000000-0000-0000-0000-000000000002', 'rider', 'approved', now()),
  ('e0000000-0000-0000-0000-000000000003', 'earner', 'approved', now()),
  ('e0000000-0000-0000-0000-000000000004', 'rider', 'approved', now()),
  ('e0000000-0000-0000-0000-000000000005', 'earner', 'approved', now()),
  ('e0000000-0000-0000-0000-000000000005', 'rider', 'pending', null);

insert into public.provider_profiles (
  profile_id, provider_type, service_area_id, display_name, capabilities,
  rating, total_trips
) values
  ('e0000000-0000-0000-0000-000000000003', 'earner',
   (select id from public.service_areas), 'Dispatch Rider Two',
   array['rides']::public.earner_capability[], 4.80, 12),
  ('e0000000-0000-0000-0000-000000000004', 'earner',
   (select id from public.service_areas), 'Suspended Rider',
   array['rides']::public.earner_capability[], 4.50, 5),
  ('e0000000-0000-0000-0000-000000000005', 'earner',
   (select id from public.service_areas), 'Pending Earner',
   array['rides']::public.earner_capability[], 4.90, 20);

insert into public.rider_presence (
  profile_id, is_online, is_available, latitude, longitude, heading_degrees,
  barangay_id, vehicle_type, vehicle_label, vehicle_plate, is_simulated, source
) values
  ('e0000000-0000-0000-0000-000000000002', true, true, 9.0705, 126.1945, 0,
   (select id from public.barangays where name = 'San Isidro'),
   'motorcycle', 'Honda Click', 'DSP 001', true, 'demo'),
  ('e0000000-0000-0000-0000-000000000003', false, false, 9.0785, 126.2025, 90,
   (select id from public.barangays where name = 'Bagong Lungsod (Poblacion)'),
   'tricycle', 'Bajaj RE', 'DSP 002', true, 'demo'),
  ('e0000000-0000-0000-0000-000000000004', true, true, 9.0805, 126.1945, 180,
   (select id from public.barangays where name = 'Dagocdoc (Poblacion)'),
   'motorcycle', 'Yamaha Mio', 'DSP 003', true, 'demo'),
  ('e0000000-0000-0000-0000-000000000005', true, true, 9.0825, 126.1985, 45,
   (select id from public.barangays where name = 'Awasian'),
   'motorcycle', 'Yamaha Sniper', 'DSP 004', true, 'demo'),
  ('e0000000-0000-0000-0000-000000000006', true, true, 9.0865, 126.1905, 270,
   (select id from public.barangays where name = 'Telaje'),
   'motorcycle', 'Honda Beat', 'DSP 005', true, 'demo');

-- 1. Structural privileges.
do $$
begin
  perform public.test_assert(
    has_table_privilege('authenticated', 'public.rider_presence', 'SELECT'),
    'authenticated may read rider presence'
  );
  perform public.test_assert(
    not has_table_privilege('authenticated', 'public.rider_presence', 'INSERT')
      and not has_table_privilege('authenticated', 'public.rider_presence', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.rider_presence', 'DELETE'),
    'clients may not write rider presence directly'
  );
  perform public.test_assert(
    not has_table_privilege('anon', 'public.rider_presence', 'SELECT'),
    'anon may not read rider presence'
  );
end;
$$;

-- 2. Eligibility is the approved rider role OR approved earner with rides.
do $$
begin
  perform public.test_assert(
    public.is_approved_ride_provider('e0000000-0000-0000-0000-000000000002'),
    'an approved rider role is a ride provider'
  );
  perform public.test_assert(
    public.is_approved_ride_provider('e0000000-0000-0000-0000-000000000003'),
    'an approved earner with rides is a ride provider'
  );
  perform public.test_assert(
    public.is_approved_ride_provider('e0000000-0000-0000-0000-000000000005'),
    'a rider:pending role does not block an approved earner with rides'
  );
  perform public.test_assert(
    not public.is_approved_ride_provider('e0000000-0000-0000-0000-000000000004'),
    'a suspended account is not a ride provider'
  );
  perform public.test_assert(
    not public.is_approved_ride_provider('e0000000-0000-0000-0000-000000000006'),
    'an unapproved account is not a ride provider'
  );
end;
$$;

-- 3. Passenger discovery and presence RLS.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_rows integer;
  v_names text;
begin
  -- Online and approved only: rider one and the pending earner. Rider two is
  -- offline; the suspended and unapproved rows are not readable.
  perform public.test_assert(
    (select count(*) from public.rider_presence) = 2,
    'a passenger sees only online approved riders'
  );

  select count(*), string_agg(full_name, ',' order by full_name)
    into v_rows, v_names
    from public.find_available_riders(
      p_pickup_latitude => 9.0705,
      p_pickup_longitude => 126.1945
    );
  perform public.test_assert(
    v_rows = 2,
    'discovery returns the two online approved riders'
  );
  perform public.test_assert(
    v_names like '%Dispatch Rider One%' and v_names like '%Pending Earner%',
    'discovery returns the expected riders'
  );
  perform public.test_assert(
    v_names not like '%Suspended%' and v_names not like '%Unapproved%',
    'discovery excludes suspended and unapproved accounts'
  );
end;
$$;

-- 4. An unapproved account cannot publish presence.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000006', true
);

do $$
begin
  begin
    perform public.set_rider_presence(true);
    raise exception 'expected an unapproved account to be refused';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- 5. A rider going online reuses the last fix, and offline rows disappear.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000003', true
);

do $$
declare
  v_row public.rider_presence%rowtype;
begin
  perform public.set_rider_presence(true);
  select * into v_row
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000003';
  perform public.test_assert(v_row.is_online and v_row.is_available,
    'going online makes the rider available');
  perform public.test_assert(v_row.latitude = 9.0785 and v_row.longitude = 126.2025,
    'going online without a new fix reuses the stored position');
  perform public.test_assert(v_row.is_simulated and v_row.source = 'demo',
    'a demo rider keeps the simulated marker after flipping the switch');
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.find_available_riders()) = 3,
    'a rider who comes online joins discovery'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000003', true
);
select public.set_rider_presence(false);

select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.find_available_riders()) = 2,
    'going offline removes the rider from discovery'
  );
end;
$$;

-- 6. Create, assign, accept and complete a ride.
do $$
declare
  v_ride uuid;
  v_row public.ride_requests%rowtype;
  v_available boolean;
begin
  v_ride := (public.create_ride_request(
    p_pickup_address => 'Purok 3, San Isidro',
    p_pickup_barangay => 'Purok 3, San Isidro',
    p_pickup_purok => 'Purok 3',
    p_pickup_latitude => 9.0705,
    p_pickup_longitude => 126.1945,
    p_dropoff_address => 'SM Terminal, Bagong Lungsod',
    p_dropoff_barangay => 'SM Terminal, Bagong Lungsod',
    p_distance_km => 4.2,
    p_eta_minutes => 12,
    p_fare_centavos => 12000,
    p_platform_fee_centavos => 1200
  )->>'id')::uuid;

  select * into v_row from public.ride_requests where id = v_ride;
  perform public.test_assert(v_row.status = 'searching',
    'a new request starts searching');
  perform public.test_assert(v_row.payment_method = 'cash',
    'a new request is cash on delivery');
  perform public.test_assert(
    v_row.pickup_barangay_id =
      (select id from public.barangays where name = 'San Isidro'),
    'the pickup barangay is resolved from the label'
  );
  perform public.test_assert(
    v_row.dropoff_barangay_id =
      (select id from public.barangays
        where name = 'Bagong Lungsod (Poblacion)'),
    'the dropoff barangay is resolved from the label'
  );
  perform public.test_assert(
    (select count(*) from public.ride_status_events where ride_id = v_ride) = 1,
    'creation writes one status event'
  );

  perform public.assign_ride_request(
    v_ride, 'e0000000-0000-0000-0000-000000000002'
  );

  select * into v_row from public.ride_requests where id = v_ride;
  perform public.test_assert(v_row.status = 'awaiting_acceptance',
    'assigning moves the request to awaiting acceptance');
  perform public.test_assert(
    v_row.rider_id = 'e0000000-0000-0000-0000-000000000002',
    'assigning records the chosen rider'
  );

  select is_available into v_available
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000002';
  perform public.test_assert(not v_available,
    'assignment holds the rider and removes them from discovery');

  perform public.test_assert(
    (select count(*) from public.find_available_riders()) = 1,
    'the held rider is not discoverable'
  );
end;
$$;

-- The rider's inbox sees the request and the notification.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000002', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.ride_requests
      where rider_id = 'e0000000-0000-0000-0000-000000000002'
        and status = 'awaiting_acceptance') = 1,
    'the chosen rider sees the request'
  );
  perform public.test_assert(
    (select count(*) from public.notifications
      where profile_id = 'e0000000-0000-0000-0000-000000000002'
        and title = 'New ride request') = 1,
    'assignment notifies the rider'
  );
end;
$$;

-- A different rider cannot answer it.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000003', true
);

do $$
declare
  v_ride uuid;
begin
  select id into v_ride
    from public.ride_requests
   where status = 'awaiting_acceptance'
     and rider_id = 'e0000000-0000-0000-0000-000000000002';
  begin
    perform public.respond_to_ride_request(v_ride, true);
    raise exception 'expected a non-assigned rider to be refused';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- The assigned rider accepts, then advances the trip to completion.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_ride uuid;
  v_row public.ride_requests%rowtype;
  v_presence public.rider_presence%rowtype;
  v_trips integer;
begin
  select id into v_ride
    from public.ride_requests
   where status = 'awaiting_acceptance'
     and rider_id = 'e0000000-0000-0000-0000-000000000002';

  perform public.respond_to_ride_request(v_ride, true);

  select * into v_row from public.ride_requests where id = v_ride;
  perform public.test_assert(v_row.status = 'accepted',
    'accepting moves the request to accepted');
  perform public.test_assert(v_row.accepted_at is not null,
    'accepting records the acceptance time');

  select * into v_presence
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000002';
  perform public.test_assert(v_presence.is_online and not v_presence.is_available,
    'an accepted rider stays online but is no longer available');

  -- Toggling online while on a trip must not make them available again.
  perform public.set_rider_presence(true);
  select * into v_presence
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000002';
  perform public.test_assert(not v_presence.is_available,
    'going online during a trip does not free the rider');

  perform public.advance_ride_status(v_ride, 'heading_to_pickup');
  perform public.advance_ride_status(v_ride, 'arrived');
  perform public.advance_ride_status(v_ride, 'in_progress');
  perform public.advance_ride_status(v_ride, 'completed');

  select * into v_row from public.ride_requests where id = v_ride;
  perform public.test_assert(v_row.status = 'completed',
    'the trip reaches completed');
  perform public.test_assert(v_row.completed_at is not null,
    'completion records the completion time');

  select * into v_presence
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000002';
  perform public.test_assert(v_presence.is_available,
    'completion frees the rider again');

  select total_rides into v_trips
    from public.profiles
   where id = 'e0000000-0000-0000-0000-000000000001';
  perform public.test_assert(v_trips = 1,
    'completion increments the passenger ride count');

  begin
    perform public.advance_ride_status(v_ride, 'completed');
    raise exception 'expected a completed trip to stay completed';
  exception when invalid_parameter_value then null;
  end;
end;
$$;

-- 7. Decline releases the rider and reopens the request.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_ride uuid;
  v_row public.ride_requests%rowtype;
  v_available boolean;
begin
  v_ride := (public.create_ride_request(
    p_pickup_address => 'Awasian',
    p_pickup_barangay => 'Awasian',
    p_dropoff_address => 'Bioto',
    p_dropoff_barangay => 'Bioto',
    p_distance_km => 3.1,
    p_eta_minutes => 9,
    p_fare_centavos => 9000
  )->>'id')::uuid;

  perform public.assign_ride_request(
    v_ride, 'e0000000-0000-0000-0000-000000000002'
  );
  perform set_config(
    'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000002', true
  );
  perform public.respond_to_ride_request(v_ride, false);

  select * into v_row from public.ride_requests where id = v_ride;
  perform public.test_assert(v_row.status = 'searching',
    'declining reopens the request');
  perform public.test_assert(v_row.rider_id is null,
    'declining clears the rider');
  select is_available into v_available
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000002';
  perform public.test_assert(v_available,
    'declining frees the rider');

  perform set_config(
    'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', true
  );
  perform public.test_assert(
    (select count(*) from public.notifications
      where profile_id = 'e0000000-0000-0000-0000-000000000001'
        and title like '%declined%') >= 1,
    'declining notifies the passenger'
  );
end;
$$;

-- 8. Cancellation releases the rider and notifies them.
do $$
declare
  v_ride uuid;
  v_row public.ride_requests%rowtype;
  v_available boolean;
begin
  v_ride := (public.create_ride_request(
    p_pickup_address => 'Bioto',
    p_pickup_barangay => 'Bioto',
    p_dropoff_address => 'Telaje',
    p_dropoff_barangay => 'Telaje',
    p_distance_km => 2.4,
    p_eta_minutes => 7,
    p_fare_centavos => 7000
  )->>'id')::uuid;

  perform public.assign_ride_request(
    v_ride, 'e0000000-0000-0000-0000-000000000002'
  );
  perform public.cancel_ride_request(v_ride, 'Test cancellation');

  select * into v_row from public.ride_requests where id = v_ride;
  perform public.test_assert(v_row.status = 'cancelled',
    'cancelling ends the request');
  perform public.test_assert(v_row.cancellation_reason = 'Test cancellation',
    'cancelling records the reason');
  select is_available into v_available
    from public.rider_presence
   where profile_id = 'e0000000-0000-0000-0000-000000000002';
  perform public.test_assert(v_available,
    'cancelling frees the rider');
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000002', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.notifications
      where profile_id = 'e0000000-0000-0000-0000-000000000002'
        and title = 'Ride cancelled') >= 1,
    'cancelling notifies the rider'
  );
end;
$$;

-- 9. An open request is visible to an approved earner whose rider role is only
-- pending; an unapproved account cannot see it.
select set_config(
  'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_ride uuid;
begin
  v_ride := (public.create_ride_request(
    p_pickup_address => 'Mabua',
    p_pickup_barangay => 'Mabua',
    p_dropoff_address => 'San Isidro',
    p_dropoff_barangay => 'San Isidro',
    p_distance_km => 5.0,
    p_eta_minutes => 14,
    p_fare_centavos => 10000
  )->>'id')::uuid;

  perform set_config(
    'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000005', true
  );
  perform public.test_assert(
    public.can_access_ride(v_ride),
    'an approved earner with rider:pending can access the open pool'
  );
  perform public.test_assert(
    (select count(*) from public.ride_requests where id = v_ride) = 1,
    'the pending earner sees the open request'
  );

  perform set_config(
    'request.jwt.claim.sub', 'e0000000-0000-0000-0000-000000000006', true
  );
  perform public.test_assert(
    not public.can_access_ride(v_ride),
    'an unapproved account cannot access the open pool'
  );
  perform public.test_assert(
    (select count(*) from public.ride_requests where id = v_ride) = 0,
    'an unapproved account cannot read the open request'
  );
end;
$$;

-- 10. Clients cannot write rider_presence directly.
do $$
begin
  begin
    insert into public.rider_presence (profile_id, is_online)
    values ('e0000000-0000-0000-0000-000000000001', true);
    raise exception 'expected a direct presence insert to be denied';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.rider_presence set is_online = false
     where profile_id = 'e0000000-0000-0000-0000-000000000002';
    raise exception 'expected a direct presence update to be denied';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
rollback;
