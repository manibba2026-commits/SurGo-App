begin;

-- Simulated activity attribution.
--
-- Demo rows live in the same tables as real rows. The admin aggregates must
-- count them for activity, never for revenue, and rows created without a flag
-- must default to actual.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('f1000000-0000-0000-0000-000000000001', 'audit.admin@example.com',
   '+639190001001', '{"full_name":"Audit Admin"}'::jsonb),
  ('f1000000-0000-0000-0000-000000000002', 'audit.rider@example.com',
   '+639190001002', '{"full_name":"Audit Rider"}'::jsonb),
  ('f1000000-0000-0000-0000-000000000003', 'audit.passenger@example.com',
   '+639190001003', '{"full_name":"Audit Passenger"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('f1000000-0000-0000-0000-000000000001', 'admin', 'approved', now());

insert into public.ride_requests (
  id, passenger_id, rider_id, service_area_id, status,
  pickup_address, pickup_barangay_id, dropoff_address, dropoff_barangay_id,
  distance_km, eta_minutes, fare_centavos, platform_fee_centavos,
  requested_at, accepted_at, started_at, completed_at
) values
  ('f2000000-0000-0000-0000-000000000001',
   'f1000000-0000-0000-0000-000000000003',
   'f1000000-0000-0000-0000-000000000002',
   (select id from public.service_areas), 'completed',
   'San Isidro', (select id from public.barangays where name = 'San Isidro'),
   'Bongtod', (select id from public.barangays
                where name = 'Bongtod Poblacion (East West)'),
   3.0, 10, 10800, 1200, now(), now(), now(), now()),
  ('f2000000-0000-0000-0000-000000000002',
   'f1000000-0000-0000-0000-000000000003',
   'f1000000-0000-0000-0000-000000000002',
   (select id from public.service_areas), 'completed',
   'Telaje', (select id from public.barangays where name = 'Telaje'),
   'Mabua', (select id from public.barangays where name = 'Mabua'),
   4.0, 12, 10000, 500, now(), now(), now(), now());

insert into public.service_transactions (
  id, service_type, ride_id, customer_id, provider_id,
  fare_centavos, platform_fee_centavos, customer_pays_centavos,
  provider_payout_centavos, platform_revenue_centavos,
  payment_method, status, settled_at
) values
  ('f3000000-0000-0000-0000-000000000001', 'ride',
   'f2000000-0000-0000-0000-000000000001',
   'f1000000-0000-0000-0000-000000000003',
   'f1000000-0000-0000-0000-000000000002',
   10800, 1200, 12000, 10800, 1200, 'cash', 'completed', now());

insert into public.service_transactions (
  id, service_type, ride_id, customer_id, provider_id,
  fare_centavos, platform_fee_centavos, customer_pays_centavos,
  provider_payout_centavos, platform_revenue_centavos,
  payment_method, status, settled_at, is_simulated
) values
  ('f3000000-0000-0000-0000-000000000002', 'ride',
   'f2000000-0000-0000-0000-000000000002',
   'f1000000-0000-0000-0000-000000000003',
   'f1000000-0000-0000-0000-000000000002',
   10000, 500, 10500, 10000, 500, 'cash', 'completed', now(), true);

-- 1. The flag defaults to actual for anything written without it.
do $$
begin
  perform public.test_assert(
    (select not is_simulated from public.service_transactions
      where id = 'f3000000-0000-0000-0000-000000000001'),
    'a settlement created without the flag stays actual'
  );
end;
$$;

-- 2. Admin aggregates exclude simulated rows from money only.
select set_config(
  'request.jwt.claim.sub', 'f1000000-0000-0000-0000-000000000001', true
);
set local role authenticated;

do $$
declare
  v_overview jsonb := public.admin_overview();
  v_today bigint;
begin
  perform public.test_assert(
    (v_overview ->> 'revenue_total')::bigint = 1200,
    'revenue_total counts actual settlements only'
  );
  perform public.test_assert(
    (v_overview -> 'revenue_by_service' ->> 'ride')::bigint = 1200,
    'revenue_by_service counts actual settlements only'
  );
  perform public.test_assert(
    (v_overview ->> 'simulated_transactions')::int = 1,
    'simulated settlements are counted separately'
  );
  perform public.test_assert(
    (v_overview ->> 'simulated_cash_total')::bigint = 10500,
    'simulated cash is reported separately'
  );
  perform public.test_assert(
    (v_overview ->> 'simulated_revenue_total')::bigint = 500,
    'simulated revenue is reported separately'
  );
  perform public.test_assert(
    (v_overview ->> 'rides_total')::int >= 2,
    'activity counts still describe the whole dataset'
  );

  select revenue_centavos into v_today
    from public.admin_daily_activity(1);
  perform public.test_assert(
    v_today = 1200,
    'daily revenue excludes simulated settlements'
  );
end;
$$;

reset role;
rollback;
