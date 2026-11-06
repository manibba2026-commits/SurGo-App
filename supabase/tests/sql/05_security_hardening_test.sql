begin;

-- Fixtures created as the database owner (bypasses RLS).
insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('a1111111-1111-1111-1111-111111111111', 'alice.sec@example.com',
   '+639180000001', '{"full_name":"Alice Sec"}'::jsonb),
  ('b2222222-2222-2222-2222-222222222222', 'bob.sec@example.com',
   '+639180000002', '{"full_name":"Bob Sec"}'::jsonb),
  ('c3333333-3333-3333-3333-333333333333', 'carol.sec@example.com',
   '+639180000003', '{"full_name":"Carol Sec"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('b2222222-2222-2222-2222-222222222222', 'rider', 'approved', now()),
  ('c3333333-3333-3333-3333-333333333333', 'admin', 'approved', now());

insert into public.wallet_accounts (id, profile_id, account_type, balance_centavos)
values
  ('dddddddd-0000-0000-0000-000000000001',
   'a1111111-1111-1111-1111-111111111111', 'passenger', 10000),
  ('dddddddd-0000-0000-0000-000000000002',
   'b2222222-2222-2222-2222-222222222222', 'passenger', 5000);

insert into public.wallet_transactions (
  wallet_account_id, transaction_type, direction, amount_centavos,
  balance_after_centavos
) values
  ('dddddddd-0000-0000-0000-000000000001', 'top_up', 'credit', 10000, 10000),
  ('dddddddd-0000-0000-0000-000000000002', 'top_up', 'credit', 5000, 5000);

insert into public.verification_applications (
  id, profile_id, capability_type, status, submitted_at
) values (
  'eeeeeeee-0000-0000-0000-000000000001',
  'a1111111-1111-1111-1111-111111111111', 'rider', 'submitted', now()
);

insert into public.verification_documents (application_id, document_type)
values ('eeeeeeee-0000-0000-0000-000000000001', 'drivers_license');

insert into public.provider_profiles (
  profile_id, provider_type, service_area_id, display_name, capabilities
) values (
  'b2222222-2222-2222-2222-222222222222', 'earner',
  (select id from public.service_areas), 'Bob Sec',
  array['rides']::public.earner_capability[]
);

insert into public.vehicles (
  id, owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, status
) values (
  'f1111111-0000-0000-0000-000000000001',
  'a1111111-1111-1111-1111-111111111111',
  (select id from public.service_areas), 'Alice Bike', 'motorcycle',
  '2-Wheel', 'SEC 001', 'inactive'
);

insert into public.vehicle_documents (vehicle_id, document_type, storage_path)
values (
  'f1111111-0000-0000-0000-000000000001', 'registration',
  'a1111111-1111-1111-1111-111111111111/bike.pdf'
);

insert into public.ride_requests (
  id, passenger_id, service_area_id, status, pickup_address,
  pickup_barangay_id, dropoff_address, fare_centavos, cancelled_at
) values
  ('aaaa1111-0000-0000-0000-000000000001',
   'a1111111-1111-1111-1111-111111111111',
   (select id from public.service_areas), 'cancelled', 'Awasian',
   (select id from public.barangays where name = 'Awasian'), 'Bioto',
   12000, now()),
  ('bbbb2222-0000-0000-0000-000000000002',
   'b2222222-2222-2222-2222-222222222222',
   (select id from public.service_areas), 'cancelled', 'Mabua',
   (select id from public.barangays where name = 'Mabua'), 'Bioto',
   9000, now());

insert into storage.objects (bucket_id, name) values
  ('verification-documents',
   'a1111111-1111-1111-1111-111111111111/license.pdf'),
  ('verification-documents',
   'b2222222-2222-2222-2222-222222222222/license.pdf');

-- 1. Structural privileges: anon has none, authenticated has SELECT only.
do $$
declare
  v_rel record;
  v_bad text := '';
begin
  for v_rel in
    select c.oid, c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
  loop
    if has_table_privilege('anon', v_rel.oid, 'SELECT') then
      v_bad := v_bad || 'anon:select:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('anon', v_rel.oid, 'INSERT') then
      v_bad := v_bad || 'anon:insert:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('anon', v_rel.oid, 'UPDATE') then
      v_bad := v_bad || 'anon:update:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('anon', v_rel.oid, 'DELETE') then
      v_bad := v_bad || 'anon:delete:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('anon', v_rel.oid, 'TRUNCATE') then
      v_bad := v_bad || 'anon:truncate:' || v_rel.relname || ' ';
    end if;

    if v_rel.relname = 'admin_audit_logs' then
      if has_table_privilege('authenticated', v_rel.oid, 'SELECT') then
        v_bad := v_bad || 'auth:select-audit-logs ';
      end if;
    elsif not has_table_privilege('authenticated', v_rel.oid, 'SELECT') then
      v_bad := v_bad || 'auth:no-select:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('authenticated', v_rel.oid, 'INSERT') then
      v_bad := v_bad || 'auth:insert:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('authenticated', v_rel.oid, 'UPDATE') then
      v_bad := v_bad || 'auth:update:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('authenticated', v_rel.oid, 'DELETE') then
      v_bad := v_bad || 'auth:delete:' || v_rel.relname || ' ';
    end if;
    if has_table_privilege('authenticated', v_rel.oid, 'TRUNCATE') then
      v_bad := v_bad || 'auth:truncate:' || v_rel.relname || ' ';
    end if;
  end loop;

  perform public.test_assert(
    v_bad = '', 'unexpected table privileges: ' || v_bad
  );
end;
$$;

-- 2. Function EXECUTE: anon never, authenticated only on the RLS helpers.
do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.has_approved_role(public.user_role_type)',
    'public.is_approved_provider(uuid)',
    'public.owns_vehicle(uuid)',
    'public.owns_verification_application(uuid)',
    'public.owns_wallet_account(uuid)',
    'public.can_access_ride(uuid)',
    'public.can_access_rental(uuid)',
    'public.can_access_service_request(uuid)'
  ]
  loop
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE'),
      'anon must not execute ' || v_sig
    );
    perform public.test_assert(
      has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      'authenticated must execute ' || v_sig
    );
    perform public.test_assert(
      has_function_privilege('service_role', v_sig, 'EXECUTE'),
      'service_role must execute ' || v_sig
    );
  end loop;

  perform public.test_assert(
    not has_function_privilege('anon', 'public.set_updated_at()', 'EXECUTE'),
    'anon must not execute set_updated_at'
  );
  perform public.test_assert(
    not has_function_privilege(
      'authenticated', 'public.set_updated_at()', 'EXECUTE'
    ),
    'authenticated must not execute set_updated_at'
  );
  perform public.test_assert(
    not has_function_privilege(
      'authenticated', 'public.handle_new_auth_user()', 'EXECUTE'
    ),
    'authenticated must not execute handle_new_auth_user'
  );
  perform public.test_assert(
    not has_function_privilege(
      'authenticated', 'public.handle_auth_user_updated()', 'EXECUTE'
    ),
    'authenticated must not execute handle_auth_user_updated'
  );

  perform public.test_assert(
    (select proconfig from pg_proc
      where oid = 'public.set_updated_at()'::regprocedure)
      @> array['search_path=""'],
    'set_updated_at must pin search_path'
  );
end;
$$;

-- 2b. Financial RPCs and views follow the same privilege boundary.
do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.get_active_pricing_policy(public.service_type, timestamptz)',
    'public.calculate_service_price(public.service_type, numeric, integer, uuid, timestamptz)',
    'public.settle_service_transaction(public.service_type, uuid, numeric, integer, uuid)',
    'public.confirm_cash_collection(uuid, bigint, uuid, text)',
    'public.fail_cash_collection(uuid, text, uuid)',
    'public.open_cash_payment_dispute(uuid, text, bigint, uuid, uuid)',
    'public.resolve_cash_payment_dispute(uuid, public.cash_dispute_status, text, uuid)',
    'public.record_provider_fee_remittance(uuid, bigint, text, uuid, text)',
    'public.verify_provider_fee_remittance(uuid, boolean, uuid, text)'
  ]
  loop
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE'),
      'anon must not execute ' || v_sig
    );
    perform public.test_assert(
      has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      'authenticated must execute ' || v_sig
    );
    perform public.test_assert(
      has_function_privilege('service_role', v_sig, 'EXECUTE'),
      'service_role must execute ' || v_sig
    );
  end loop;

  foreach v_sig in array array[
    'public.round_centavos(numeric)',
    'public.ensure_transaction_accounts(uuid)',
    'public.assign_pricing_policy_version()',
    'public.guard_pricing_policy_terms()',
    'public.guard_settled_transaction_snapshot()',
    'public.guard_settled_transaction_delete()'
  ]
  loop
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE'),
      'anon must not execute internal ' || v_sig
    );
    perform public.test_assert(
      not has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      'authenticated must not execute internal ' || v_sig
    );
  end loop;

  foreach v_sig in array array[
    'public.provider_earnings_summary',
    'public.platform_revenue_daily',
    'public.platform_revenue_summary'
  ]
  loop
    perform public.test_assert(
      not has_table_privilege('anon', v_sig, 'SELECT'),
      'anon must not read ' || v_sig
    );
    perform public.test_assert(
      has_table_privilege('authenticated', v_sig, 'SELECT'),
      'authenticated must read ' || v_sig
    );
    perform public.test_assert(
      has_table_privilege('service_role', v_sig, 'SELECT'),
      'service_role must read ' || v_sig
    );
  end loop;
end;
$$;

-- 3. Trigger functions still fire after EXECUTE was revoked.
do $$
begin
  perform public.test_assert(
    (select count(*) from public.profiles where id =
      'a1111111-1111-1111-1111-111111111111') = 1,
    'the auth trigger must still create profiles'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles where profile_id =
      'a1111111-1111-1111-1111-111111111111' and role = 'passenger') = 1,
    'the auth trigger must still grant the passenger role'
  );
end;
$$;

-- 4. Default privileges for future migration-created tables.
create table public.security_default_probe (id integer);
create sequence public.security_default_probe_seq;

do $$
begin
  perform public.test_assert(
    not has_table_privilege('anon', 'public.security_default_probe', 'SELECT'),
    'new tables must not be readable by anon'
  );
  perform public.test_assert(
    has_table_privilege(
      'authenticated', 'public.security_default_probe', 'SELECT'
    ),
    'new tables must remain readable by authenticated'
  );
  perform public.test_assert(
    not has_table_privilege(
      'authenticated', 'public.security_default_probe', 'INSERT'
    ),
    'new tables must not be writable by authenticated'
  );
  perform public.test_assert(
    not has_sequence_privilege(
      'anon', 'public.security_default_probe_seq', 'USAGE'
    ),
    'new sequences must not be usable by anon'
  );
  perform public.test_assert(
    not has_sequence_privilege(
      'authenticated', 'public.security_default_probe_seq', 'USAGE'
    ),
    'new sequences must not be usable by authenticated'
  );
  perform public.test_assert(
    has_sequence_privilege(
      'service_role', 'public.security_default_probe_seq', 'USAGE'
    ),
    'service_role must keep sequence access'
  );
end;
$$;

drop sequence public.security_default_probe_seq;
drop table public.security_default_probe;

-- 5. Anonymous requests are denied outright.
set local role anon;

do $$
begin
  begin
    perform 1 from public.profiles limit 1;
    raise exception 'anon must not read profiles';
  exception when insufficient_privilege then null;
  end;

  begin
    perform 1 from public.wallet_accounts limit 1;
    raise exception 'anon must not read wallets';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.has_approved_role('admin');
    raise exception 'anon must not execute RLS helpers';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- 6. Signed-in users keep their permitted reads only.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1111111-1111-1111-1111-111111111111', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.profiles) = 1,
    'a user must only see their own profile'
  );
  perform public.test_assert(
    (select count(*) from public.wallet_accounts) = 1,
    'a user must only see their own wallet'
  );
  perform public.test_assert(
    (select count(*) from public.wallet_transactions) = 1,
    'a user must only see their own ledger'
  );
  perform public.test_assert(
    (select count(*) from public.verification_documents) = 1,
    'a user must only see their own verification documents'
  );
  perform public.test_assert(
    (select count(*) from public.ride_requests) = 1,
    'a user must only see their own rides'
  );
  perform public.test_assert(
    (select count(*) from public.vehicles) = 1,
    'a user sees their own vehicle even when inactive'
  );
  perform public.test_assert(
    (select count(*) from public.vehicle_documents) = 1,
    'a user must only see documents of their own vehicle'
  );
  perform public.test_assert(
    (select count(*) from public.provider_profiles) = 1,
    'an approved provider profile stays readable'
  );
  perform public.test_assert(
    not public.can_access_ride('bbbb2222-0000-0000-0000-000000000002'),
    'a user must not access an unrelated ride'
  );
  perform public.test_assert(
    public.can_access_ride('aaaa1111-0000-0000-0000-000000000001'),
    'a user must access their own ride'
  );
end;
$$;

-- 6b. Another signed-in user cannot see Alice's vehicle or its documents.
select set_config(
  'request.jwt.claim.sub', 'b2222222-2222-2222-2222-222222222222', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.vehicles) = 0,
    'an inactive vehicle must stay hidden from other users'
  );
  perform public.test_assert(
    (select count(*) from public.vehicle_documents) = 0,
    'another user must not see vehicle documents'
  );
  perform public.test_assert(
    (select count(*) from public.provider_profiles) = 1,
    'a provider sees their own provider profile'
  );
  perform public.test_assert(
    (select count(*) from public.ride_requests) = 1,
    'a rider sees only their own non-open ride'
  );
  perform public.test_assert(
    not public.can_access_ride('aaaa1111-0000-0000-0000-000000000001'),
    'a rider must not access a cancelled ride they never took'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub', 'a1111111-1111-1111-1111-111111111111', true
);

-- 7. No self-escalation of roles.
do $$
begin
  begin
    insert into public.user_roles (profile_id, role, status, approved_at)
    values ('a1111111-1111-1111-1111-111111111111', 'admin', 'approved', now());
    raise exception 'self-assigned admin role must be rejected';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.user_roles set role = 'admin'
     where profile_id = 'a1111111-1111-1111-1111-111111111111';
    raise exception 'role update must be rejected';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- 8. Storage: own folder only, no writes into someone else's folder.
do $$
begin
  perform public.test_assert(
    (select count(*) from storage.objects) = 1,
    'a user must only list their own storage folder'
  );

  begin
    insert into storage.objects (bucket_id, name)
    values ('verification-documents',
      'b2222222-2222-2222-2222-222222222222/spoof.pdf');
    raise exception 'writing into another user folder must be rejected';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- 9. Admin reads are policy-driven; audit logs stay service-role only.
select set_config(
  'request.jwt.claim.sub', 'c3333333-3333-3333-3333-333333333333', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.profiles) = 3,
    'an admin must see every profile'
  );
  perform public.test_assert(
    (select count(*) from public.wallet_accounts) = 2,
    'an admin must see every wallet'
  );
  begin
    perform 1 from public.admin_audit_logs limit 1;
    raise exception 'audit logs must remain service_role only';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;

-- 10. Anonymous storage access sees nothing.
set local role anon;

do $$
begin
  perform public.test_assert(
    (select count(*) from storage.objects) = 0,
    'anon must not list storage objects'
  );
end;
$$;

reset role;

rollback;
