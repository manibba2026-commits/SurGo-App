begin;

-- Owner vehicle management and notification acknowledgements.
--
-- Fixtures: two approved vehicle owners, a renter and a plain account, private
-- photo objects under each owner's folder, and notifications for the owner and
-- the renter. The test proves the RPCs enforce ownership and role, validate
-- photo paths, list/unlist without deleting history, keep the catalogue RLS
-- honest, and that clients still cannot write the tables or another account's
-- storage folder directly.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('b2000000-0000-0000-0000-000000000001', 'owner.one@example.com',
   '+639170004001', '{"full_name":"Owner One"}'::jsonb),
  ('b2000000-0000-0000-0000-000000000002', 'owner.two@example.com',
   '+639170004002', '{"full_name":"Owner Two"}'::jsonb),
  ('b2000000-0000-0000-0000-000000000003', 'renter.vehicle@example.com',
   '+639170004003', '{"full_name":"Vehicle Renter"}'::jsonb),
  ('b2000000-0000-0000-0000-000000000004', 'plain.vehicle@example.com',
   '+639170004004', '{"full_name":"Plain Vehicle Account"}'::jsonb);

-- The auth trigger already grants every account an approved passenger role.
insert into public.user_roles (profile_id, role, status, approved_at) values
  ('b2000000-0000-0000-0000-000000000001', 'vehicle_owner', 'approved', now()),
  ('b2000000-0000-0000-0000-000000000002', 'vehicle_owner', 'approved', now());

insert into public.notifications (profile_id, notification_type, title, body) values
  ('b2000000-0000-0000-0000-000000000001', 'rental', 'Owner alert', 'Owner only'),
  ('b2000000-0000-0000-0000-000000000001', 'system', 'Owner second', 'Owner only 2'),
  ('b2000000-0000-0000-0000-000000000003', 'ride', 'Renter alert', 'Renter only');

-- The private objects exist before the RPCs validate paths. These rows are
-- inserted as the migration owner, which is what an upload would have done.
insert into storage.objects (bucket_id, name, owner) values
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/one.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/two.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/three.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/four.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/five.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/six.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000001/vehicles/seven.jpg', 'b2000000-0000-0000-0000-000000000001'),
  ('vehicle-photos', 'b2000000-0000-0000-0000-000000000002/vehicles/foreign.jpg', 'b2000000-0000-0000-0000-000000000002');

select set_config(
  'surgo.owner_notification',
  (select id from public.notifications where title = 'Owner alert')::text,
  true
);
select set_config(
  'surgo.owner_second',
  (select id from public.notifications where title = 'Owner second')::text,
  true
);
select set_config(
  'surgo.renter_notification',
  (select id from public.notifications where title = 'Renter alert')::text,
  true
);

-- 1. Function privileges, bucket and policies.
do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.create_vehicle(text,text,text,text,bigint,uuid,text,text,integer,text,text[])',
    'public.update_vehicle(uuid,text,text,text,text,bigint,uuid,text,text,integer,text,boolean,text[])',
    'public.set_vehicle_listing(uuid,boolean)',
    'public.mark_notification_read(uuid)',
    'public.mark_all_notifications_read()'
  ] loop
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE'),
      'anon must not execute ' || v_sig
    );
    perform public.test_assert(
      has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      'authenticated must execute ' || v_sig
    );
  end loop;

  perform public.test_assert(
    not has_function_privilege(
      'authenticated',
      'public._vehicle_photo_path_valid(uuid,text)',
      'EXECUTE'
    ),
    'the photo path validator is not callable by clients'
  );

  perform public.test_assert(
    exists (
      select 1 from storage.buckets
       where id = 'vehicle-photos' and not public
    ),
    'vehicle photos live in a private bucket'
  );

  perform public.test_assert(
    (select count(*) from pg_policies
      where schemaname = 'storage'
        and policyname in (
          'surgo vehicle photos read',
          'surgo vehicle photos insert own',
          'surgo vehicle photos update own',
          'surgo vehicle photos delete own'
        )) = 4,
    'vehicle photo storage policies exist'
  );
end;
$$;

-- 2. An approved owner creates a listing.
select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', true
);
set local role authenticated;

select set_config(
  'surgo.test_vehicle',
  public.create_vehicle(
    'Honda Click 125i', 'motorcycle', '2-Wheel', 'tst 001', 50000,
    null, 'Honda', 'Click', 2023, 'Black',
    array[
      'b2000000-0000-0000-0000-000000000001/vehicles/one.jpg',
      'b2000000-0000-0000-0000-000000000001/vehicles/two.jpg'
    ]
  )::text,
  true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_vehicle')::uuid;
begin
  perform public.test_assert(
    (select service_area_id is not null from public.vehicles where id = v_id),
    'a default service area is chosen'
  );
  perform public.test_assert(
    (select name = 'Honda Click 125i'
       and vehicle_type = 'motorcycle'
       and category = '2-Wheel'
       and plate_number = 'TST 001'
       and price_per_day_centavos = 50000
       and status = 'active'
       and make = 'Honda'
       and model = 'Click'
       and model_year = 2023
       and color = 'Black'
       and photo_paths = array[
         'b2000000-0000-0000-0000-000000000001/vehicles/one.jpg',
         'b2000000-0000-0000-0000-000000000001/vehicles/two.jpg'
       ]
     from public.vehicles where id = v_id),
    'create_vehicle stores an active listing with its photos'
  );
end;
$$;

-- 3. Creation validation.
do $$
declare
  v_area uuid := (select id from public.service_areas limit 1);
  v_refused boolean;
begin
  v_refused := false;
  begin
    perform public.create_vehicle(
      'Duplicate', 'motorcycle', '2-Wheel', 'TST 001', 50000, v_area
    );
  exception when unique_violation then
    v_refused := true;
  end;
  perform public.test_assert(v_refused, 'a duplicate plate is refused');

  v_refused := false;
  begin
    perform public.create_vehicle(
      'Boat', 'boat', 'Boat', 'TST 002', 50000, v_area
    );
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(v_refused, 'an invalid category is refused');

  v_refused := false;
  begin
    perform public.create_vehicle(
      'Foreign photo', 'motorcycle', '2-Wheel', 'TST 003', 50000, v_area,
      null, null, null, null,
      array['b2000000-0000-0000-0000-000000000002/vehicles/foreign.jpg']
    );
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'another owner''s photo path is refused'
  );

  v_refused := false;
  begin
    perform public.create_vehicle(
      'Missing photo', 'motorcycle', '2-Wheel', 'TST 004', 50000, v_area,
      null, null, null, null,
      array['b2000000-0000-0000-0000-000000000001/vehicles/missing.jpg']
    );
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'a path with no stored object is refused'
  );

  v_refused := false;
  begin
    perform public.create_vehicle(
      'Too many photos', 'motorcycle', '2-Wheel', 'TST 005', 50000, v_area,
      null, null, null, null,
      array[
        'b2000000-0000-0000-0000-000000000001/vehicles/one.jpg',
        'b2000000-0000-0000-0000-000000000001/vehicles/two.jpg',
        'b2000000-0000-0000-0000-000000000001/vehicles/three.jpg',
        'b2000000-0000-0000-0000-000000000001/vehicles/four.jpg',
        'b2000000-0000-0000-0000-000000000001/vehicles/five.jpg',
        'b2000000-0000-0000-0000-000000000001/vehicles/six.jpg',
        'b2000000-0000-0000-0000-000000000001/vehicles/seven.jpg'
      ]
    );
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(v_refused, 'more than six photos is refused');
end;
$$;

-- 4. Updating details, photos and listing state.
do $$
declare
  v_id uuid := current_setting('surgo.test_vehicle')::uuid;
  v_area uuid := (select service_area_id from public.vehicles where id = v_id);
  v_refused boolean;
begin
  perform public.update_vehicle(
    v_id, 'Honda Click 160', 'motorcycle', '2-Wheel', 'TST 001', 60000,
    v_area, 'Honda', 'Click 160', 2024, 'Red', true,
    array[
      'b2000000-0000-0000-0000-000000000001/vehicles/one.jpg',
      'b2000000-0000-0000-0000-000000000001/vehicles/three.jpg'
    ]
  );
  perform public.test_assert(
    (select name = 'Honda Click 160'
       and price_per_day_centavos = 60000
       and model = 'Click 160'
       and model_year = 2024
       and color = 'Red'
       and status = 'active'
       and photo_paths = array[
         'b2000000-0000-0000-0000-000000000001/vehicles/one.jpg',
         'b2000000-0000-0000-0000-000000000001/vehicles/three.jpg'
       ]
     from public.vehicles where id = v_id),
    'update_vehicle replaces details and the photo list'
  );

  perform public.update_vehicle(
    v_id, 'Honda Click 160', 'motorcycle', '2-Wheel', 'TST 001', 60000,
    v_area, 'Honda', 'Click 160', 2024, 'Red', false, null
  );
  perform public.test_assert(
    (select status = 'inactive' from public.vehicles where id = v_id),
    'unlisting through update_vehicle keeps the row and sets inactive'
  );

  -- Null means "leave the stored photo list alone".
  perform public.update_vehicle(
    v_id, 'Honda Click 160', 'motorcycle', '2-Wheel', 'TST 001', 60000,
    v_area, 'Honda', 'Click 160', 2024, 'Red', true, null
  );
  perform public.test_assert(
    (select cardinality(photo_paths) = 2 from public.vehicles where id = v_id),
    'a null photo list leaves the stored photos alone'
  );

  v_refused := false;
  begin
    perform public.update_vehicle(
      v_id, 'Honda Click 160', 'motorcycle', '2-Wheel', 'TST 001', 60000,
      v_area, null, null, null, null, true,
      array['b2000000-0000-0000-0000-000000000002/vehicles/foreign.jpg']
    );
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'update_vehicle refuses a foreign photo path'
  );
end;
$$;

-- 5. Another owner cannot touch the row.
select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_vehicle')::uuid;
  v_refused boolean := false;
begin
  begin
    perform public.update_vehicle(
      v_id, 'Stolen', 'motorcycle', '2-Wheel', 'TST 001', 1000,
      null, null, null, null, null, null, null
    );
  exception when no_data_found then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'another owner cannot update the vehicle'
  );

  v_refused := false;
  begin
    perform public.set_vehicle_listing(v_id, false);
  exception when no_data_found then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'another owner cannot unlist the vehicle'
  );
end;
$$;

-- 6. Listing toggles preserve history and keep review states.
select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_vehicle')::uuid;
begin
  perform public.set_vehicle_listing(v_id, false);
  perform public.test_assert(
    (select status = 'inactive' from public.vehicles where id = v_id),
    'set_vehicle_listing(false) deactivates the listing'
  );
  perform public.test_assert(
    (select count(*) from public.vehicles where id = v_id) = 1,
    'deactivation does not delete the row'
  );

  perform public.set_vehicle_listing(v_id, true);
  perform public.test_assert(
    (select status = 'active' from public.vehicles where id = v_id),
    'set_vehicle_listing(true) relists the vehicle'
  );
end;
$$;

-- Pending and suspended vehicles cannot be listed by their owner. Unlisting one
-- must not clear the review or suspension state.
reset role;

insert into public.vehicles (
  owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, status
) values
  ('b2000000-0000-0000-0000-000000000001',
   (select id from public.service_areas limit 1),
   'Pending Vehicle', 'motorcycle', '2-Wheel', 'TST 006',
   'pending_verification'),
  ('b2000000-0000-0000-0000-000000000001',
   (select id from public.service_areas limit 1),
   'Suspended Vehicle', 'motorcycle', '2-Wheel', 'TST 007', 'suspended');

select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', true
);
set local role authenticated;

do $$
declare
  v_pending uuid := (select id from public.vehicles where plate_number = 'TST 006');
  v_suspended uuid := (select id from public.vehicles where plate_number = 'TST 007');
  v_refused boolean;
begin
  v_refused := false;
  begin
    perform public.set_vehicle_listing(v_pending, true);
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'a pending vehicle cannot be listed by its owner'
  );
  perform public.test_assert(
    (select status = 'pending_verification' from public.vehicles where id = v_pending),
    'the pending status is preserved'
  );

  v_refused := false;
  begin
    perform public.set_vehicle_listing(v_suspended, true);
  exception when invalid_parameter_value then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'a suspended vehicle cannot be relisted by its owner'
  );
  perform public.test_assert(
    (select status = 'suspended' from public.vehicles where id = v_suspended),
    'the suspended status is preserved'
  );

  perform public.set_vehicle_listing(v_suspended, false);
  perform public.test_assert(
    (select status = 'suspended' from public.vehicles where id = v_suspended),
    'unlisting a suspended vehicle does not clear the suspension'
  );
end;
$$;

-- 7. The rental catalogue only shows active rows, while the owner sees their
--    own inactive row.
select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000003', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.vehicles where plate_number = 'TST 001') = 1,
    'a renter sees an active listing'
  );
  perform public.test_assert(
    (select count(*) from public.vehicles where plate_number = 'TST 006') = 0,
    'a renter does not see a pending vehicle'
  );
  perform public.test_assert(
    (select count(*) from public.vehicles where plate_number = 'TST 007') = 0,
    'a renter does not see a suspended vehicle'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', true
);
select public.set_vehicle_listing(
  current_setting('surgo.test_vehicle')::uuid, false
);

select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000003', true
);
do $$
begin
  perform public.test_assert(
    (select count(*) from public.vehicles where plate_number = 'TST 001') = 0,
    'an unlisted vehicle leaves the renter catalogue'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', true
);
do $$
begin
  perform public.test_assert(
    (select count(*) from public.vehicles where plate_number = 'TST 001') = 1,
    'the owner still sees their unlisted vehicle'
  );
end;
$$;

-- 8. Notification acknowledgements are scoped to the signed-in profile.
do $$
declare
  v_id uuid := current_setting('surgo.owner_notification')::uuid;
  v_other uuid := current_setting('surgo.renter_notification')::uuid;
  v_count integer;
begin
  v_count := public.mark_notification_read(v_id);
  perform public.test_assert(
    v_count = 1, 'marking an own notification read changes one row'
  );
  perform public.test_assert(
    (select read_at is not null from public.notifications where id = v_id),
    'the read timestamp is stamped'
  );

  perform public.test_assert(
    public.mark_notification_read(v_id) = 1,
    're-marking an own notification is accepted'
  );

  perform public.test_assert(
    public.mark_notification_read(v_other) = 0,
    'another account''s notification is not changed'
  );

  v_count := public.mark_all_notifications_read();
  perform public.test_assert(
    v_count = 1, 'mark all read changes the remaining unread owner row'
  );
  perform public.test_assert(
    (select count(*) from public.notifications
      where profile_id = auth.uid() and read_at is null) = 0,
    'the owner feed is fully read'
  );
  perform public.test_assert(
    public.mark_all_notifications_read() = 0,
    'marking an already-read feed changes nothing'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000003', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.notifications where read_at is null) = 1,
    'the owner''s mark-all did not touch the renter feed'
  );
  perform public.test_assert(
    public.mark_all_notifications_read() = 1,
    'the renter can mark their own feed read'
  );
  perform public.test_assert(
    (select count(*) from public.notifications where read_at is null) = 0,
    'the renter feed is fully read'
  );
end;
$$;

-- 9. Role and session checks.
select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000004', true
);

do $$
declare
  v_refused boolean := false;
begin
  begin
    perform public.create_vehicle(
      'Plain vehicle', 'motorcycle', '2-Wheel', 'TST 008', 50000
    );
  exception when insufficient_privilege then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'an account without the owner role cannot create a vehicle'
  );
end;
$$;

select set_config('request.jwt.claim.sub', '', true);

do $$
declare
  v_refused boolean := false;
begin
  begin
    perform public.mark_notification_read(gen_random_uuid());
  exception when insufficient_privilege then
    v_refused := true;
  end;
  perform public.test_assert(
    v_refused, 'a signed-out caller cannot mark notifications read'
  );
end;
$$;

-- 10. Direct table writes are still denied at the grant level.
select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000001', true
);

do $$
begin
  begin
    insert into public.vehicles (
      owner_profile_id, name, vehicle_type, category, plate_number
    ) values (
      auth.uid(), 'Direct', 'motorcycle', '2-Wheel', 'DIR 001'
    );
    raise exception 'expected vehicle insert denial';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.vehicles set name = 'Hacked'
     where owner_profile_id = auth.uid();
    raise exception 'expected vehicle update denial';
  exception when insufficient_privilege then null;
  end;

  begin
    delete from public.vehicles where owner_profile_id = auth.uid();
    raise exception 'expected vehicle delete denial';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.notifications set read_at = now()
     where profile_id = auth.uid();
    raise exception 'expected notification update denial';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- 11. Storage stays private and folder-scoped.
do $$
begin
  insert into storage.objects (bucket_id, name, owner) values (
    'vehicle-photos',
    'b2000000-0000-0000-0000-000000000001/vehicles/upload.jpg',
    auth.uid()
  );

  begin
    insert into storage.objects (bucket_id, name, owner) values (
      'vehicle-photos',
      'b2000000-0000-0000-0000-000000000002/vehicles/steal.jpg',
      auth.uid()
    );
    raise exception 'expected foreign folder insert denial';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000003', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from storage.objects
      where bucket_id = 'vehicle-photos') >= 8,
    'signed-in users can read listing photo objects'
  );
end;
$$;

rollback;
