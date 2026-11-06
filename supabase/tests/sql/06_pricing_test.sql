begin;

-- No policy is seeded, so pricing must fail closed.
do $$
declare
  v_failed boolean := false;
begin
  begin
    perform 1 from public.calculate_service_price('ride', 1, 0);
  exception when no_data_found then
    v_failed := true;
  end;
  perform public.test_assert(
    v_failed, 'missing pricing policy must reject the quote'
  );
end;
$$;

-- Deterministic half-up centavo rounding.
do $$
begin
  perform public.test_assert(public.round_centavos(0.5) = 1,
    '0.5 must round up to 1');
  perform public.test_assert(public.round_centavos(1.49) = 1,
    '1.49 must round down to 1');
  perform public.test_assert(public.round_centavos(1.5) = 2,
    '1.5 must round up to 2');
  perform public.test_assert(public.round_centavos(2.5) = 3,
    '2.5 must round half up to 3');
  perform public.test_assert(public.round_centavos(-1.5) = -2,
    'negative halves must round away from zero');
end;
$$;

-- Fixed customer-addon ride policy.
insert into public.pricing_policies (
  name, service_type, base_fare_centavos, per_km_centavos,
  minimum_fare_centavos, platform_fee_fixed_centavos,
  platform_fee_mode, platform_fee_type,
  approved_at, effective_from, is_active
) values (
  'Test ride fixed addon', 'ride', 10000, 0, 10000, 1500,
  'customer_addon', 'fixed', now(), now() - interval '1 minute', true
);

-- Percentage provider-deduction Pasuyo policy. The percentage is deliberately
-- a test value, not the old 10%/15% defaults.
insert into public.pricing_policies (
  name, service_type, base_fare_centavos, per_km_centavos,
  minimum_fare_centavos, platform_fee_bps,
  platform_fee_mode, platform_fee_type,
  approved_at, effective_from, is_active
) values (
  'Test pasuyo percentage deduction', 'pasuyo', 20000, 0, 20000, 1250,
  'provider_deduction', 'percentage',
  now(), now() - interval '1 minute', true
);

-- Distance-based fee with both a floor and a ceiling.
insert into public.pricing_policies (
  name, service_type, base_fare_centavos, per_km_centavos,
  minimum_fare_centavos, platform_fee_type,
  platform_fee_per_km_centavos, minimum_platform_fee_centavos,
  maximum_platform_fee_centavos, platform_fee_mode,
  approved_at, effective_from, is_active
) values (
  'Test rental distance fee', 'rental', 0, 333, 0,
  'distance', 100, 500, 1000, 'customer_addon',
  now(), now() - interval '1 minute', true
);

do $$
declare
  v record;
  v_ride_id uuid;
begin
  select id into v_ride_id
    from public.pricing_policies
   where name = 'Test ride fixed addon';

  select * into v from public.calculate_service_price('ride', 5, 0);
  perform public.test_assert(v.pricing_policy_id = v_ride_id,
    'quote must reference the active policy');
  perform public.test_assert(v.pricing_policy_version = 1,
    'first ride policy must be version 1');
  perform public.test_assert(v.fare_centavos = 10000,
    'fixed ride fare must be the base fare');
  perform public.test_assert(v.platform_fee_centavos = 1500,
    'fixed customer addon fee must be 1500');
  perform public.test_assert(v.customer_pays_centavos = 11500,
    'customer total must be fare plus addon fee');
  perform public.test_assert(v.provider_payout_centavos = 10000,
    'provider keeps the fare in customer_addon mode');
  perform public.test_assert(v.platform_revenue_centavos = 1500,
    'platform revenue equals the fee');
end;
$$;

do $$
declare
  v record;
begin
  select * into v from public.calculate_service_price('pasuyo', 0, 0);
  perform public.test_assert(v.fare_centavos = 20000,
    'percentage policy fare must be the base fare');
  perform public.test_assert(v.platform_fee_centavos = 2500,
    '12.5% of 20000 must be 2500');
  perform public.test_assert(v.customer_pays_centavos = 20000,
    'provider_deduction does not add the fee to the customer total');
  perform public.test_assert(v.provider_payout_centavos = 17500,
    'provider payout must be fare minus the fee');
  perform public.test_assert(v.platform_revenue_centavos = 2500,
    'platform revenue equals the deducted fee');
  perform public.test_assert(v.fee_mode = 'provider_deduction',
    'quote must expose the configured fee mode');
end;
$$;

do $$
declare
  v record;
begin
  select * into v from public.calculate_service_price('rental', 1.5, 0);
  perform public.test_assert(v.fare_centavos = 500,
    '499.5 centavos must round half up to 500');
  perform public.test_assert(v.platform_fee_centavos = 500,
    'distance fee below the floor must be raised to 500');
  perform public.test_assert(v.customer_pays_centavos = 1000,
    'customer total must reflect the minimum fee');

  select * into v from public.calculate_service_price('rental', 0.5, 0);
  perform public.test_assert(v.fare_centavos = 167,
    '166.5 centavos must round half up to 167');
  perform public.test_assert(v.platform_fee_centavos = 500,
    'minimum fee applies at short distances');
  perform public.test_assert(v.customer_pays_centavos = 667,
    'customer total must use rounded fare and floored fee');

  select * into v from public.calculate_service_price('rental', 20, 0);
  perform public.test_assert(v.fare_centavos = 6660,
    'distance fare must be 20 km at 333 centavos per km');
  perform public.test_assert(v.platform_fee_centavos = 1000,
    'distance fee above the ceiling must be capped at 1000');
  perform public.test_assert(v.customer_pays_centavos = 7660,
    'customer total must use the capped fee');
end;
$$;

-- Versioning: a second policy for the same service is version 2.
insert into public.pricing_policies (name, service_type)
values ('Test ride draft version 2', 'ride');

do $$
begin
  perform public.test_assert(
    (select version from public.pricing_policies
      where name = 'Test ride draft version 2') = 2,
    'new policy must receive the next version for its service type'
  );

  perform public.test_assert(
    (select count(*) from public.pricing_policies
      where service_type = 'ride' and is_active) = 1,
    'only one ride policy may be active'
  );
end;
$$;

do $$
declare
  v_blocked boolean := false;
begin
  begin
    update public.pricing_policies
       set base_fare_centavos = 1
     where name = 'Test ride fixed addon';
  exception when raise_exception then
    v_blocked := true;
  end;

  perform public.test_assert(v_blocked,
    'approved pricing terms must be immutable');

  perform public.test_assert(
    (select base_fare_centavos from public.pricing_policies
      where name = 'Test ride fixed addon') = 10000,
    'a blocked update must not change the approved fare'
  );
end;
$$;

do $$
declare
  v_failed boolean := false;
  v_draft uuid;
begin
  select id into v_draft
    from public.pricing_policies
   where name = 'Test ride draft version 2';

  begin
    perform 1 from public.calculate_service_price('ride', 1, 0, v_draft);
  exception when no_data_found then
    v_failed := true;
  end;

  perform public.test_assert(v_failed,
    'an inactive policy id must not be used for pricing');
end;
$$;

do $$
declare
  v_distance_failed boolean := false;
  v_duration_failed boolean := false;
begin
  begin
    perform 1 from public.calculate_service_price('ride', -1, 0);
  exception when invalid_parameter_value then
    v_distance_failed := true;
  end;

  begin
    perform 1 from public.calculate_service_price('ride', 1, -1);
  exception when invalid_parameter_value then
    v_duration_failed := true;
  end;

  perform public.test_assert(v_distance_failed,
    'negative distance must be rejected');
  perform public.test_assert(v_duration_failed,
    'negative duration must be rejected');
end;
$$;

rollback;



