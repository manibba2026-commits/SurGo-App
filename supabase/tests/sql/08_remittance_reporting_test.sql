begin;

-- Remittance lifecycle, provider earnings and platform revenue reporting.
-- All amounts are integer centavos and every policy below is a test value.
-- Nothing here is the proposed production pricing model.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('40000000-0000-0000-0000-000000000004', 'remit.customer@example.com',
   '+639200000004', '{"full_name":"Remit Customer"}'::jsonb),
  ('50000000-0000-0000-0000-000000000005', 'remit.provider@example.com',
   '+639200000005', '{"full_name":"Remit Provider"}'::jsonb),
  ('60000000-0000-0000-0000-000000000006', 'remit.admin@example.com',
   '+639200000006', '{"full_name":"Remit Admin"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('50000000-0000-0000-0000-000000000005', 'rider', 'approved', now()),
  ('60000000-0000-0000-0000-000000000006', 'admin', 'approved', now());

insert into public.ride_requests (
  id, passenger_id, rider_id, service_area_id, status, pickup_address,
  pickup_barangay_id, dropoff_address, distance_km, eta_minutes,
  fare_centavos, accepted_at, started_at, completed_at
) values (
  '70000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000005',
  (select id from public.service_areas where city = 'Tandag City'),
  'completed', 'Awasian', (select id from public.barangays where name = 'Awasian'),
  'Bioto', 4.0, 10, 0,
  now() - interval '2 hours', now() - interval '90 minutes',
  now() - interval '1 hour'
);

insert into public.vehicles (
  id, owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, price_per_day_centavos, status
) values (
  '70000000-0000-0000-0000-000000000003',
  '50000000-0000-0000-0000-000000000005',
  (select id from public.service_areas where city = 'Tandag City'),
  'Remit Test Bike', 'motorcycle', '2-Wheel', 'REM 001', 50000, 'active'
);

insert into public.rental_bookings (
  id, renter_id, owner_id, vehicle_id, service_area_id, status,
  start_at, end_at, duration_hours, total_fare_centavos,
  accepted_at, started_at, returned_at, completed_at
) values (
  '70000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000005',
  '70000000-0000-0000-0000-000000000003',
  (select id from public.service_areas where city = 'Tandag City'),
  'completed', now() - interval '3 hours', now() - interval '1 hour', 2, 0,
  now() - interval '3 hours', now() - interval '3 hours',
  now() - interval '1 hour', now() - interval '1 hour'
);

insert into public.service_requests (
  id, customer_id, provider_id, service_area_id, category, status, title,
  pickup_address, pickup_barangay_id, quoted_fee_centavos,
  accepted_at, picked_up_at, delivered_at
) values (
  '70000000-0000-0000-0000-000000000004',
  '40000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000005',
  (select id from public.service_areas where city = 'Tandag City'),
  'groceries', 'delivered', 'Remit test errand', 'Mabuhay',
  (select id from public.barangays where name = 'Mabuhay'), 0,
  now() - interval '2 hours', now() - interval '90 minutes',
  now() - interval '1 hour'
);

-- Fixed test fees: 400 (addon) + 200 (addon) + 400 (deduction) = 1000.
insert into public.pricing_policies (
  name, service_type, base_fare_centavos, per_km_centavos,
  minimum_fare_centavos, platform_fee_fixed_centavos,
  platform_fee_mode, platform_fee_type,
  approved_at, effective_from, is_active
) values
  ('Remit test ride', 'ride', 10000, 0, 10000, 400,
   'customer_addon', 'fixed', now(), now() - interval '1 minute', true),
  ('Remit test rental', 'rental', 50000, 0, 50000, 200,
   'customer_addon', 'fixed', now(), now() - interval '1 minute', true),
  ('Remit test pasuyo', 'pasuyo', 20000, 0, 20000, 400,
   'provider_deduction', 'fixed', now(), now() - interval '1 minute', true);

do $$
declare
  v_ride public.service_transactions;
  v_rental public.service_transactions;
  v_pasuyo public.service_transactions;
begin
  v_ride := public.settle_service_transaction(
    'ride', '70000000-0000-0000-0000-000000000001'
  );
  v_rental := public.settle_service_transaction(
    'rental', '70000000-0000-0000-0000-000000000002'
  );
  v_pasuyo := public.settle_service_transaction(
    'pasuyo', '70000000-0000-0000-0000-000000000004'
  );

  perform public.test_assert(v_ride.fare_centavos = 10000,
    'ride fare must be the fixed test base fare');
  perform public.test_assert(v_ride.platform_fee_centavos = 400,
    'ride fee must be the fixed test fee');
  perform public.test_assert(v_ride.customer_pays_centavos = 10400,
    'ride customer total must add the customer_addon fee');

  perform public.test_assert(v_rental.fare_centavos = 50000,
    'rental fare must be the fixed test base fare');
  perform public.test_assert(v_rental.customer_pays_centavos = 50200,
    'rental customer total must add the customer_addon fee');

  perform public.test_assert(v_pasuyo.fare_centavos = 20000,
    'pasuyo fare must be the fixed test base fare');
  perform public.test_assert(v_pasuyo.customer_pays_centavos = 20000,
    'provider_deduction must not add the fee to the customer total');
  perform public.test_assert(v_pasuyo.provider_payout_centavos = 19600,
    'provider_deduction payout must subtract the fee');

  perform public.test_assert(
    (select sum(amount_centavos) from public.platform_fee_receivables) = 1000,
    'the three settlements must create 1000 centavos of receivables'
  );
  perform public.test_assert(
    (select count(*) from public.platform_fee_receivables
      where status = 'open') = 3,
    'every new receivable must be open'
  );

  -- Confirm the cash the customer handed over. This is provider cash, not
  -- SurGo revenue, and it still does not move any wallet balance.
  perform public.confirm_cash_collection(v_ride.id, 10400, null);
  perform public.confirm_cash_collection(v_rental.id, 50200, null);
  perform public.confirm_cash_collection(v_pasuyo.id, 20000, null);

  perform public.test_assert(
    (select count(*) from public.cash_collections
      where status = 'confirmed') = 3,
    'all three cash collections must be confirmed'
  );
  perform public.test_assert(
    (select count(*) from public.wallet_transactions) = 0,
    'cash confirmation must never credit a wallet'
  );
end;
$$;

-- Provider earnings and platform revenue before any remittance is verified.
do $$
declare
  v_provider public.provider_earnings_summary;
  v_platform public.platform_revenue_summary;
begin
  select * into v_provider from public.provider_earnings_summary;
  select * into v_platform from public.platform_revenue_summary;

  perform public.test_assert(v_provider.completed_transactions = 3,
    'provider summary must count the three transactions');
  perform public.test_assert(v_provider.gross_fare_centavos = 80000,
    'provider summary gross fare must be 80000');
  perform public.test_assert(v_provider.platform_fee_centavos = 1000,
    'provider summary fee total must be 1000');
  perform public.test_assert(v_provider.cash_expected_centavos = 80600,
    'provider summary cash expected must be 80600');
  perform public.test_assert(v_provider.net_earnings_centavos = 79600,
    'provider summary net earnings must be 79600');
  perform public.test_assert(v_provider.platform_revenue_centavos = 1000,
    'provider summary platform revenue must be 1000');
  perform public.test_assert(v_provider.fees_receivable_centavos = 1000,
    'provider summary must show 1000 receivable');
  perform public.test_assert(v_provider.fees_remitted_centavos = 0,
    'no cash has been remitted yet');
  perform public.test_assert(v_provider.fees_outstanding_centavos = 1000,
    'all 1000 centavos must be outstanding');
  perform public.test_assert(v_provider.cash_confirmed_centavos = 80600,
    'provider summary must total confirmed cash');
  perform public.test_assert(v_provider.pending_cash_collections = 0,
    'no cash collection may remain pending');
  perform public.test_assert(v_provider.failed_cash_collections = 0,
    'no cash collection may be failed');

  perform public.test_assert(v_platform.completed_transactions = 3,
    'platform summary must count the three transactions');
  perform public.test_assert(v_platform.fare_centavos = 80000,
    'platform summary fare must be 80000');
  perform public.test_assert(v_platform.platform_fee_centavos = 1000,
    'platform summary fee must be 1000');
  perform public.test_assert(v_platform.platform_revenue_centavos = 1000,
    'platform summary revenue must be 1000');
  perform public.test_assert(v_platform.customer_pays_centavos = 80600,
    'platform summary customer total must be 80600');
  perform public.test_assert(v_platform.provider_payout_centavos = 79600,
    'platform summary payout must be 79600');
  perform public.test_assert(v_platform.fees_remitted_centavos = 0,
    'platform summary must show nothing remitted');
  perform public.test_assert(v_platform.fees_outstanding_centavos = 1000,
    'platform summary must show 1000 outstanding');
end;
$$;

-- Invalid and over-limit remittances must fail without writing a row.
do $$
declare
  v_ride_receivable uuid;
  v_zero_blocked boolean := false;
  v_negative_blocked boolean := false;
  v_over_blocked boolean := false;
begin
  select r.id into v_ride_receivable
    from public.platform_fee_receivables r
    join public.service_transactions st on st.id = r.service_transaction_id
   where st.ride_id = '70000000-0000-0000-0000-000000000001';

  begin
    perform public.record_provider_fee_remittance(
      v_ride_receivable, 0, 'REM-ZERO',
      '50000000-0000-0000-0000-000000000005'
    );
  exception when invalid_parameter_value then
    v_zero_blocked := true;
  end;

  begin
    perform public.record_provider_fee_remittance(
      v_ride_receivable, -100, 'REM-NEGATIVE',
      '50000000-0000-0000-0000-000000000005'
    );
  exception when invalid_parameter_value then
    v_negative_blocked := true;
  end;

  begin
    perform public.record_provider_fee_remittance(
      v_ride_receivable, 401, 'REM-OVER',
      '50000000-0000-0000-0000-000000000005'
    );
  exception when raise_exception then
    v_over_blocked := true;
  end;

  perform public.test_assert(v_zero_blocked,
    'a zero remittance must be rejected');
  perform public.test_assert(v_negative_blocked,
    'a negative remittance must be rejected');
  perform public.test_assert(v_over_blocked,
    'a remittance above the outstanding amount must be rejected');
  perform public.test_assert(
    (select count(*) from public.provider_fee_remittances) = 0,
    'rejected remittance attempts must not create rows'
  );
  perform public.test_assert(
    (select amount_remitted_centavos
       from public.platform_fee_receivables
      where id = v_ride_receivable) = 0,
    'failed remittance attempts must not change the receivable'
  );
end;
$$;

-- Rejected remittance never counts as received cash.
do $$
declare
  v_ride_receivable uuid;
  v_remittance public.provider_fee_remittances;
  v_verified public.provider_fee_remittances;
  v_missing_reason_blocked boolean := false;
  v_approve_after_reject_blocked boolean := false;
begin
  select r.id into v_ride_receivable
    from public.platform_fee_receivables r
    join public.service_transactions st on st.id = r.service_transaction_id
   where st.ride_id = '70000000-0000-0000-0000-000000000001';

  v_remittance := public.record_provider_fee_remittance(
    v_ride_receivable, 100, 'REM-REJECTED-1',
    '50000000-0000-0000-0000-000000000005', 'Wrong bank slip'
  );
  perform public.test_assert(v_remittance.status = 'submitted',
    'a new remittance must start submitted');

  begin
    perform public.verify_provider_fee_remittance(
      v_remittance.id, false, '60000000-0000-0000-0000-000000000006', null
    );
  exception when invalid_parameter_value then
    v_missing_reason_blocked := true;
  end;
  perform public.test_assert(v_missing_reason_blocked,
    'rejecting a remittance requires a reason');

  v_verified := public.verify_provider_fee_remittance(
    v_remittance.id, false, '60000000-0000-0000-0000-000000000006',
    'Reference does not match the deposit'
  );
  perform public.test_assert(v_verified.status = 'rejected',
    'an admin must be able to reject a remittance');
  perform public.test_assert(v_verified.verified_at is not null,
    'a rejected remittance must record the decision time');
  perform public.test_assert(
    v_verified.rejection_reason = 'Reference does not match the deposit',
    'the rejection reason must be stored'
  );
  perform public.test_assert(
    (select amount_remitted_centavos
       from public.platform_fee_receivables
      where id = v_ride_receivable) = 0,
    'a rejected remittance must not reduce the receivable'
  );
  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_ride_receivable) = 'open',
    'a rejected remittance must leave the receivable open'
  );
  perform public.test_assert(
    (select fees_remitted_centavos
       from public.platform_revenue_summary) = 0,
    'rejected remittances must not appear as platform cash'
  );

  begin
    perform public.verify_provider_fee_remittance(
      v_remittance.id, true, '60000000-0000-0000-0000-000000000006'
    );
  exception when raise_exception then
    v_approve_after_reject_blocked := true;
  end;
  perform public.test_assert(v_approve_after_reject_blocked,
    'a rejected remittance cannot later be approved');
end;
$$;

-- Partial remittance: a submitted row is not cash received, only admin
-- verification reduces the receivable.
do $$
declare
  v_ride_receivable uuid;
  v_remittance public.provider_fee_remittances;
  v_again public.provider_fee_remittances;
begin
  select r.id into v_ride_receivable
    from public.platform_fee_receivables r
    join public.service_transactions st on st.id = r.service_transaction_id
   where st.ride_id = '70000000-0000-0000-0000-000000000001';

  v_remittance := public.record_provider_fee_remittance(
    v_ride_receivable, 250, 'REM-RIDE-A',
    '50000000-0000-0000-0000-000000000005'
  );

  perform public.test_assert(
    (select amount_remitted_centavos
       from public.platform_fee_receivables
      where id = v_ride_receivable) = 0,
    'submitted remittances must not count as received cash'
  );
  perform public.test_assert(
    (select fees_outstanding_centavos
       from public.platform_revenue_summary) = 1000,
    'submitted remittances must stay outstanding until verified'
  );

  v_again := public.verify_provider_fee_remittance(
    v_remittance.id, true, '60000000-0000-0000-0000-000000000006'
  );
  perform public.test_assert(v_again.status = 'verified',
    'the admin must be able to verify a partial remittance');
  perform public.test_assert(
    (select amount_remitted_centavos
       from public.platform_fee_receivables
      where id = v_ride_receivable) = 250,
    'verification must add the remitted amount');
  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_ride_receivable) = 'partially_remitted',
    'a 250 of 400 remittance must mark the receivable partial');
  perform public.test_assert(
    (select last_remittance_at from public.platform_fee_receivables
      where id = v_ride_receivable) is not null,
    'verification must stamp the last remittance time'
  );

  -- Re-verifying the same approved remittance is idempotent.
  v_again := public.verify_provider_fee_remittance(
    v_remittance.id, true, '60000000-0000-0000-0000-000000000006'
  );
  perform public.test_assert(v_again.id = v_remittance.id,
    're-verification must return the same remittance');
  perform public.test_assert(
    (select amount_remitted_centavos
       from public.platform_fee_receivables
      where id = v_ride_receivable) = 250,
    're-verification must not double-count cash'
  );

  perform public.test_assert(
    (select fees_remitted_centavos
       from public.provider_earnings_summary) = 250,
    'provider summary must show the verified 250 only'
  );
  perform public.test_assert(
    (select fees_outstanding_centavos
       from public.provider_earnings_summary) = 750,
    'provider summary must keep 750 outstanding'
  );
end;
$$;

-- Finish the ride receivable, then complete the rental and Pasuyo receivables.
do $$
declare
  v_ride_receivable uuid;
  v_rental_receivable uuid;
  v_pasuyo_receivable uuid;
  v_ride_second public.provider_fee_remittances;
  v_rental_first public.provider_fee_remittances;
  v_rental_again public.provider_fee_remittances;
  v_pasuyo public.provider_fee_remittances;
  v_closed_blocked boolean := false;
  v_reference_blocked boolean := false;
begin
  select r.id into v_ride_receivable
    from public.platform_fee_receivables r
    join public.service_transactions st on st.id = r.service_transaction_id
   where st.ride_id = '70000000-0000-0000-0000-000000000001';

  select r.id into v_rental_receivable
    from public.platform_fee_receivables r
    join public.service_transactions st on st.id = r.service_transaction_id
   where st.rental_id = '70000000-0000-0000-0000-000000000002';

  select r.id into v_pasuyo_receivable
    from public.platform_fee_receivables r
    join public.service_transactions st on st.id = r.service_transaction_id
   where st.service_request_id = '70000000-0000-0000-0000-000000000004';

  v_ride_second := public.record_provider_fee_remittance(
    v_ride_receivable, 150, 'REM-RIDE-B',
    '50000000-0000-0000-0000-000000000005'
  );
  perform public.verify_provider_fee_remittance(
    v_ride_second.id, true, '60000000-0000-0000-0000-000000000006'
  );

  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_ride_receivable) = 'remitted',
    'the ride receivable must be fully remitted');
  perform public.test_assert(
    (select amount_remitted_centavos
       from public.platform_fee_receivables
      where id = v_ride_receivable) = 400,
    'the ride receivable must total 400 remitted');

  begin
    perform public.record_provider_fee_remittance(
      v_ride_receivable, 1, 'REM-RIDE-EXTRA',
      '50000000-0000-0000-0000-000000000005'
    );
  exception when raise_exception then
    v_closed_blocked := true;
  end;
  perform public.test_assert(v_closed_blocked,
    'a fully remitted receivable must reject new remittances');

  -- Same reference and amount is idempotent.
  v_rental_first := public.record_provider_fee_remittance(
    v_rental_receivable, 200, 'REM-RENTAL-1',
    '50000000-0000-0000-0000-000000000005'
  );
  v_rental_again := public.record_provider_fee_remittance(
    v_rental_receivable, 200, 'REM-RENTAL-1',
    '50000000-0000-0000-0000-000000000005'
  );
  perform public.test_assert(v_rental_again.id = v_rental_first.id,
    'the same provider reference and amount must be idempotent');
  perform public.test_assert(
    (select count(*) from public.provider_fee_remittances
      where reference_number = 'REM-RENTAL-1') = 1,
    'a repeated reference must not create a second row'
  );

  -- Reusing a reference for another receivable or amount must fail.
  begin
    perform public.record_provider_fee_remittance(
      v_pasuyo_receivable, 100, 'REM-RENTAL-1',
      '50000000-0000-0000-0000-000000000005'
    );
  exception when raise_exception then
    v_reference_blocked := true;
  end;
  perform public.test_assert(v_reference_blocked,
    'a reference number cannot be reused across receivables');

  perform public.verify_provider_fee_remittance(
    v_rental_first.id, true, '60000000-0000-0000-0000-000000000006'
  );
  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_rental_receivable) = 'remitted',
    'the rental receivable must be fully remitted');

  v_pasuyo := public.record_provider_fee_remittance(
    v_pasuyo_receivable, 400, 'REM-PASUYO-1',
    '50000000-0000-0000-0000-000000000005'
  );
  perform public.verify_provider_fee_remittance(
    v_pasuyo.id, true, '60000000-0000-0000-0000-000000000006'
  );
  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_pasuyo_receivable) = 'remitted',
    'the Pasuyo receivable must be fully remitted');
end;
$$;

-- Final reconciliation: fully remitted, cash confirmed and reports agree.
do $$
declare
  v_provider public.provider_earnings_summary;
  v_platform public.platform_revenue_summary;
  v_daily_transactions bigint;
  v_daily_fare bigint;
  v_daily_fee bigint;
  v_daily_revenue bigint;
  v_daily_customer bigint;
  v_daily_payout bigint;
  v_daily_remitted bigint;
  v_daily_outstanding bigint;
begin
  select * into v_provider from public.provider_earnings_summary;
  select * into v_platform from public.platform_revenue_summary;

  select coalesce(sum(completed_transactions), 0),
         coalesce(sum(fare_centavos), 0),
         coalesce(sum(platform_fee_centavos), 0),
         coalesce(sum(platform_revenue_centavos), 0),
         coalesce(sum(customer_pays_centavos), 0),
         coalesce(sum(provider_payout_centavos), 0),
         coalesce(sum(fees_remitted_centavos), 0),
         coalesce(sum(fees_outstanding_centavos), 0)
    into v_daily_transactions, v_daily_fare, v_daily_fee,
         v_daily_revenue, v_daily_customer, v_daily_payout,
         v_daily_remitted, v_daily_outstanding
    from public.platform_revenue_daily;

  perform public.test_assert(v_provider.fees_receivable_centavos = 1000,
    'provider summary receivable total must stay 1000');
  perform public.test_assert(v_provider.fees_remitted_centavos = 1000,
    'provider summary must show all 1000 remitted');
  perform public.test_assert(v_provider.fees_outstanding_centavos = 0,
    'provider summary outstanding must be zero');
  perform public.test_assert(v_provider.cash_confirmed_centavos = 80600,
    'provider summary confirmed cash must remain 80600');

  perform public.test_assert(v_platform.completed_transactions = 3,
    'platform summary must still count three transactions');
  perform public.test_assert(v_platform.fees_remitted_centavos = 1000,
    'platform summary must show all 1000 remitted');
  perform public.test_assert(v_platform.fees_outstanding_centavos = 0,
    'platform summary outstanding must be zero');
  perform public.test_assert(
    v_platform.platform_revenue_centavos
      = v_platform.platform_fee_centavos,
    'platform revenue must equal the configured fees'
  );
  perform public.test_assert(
    v_platform.customer_pays_centavos
      = v_platform.provider_payout_centavos
        + v_platform.platform_revenue_centavos,
    'customer cash must reconcile to provider payout plus platform revenue'
  );

  perform public.test_assert(v_daily_transactions = v_platform.completed_transactions,
    'daily report must count every transaction');
  perform public.test_assert(v_daily_fare = v_platform.fare_centavos,
    'daily report fare must reconcile to the summary');
  perform public.test_assert(v_daily_fee = v_platform.platform_fee_centavos,
    'daily report fees must reconcile to the summary');
  perform public.test_assert(v_daily_revenue = v_platform.platform_revenue_centavos,
    'daily report revenue must reconcile to the summary');
  perform public.test_assert(v_daily_customer = v_platform.customer_pays_centavos,
    'daily report customer cash must reconcile to the summary');
  perform public.test_assert(v_daily_payout = v_platform.provider_payout_centavos,
    'daily report payout must reconcile to the summary');
  perform public.test_assert(v_daily_remitted = v_platform.fees_remitted_centavos,
    'daily report remitted cash must reconcile to the summary');
  perform public.test_assert(v_daily_outstanding = v_platform.fees_outstanding_centavos,
    'daily report outstanding fees must reconcile to the summary');

  perform public.test_assert(
    (select count(*) from public.platform_fee_receivables
      where status <> 'remitted') = 0,
    'every receivable must end fully remitted'
  );
  perform public.test_assert(
    (select count(*) from public.provider_fee_remittances
      where status = 'submitted') = 0,
    'no remittance may be left awaiting verification'
  );
  perform public.test_assert(
    (select count(*) from public.provider_fee_remittances
      where status = 'verified') = 4,
    'three partial ride/rental/Pasuyo settlements produce four verified rows'
  );
end;
$$;

rollback;
