begin;

do $$
begin
  perform public.test_assert(
    (select count(*) from public.service_areas) = 1,
    'reset run must contain exactly one service area'
  );
  perform public.test_assert(
    (select count(*) from public.barangays) = 21,
    'reset run must contain 21 barangays'
  );
  perform public.test_assert(
    (select count(*) from public.puroks) = 115,
    'reset run must contain 115 puroks'
  );
  perform public.test_assert(
    (select id from public.barangays where name = 'Awasian')
      = md5('surgo:barangay:tandag-city:' || lower('Awasian'))::uuid,
    'seed IDs must be deterministic'
  );
  perform public.test_assert(
    (select count(*) from (
       select barangay_id, name
         from public.puroks
        group by barangay_id, name
       having count(*) > 1
     ) duplicates) = 0,
    'puroks must be unique per barangay'
  );
  perform public.test_assert(
    to_regproc('public.set_updated_at') is not null,
    'set_updated_at helper must exist'
  );
end;
$$;

rollback;

-- The BEFORE UPDATE trigger must overwrite a supplied updated_at value.
begin;
insert into auth.users (id, email, phone, raw_user_meta_data)
values (
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'trigger@example.com',
  '+639170009999', '{"full_name":"Before"}'::jsonb
);

do $$
declare
  v_updated_at timestamptz;
begin
  update public.profiles
     set full_name = 'After',
         updated_at = timestamptz '2000-01-01 00:00:00+00'
   where id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  select updated_at into v_updated_at
    from public.profiles
   where id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  perform public.test_assert(
    v_updated_at > timestamptz '2000-01-01 00:00:00+00',
    'updated_at trigger must overwrite the supplied timestamp'
  );
end;
$$;

rollback;
