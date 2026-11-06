begin;

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('10000000-0000-0000-0000-000000000001', 'finance.customer@example.com',
   '+639200000001', '{"full_name":"Finance Customer"}'::jsonb),
  ('20000000-0000-0000-0000-000000000002', 'finance.provider@example.com',
   '+639200000002', '{"full_name":"Finance Provider"}'::jsonb),
  ('30000000-0000-0000-0000-000000000003', 'finance.admin@example.com',
   '+639200000003', '{"full_name":"Finance Admin"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('20000000-0000-0000-0000-000000000002', 'rider', 'approved', now()),
  ('30000000-0000-0000-0000-000000000003', 'admin', 'approved', now());

insert into public.ride_requests (
  id, passenger_id, rider_id, service_area_id, status, pickup_address,
  pickup_barangay_id, dropoff_address, distance_km, eta_minutes,
  fare_centavos, accepted_at, started_at, completed_at
) values (
  'a0000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002',
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
  'c0000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002',
  (select id from public.service_areas where city = 'Tandag City'),
  'Finance Test Bike', 'motorcycle', '2-Wheel', 'FIN 001', 50000, 'active'
);

insert into public.rental_bookings (
  id, renter_id, owner_id, vehicle_id, service_area_id, status,
  start_at, end_at, duration_hours, total_fare_centavos,
  accepted_at, started_at, returned_at, completed_at
) values (
  'b0000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002',
  'c0000000-0000-0000-0000-000000000001',
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
  'd0000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002',
  (select id from public.service_areas where city = 'Tandag City'),
  'groceries', 'delivered', 'Finance test errand', 'Mabuhay',
  (select id from public.barangays where name = 'Mabuhay'), 0,
  now() - interval '2 hours', now() - interval '90 minutes',
  now() - interval '1 hour'
);

insert into public.pricing_policies (
  name, service_type, base_fare_centavos, per_km_centavos,
  minimum_fare_centavos, platform_fee_fixed_centavos,
  platform_fee_mode, platform_fee_type,
  approved_at, effective_from, is_active
) values
  ('Cash test ride', 'ride', 10000, 1000, 10000, 1500,
   'customer_addon', 'fixed', now(), now() - interval '1 minute', true),
  ('Cash test rental', 'rental', 50000, 0, 50000, 2000,
   'customer_addon', 'fixed', now(), now() - interval '1 minute', true);

insert into public.pricing_policies (
  name, service_type, base_fare_centavos, per_km_centavos,
  minimum_fare_centavos, platform_fee_bps,
  platform_fee_mode, platform_fee_type,
  approved_at, effective_from, is_active
) values (
  'Cash test pasuyo', 'pasuyo', 20000, 0, 20000, 1250,
  'provider_deduction', 'percentage',
  now(), now() - interval '1 minute', true
);

do $$
declare
  v_ride public.service_transactions;
  v_rental public.service_transactions;
  v_pasuyo public.service_transactions;
begin
  v_ride := public.settle_service_transaction(
    'ride', 'a0000000-0000-0000-0000-000000000001'
  );

  perform public.test_assert(v_ride.status = 'completed',
    'settlement must complete the transaction');
  perform public.test_assert(v_ride.fare_centavos = 14000,
    'ride fare must be server-calculated from distance');
  perform public.test_assert(v_ride.platform_fee_centavos = 1500,
    'ride fee must come from the active policy');
  perform public.test_assert(v_ride.customer_pays_centavos = 15500,
    'ride customer total must be fare plus addon fee');
  perform public.test_assert(v_ride.provider_payout_centavos = 14000,
    'ride provider payout must equal the fare');
  perform public.test_assert(v_ride.platform_revenue_centavos = 1500,
    'ride platform revenue must equal the fee');
  perform public.test_assert(v_ride.pricing_policy_version = 1,
    'settlement must snapshot the policy version');
  perform public.test_assert(
    v_ride.pricing_snapshot ->> 'policy_version' = '1',
    'settlement must persist a pricing snapshot'
  );
  perform public.test_assert(
    (select count(*) from public.service_transactions st
      where st.ride_id = 'a0000000-0000-0000-0000-000000000001') = 1,
    'settlement must create exactly one transaction'
  );
  perform public.test_assert(
    (select count(*) from public.cash_collections cc
      where cc.service_transaction_id = v_ride.id
        and cc.status = 'pending'
        and cc.amount_expected_centavos = 15500) = 1,
    'settlement must create one pending cash collection'
  );
  perform public.test_assert(
    (select amount_centavos from public.platform_fee_receivables r
      where r.service_transaction_id = v_ride.id) = 1500,
    'settlement must create a platform-fee receivable'
  );

  v_rental := public.settle_service_transaction(
    'rental', 'b0000000-0000-0000-0000-000000000001'
  );
  perform public.test_assert(v_rental.fare_centavos = 50000,
    'rental fare must come from the policy base fare');
  perform public.test_assert(v_rental.customer_pays_centavos = 52000,
    'rental customer total must include the addon fee');

  v_pasuyo := public.settle_service_transaction(
    'pasuyo', 'd0000000-0000-0000-0000-000000000001'
  );
  perform public.test_assert(v_pasuyo.customer_pays_centavos = 20000,
    'provider_deduction customer total must equal the fare');
  perform public.test_assert(v_pasuyo.provider_payout_centavos = 17500,
    'provider_deduction payout must subtract the fee');
end;
$$;

do $$
declare
  v_first uuid;
  v_second public.service_transactions;
begin
  select id into v_first
    from public.service_transactions
   where ride_id = 'a0000000-0000-0000-0000-000000000001';

  v_second := public.settle_service_transaction(
    'ride', 'a0000000-0000-0000-0000-000000000001'
  );

  perform public.test_assert(v_second.id = v_first,
    'duplicate settlement must return the original transaction');
  perform public.test_assert(
    (select count(*) from public.service_transactions st
      where st.ride_id = 'a0000000-0000-0000-0000-000000000001') = 1,
    'duplicate settlement must not create another transaction'
  );
  perform public.test_assert(
    (select count(*) from public.platform_fee_receivables r
      where r.service_transaction_id = v_first) = 1,
    'duplicate settlement must not duplicate receivables'
  );
  perform public.test_assert(
    (select count(*) from public.cash_collections cc
      where cc.service_transaction_id = v_first) = 1,
    'duplicate settlement must not duplicate cash collections'
  );
end;
$$;

do $$
declare
  v_update_blocked boolean := false;
  v_delete_blocked boolean := false;
begin
  begin
    update public.service_transactions
       set fare_centavos = 1
     where ride_id = 'a0000000-0000-0000-0000-000000000001';
  exception when raise_exception then
    v_update_blocked := true;
  end;

  begin
    delete from public.service_transactions
     where ride_id = 'a0000000-0000-0000-0000-000000000001';
  exception when raise_exception then
    v_delete_blocked := true;
  end;

  perform public.test_assert(v_update_blocked,
    'completed transaction amounts must be immutable');
  perform public.test_assert(v_delete_blocked,
    'completed transactions must not be deletable');
  perform public.test_assert(
    (select fare_centavos from public.service_transactions
      where ride_id = 'a0000000-0000-0000-0000-000000000001') = 14000,
    'a blocked update must leave the snapshot intact'
  );
end;
$$;

do $$
declare
  v_tx_id uuid;
  v_collection public.cash_collections;
  v_wrong_blocked boolean := false;
  v_negative_blocked boolean := false;
  v_different_blocked boolean := false;
  v_again public.cash_collections;
begin
  select id into v_tx_id
    from public.service_transactions
   where ride_id = 'a0000000-0000-0000-0000-000000000001';

  begin
    perform public.confirm_cash_collection(v_tx_id, 1, null);
  exception when raise_exception then
    v_wrong_blocked := true;
  end;

  perform public.test_assert(v_wrong_blocked,
    'a cash amount different from the customer total must fail');
  perform public.test_assert(
    (select status from public.cash_collections
      where service_transaction_id = v_tx_id) = 'pending',
    'a failed confirmation must leave the collection pending'
  );

  begin
    perform public.confirm_cash_collection(v_tx_id, -1, null);
  exception when invalid_parameter_value then
    v_negative_blocked := true;
  end;
  perform public.test_assert(v_negative_blocked,
    'negative cash amounts must be rejected');

  v_collection := public.confirm_cash_collection(v_tx_id, 15500, null, 'CASH-1');
  perform public.test_assert(v_collection.status = 'confirmed',
    'the exact cash amount must confirm the collection');
  perform public.test_assert(v_collection.amount_collected_centavos = 15500,
    'confirmed cash amount must be stored');
  perform public.test_assert(v_collection.confirmed_at is not null,
    'confirmed cash collection must have a timestamp');

  v_again := public.confirm_cash_collection(v_tx_id, 15500, null);
  perform public.test_assert(v_again.id = v_collection.id,
    're-confirming the same amount must be idempotent');

  begin
    perform public.confirm_cash_collection(v_tx_id, 15000, null);
  exception when raise_exception then
    v_different_blocked := true;
  end;
  perform public.test_assert(v_different_blocked,
    'a confirmed collection cannot be changed to another amount');

  perform public.test_assert(
    (select count(*) from public.wallet_transactions) = 0,
    'provider cash confirmation must not credit a SurGo wallet'
  );
end;
$$;

do $$
declare
  v_tx_id uuid;
  v_failed public.cash_collections;
  v_confirmed public.cash_collections;
begin
  select id into v_tx_id
    from public.service_transactions
   where rental_id = 'b0000000-0000-0000-0000-000000000001';

  v_failed := public.fail_cash_collection(
    v_tx_id, 'Customer did not have the full amount', null
  );
  perform public.test_assert(v_failed.status = 'failed',
    'cash confirmation failure must be recorded');
  perform public.test_assert(
    v_failed.failure_reason = 'Customer did not have the full amount',
    'failure reason must be stored'
  );

  v_confirmed := public.confirm_cash_collection(v_tx_id, 52000, null);
  perform public.test_assert(v_confirmed.status = 'confirmed',
    'a failed collection may be retried successfully');
  perform public.test_assert(v_confirmed.failure_reason is null,
    'successful retry must clear the failure reason');
end;
$$;

do $$
declare
  v_tx_id uuid;
  v_receivable_id uuid;
  v_dispute public.cash_payment_disputes;
  v_resolved public.cash_payment_disputes;
  v_duplicate_blocked boolean := false;
  v_remit_blocked boolean := false;
begin
  select id into v_tx_id
    from public.service_transactions
   where service_request_id = 'd0000000-0000-0000-0000-000000000001';

  select id into v_receivable_id
    from public.platform_fee_receivables
   where service_transaction_id = v_tx_id;

  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_receivable_id) = 'open',
    'a new receivable must start open'
  );

  -- The provider raises a dispute against the customer.
  v_dispute := public.open_cash_payment_dispute(
    v_tx_id,
    'Customer paid less than the agreed amount',
    20000,
    '20000000-0000-0000-0000-000000000002'
  );

  perform public.test_assert(v_dispute.status = 'open',
    'a new cash dispute must be open');
  perform public.test_assert(
    v_dispute.raised_by = '20000000-0000-0000-0000-000000000002',
    'the dispute must record who raised it'
  );
  perform public.test_assert(
    v_dispute.against_profile_id = '10000000-0000-0000-0000-000000000001',
    'the dispute must record the other party'
  );
  perform public.test_assert(v_dispute.amount_centavos = 20000,
    'the dispute must store the disputed amount');
  perform public.test_assert(
    v_dispute.cash_collection_id is not null,
    'the dispute must link to the cash collection'
  );

  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_receivable_id) = 'disputed',
    'an open dispute must flag the receivable as disputed'
  );

  begin
    perform public.open_cash_payment_dispute(
      v_tx_id,
      'A second simultaneous dispute',
      null,
      '10000000-0000-0000-0000-000000000001'
    );
  exception when raise_exception then
    v_duplicate_blocked := true;
  end;

  perform public.test_assert(v_duplicate_blocked,
    'only one live dispute per transaction is allowed');
  perform public.test_assert(
    (select count(*) from public.cash_payment_disputes
      where service_transaction_id = v_tx_id
        and status in ('open', 'under_review')) = 1,
    'the duplicate attempt must not create a second live dispute'
  );

  begin
    perform public.record_provider_fee_remittance(
      v_receivable_id, 2500, 'DISPUTED-1',
      '20000000-0000-0000-0000-000000000002'
    );
  exception when raise_exception then
    v_remit_blocked := true;
  end;

  perform public.test_assert(v_remit_blocked,
    'a disputed receivable must reject remittances');
  perform public.test_assert(
    (select count(*) from public.provider_fee_remittances
      where receivable_id = v_receivable_id) = 0,
    'a blocked remittance must not be stored'
  );

  v_resolved := public.resolve_cash_payment_dispute(
    v_dispute.id,
    'resolved',
    'Customer and provider agreed on the amount',
    '30000000-0000-0000-0000-000000000003'
  );

  perform public.test_assert(v_resolved.status = 'resolved',
    'an admin must be able to resolve a dispute');
  perform public.test_assert(v_resolved.resolved_at is not null,
    'a resolved dispute must have a timestamp');
  perform public.test_assert(
    v_resolved.resolved_by = '30000000-0000-0000-0000-000000000003',
    'the resolving admin must be recorded'
  );
  perform public.test_assert(
    v_resolved.resolution = 'Customer and provider agreed on the amount',
    'the resolution text must be stored'
  );
  perform public.test_assert(
    (select status from public.platform_fee_receivables
      where id = v_receivable_id) = 'open',
    'resolving the last live dispute must restore the receivable'
  );
  perform public.test_assert(
    (select status from public.service_transactions
      where id = v_tx_id) = 'completed',
    'a dispute must not roll back the completed transaction'
  );
  perform public.test_assert(
    (select count(*) from public.cash_payment_disputes
      where service_transaction_id = v_tx_id) = 1,
    'resolution must update the dispute rather than create a new one'
  );
end;
$$;

rollback;






