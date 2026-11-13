begin;

do $$
declare
  expected_tables text[] := array[
    'service_areas', 'barangays', 'puroks', 'pricing_policies',
    'profiles', 'user_roles', 'provider_profiles', 'vehicles',
    'vehicle_documents', 'verification_applications',
    'verification_documents', 'ride_requests', 'ride_status_events',
    'ride_locations', 'ride_ratings', 'rental_bookings',
    'service_requests', 'service_request_items', 'service_status_events',
    'service_transactions', 'wallet_accounts', 'wallet_transactions',
    'cash_fee_remittances', 'cash_collections', 'cash_payment_disputes',
    'platform_fee_receivables', 'provider_fee_remittances',
    'notifications', 'device_tokens', 'admin_audit_logs', 'attachments',
    'rider_presence'
  ];
  missing_tables text[];
  rls_tables integer;
  enum_count integer;
  updated_at_triggers integer;
  auth_triggers integer;
  realtime_tables integer;
  bucket_count integer;
begin
  select array_agg(expected.name)
    into missing_tables
    from unnest(expected_tables) as expected(name)
   where not exists (
     select 1
       from pg_tables t
      where t.schemaname = 'public'
        and t.tablename = expected.name
   );

  perform public.test_assert(
    missing_tables is null,
    'missing tables: ' || coalesce(array_to_string(missing_tables, ', '), 'none')
  );

  perform public.test_assert(
    (select count(*) from pg_tables where schemaname = 'public') = 32,
    'expected exactly 32 public tables'
  );

  select count(*) into rls_tables
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relrowsecurity;

  perform public.test_assert(rls_tables = 32, 'RLS must be enabled on all 32 tables');

  select count(*) into enum_count
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'public'
     and t.typtype = 'e';

  perform public.test_assert(enum_count = 24, 'expected 24 public enums');

  select count(*) into updated_at_triggers
    from pg_trigger
   where not tgisinternal
     and tgname like '%_set_updated_at';

  perform public.test_assert(
    updated_at_triggers = 25,
    'expected 25 updated_at triggers, found ' || updated_at_triggers
  );

  select count(*) into auth_triggers
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'auth'
     and not tg.tgisinternal
     and tg.tgname in ('on_auth_user_created', 'on_auth_user_updated');

  perform public.test_assert(auth_triggers = 2, 'expected both auth.users triggers');

  perform public.test_assert(
    (select count(*) from public.service_areas) = 1,
    'seed should create exactly one service area'
  );
  perform public.test_assert(
    (select count(*) from public.barangays) = 21,
    'seed should create 21 Tandag barangays'
  );
  perform public.test_assert(
    (select count(*) from public.puroks) = 115,
    'seed should create 115 Tandag puroks'
  );
  perform public.test_assert(
    (select count(*) from public.service_areas where city = 'Tandag City'
       and province = 'Surigao del Sur') = 1,
    'service area must be Tandag City, Surigao del Sur'
  );

  perform public.test_assert(
    (select count(*) from auth.users) = 0,
    'seed must not create users'
  );
  perform public.test_assert(
    (select count(*) from public.profiles) = 0,
    'seed must not create profiles'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles) = 0,
    'seed must not create roles'
  );
  perform public.test_assert(
    (select count(*) from public.pricing_policies) = 0,
    'no pricing policy may be seeded or activated'
  );

  select count(*) into realtime_tables
    from pg_publication_tables
   where pubname = 'supabase_realtime';

  perform public.test_assert(
    realtime_tables = 9,
    'expected 9 realtime tables, found ' || realtime_tables
  );

  select count(*) into bucket_count from storage.buckets;
  perform public.test_assert(bucket_count = 5, 'expected 5 storage buckets');
  perform public.test_assert(
    exists (select 1 from storage.buckets where id = 'vehicle-photos'),
    'the vehicle-photos bucket exists'
  );
end;
$$;

rollback;
