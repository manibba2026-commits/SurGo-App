begin;

-- Demo PIN access: storage boundary, lookup, lockout and status preservation.
--
-- The hashes here are format-valid placeholders. Hashing and comparison live
-- in the demo-login Edge Function; this test covers the SQL contract.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('c1000000-0000-0000-0000-000000000001',
   'rhea.demo@surgo-demo.test', '+639170000007',
   '{"full_name":"Rhea Puno","surgo_demo":true}'::jsonb),
  ('c1000000-0000-0000-0000-000000000002',
   'junel.demo@surgo-demo.test', '+639170000003',
   '{"full_name":"Junel Ramos","surgo_demo":true}'::jsonb),
  ('c1000000-0000-0000-0000-000000000003',
   'real.user@example.com', '+639180000399',
   '{"full_name":"Real User"}'::jsonb);

-- The auth trigger created the profiles; Junel must stay suspended throughout.
update public.profiles
   set account_status = 'suspended'
 where id = 'c1000000-0000-0000-0000-000000000002';

-- 1. Only service_role may reach the PIN table and the RPCs.
do $$
declare
  v_sig text;
begin
  perform public.test_assert(
    has_schema_privilege('service_role', 'private', 'usage'),
    'service_role can use the private schema'
  );
  perform public.test_assert(
    not has_schema_privilege('anon', 'private', 'usage')
      and not has_schema_privilege('authenticated', 'private', 'usage'),
    'clients have no usage on the private schema'
  );
  perform public.test_assert(
    not has_table_privilege('anon', 'private.demo_access', 'select')
      and not has_table_privilege('authenticated', 'private.demo_access', 'select'),
    'clients cannot read private.demo_access'
  );
  perform public.test_assert(
    has_table_privilege('service_role', 'private.demo_access', 'select'),
    'service_role can read private.demo_access'
  );

  foreach v_sig in array array[
    'public.set_demo_access(uuid,text)',
    'public.demo_login_lookup(text)',
    'public.demo_login_record_failure(uuid)',
    'public.demo_login_record_success(uuid)'
  ] loop
    perform public.test_assert(
      has_function_privilege('service_role', v_sig, 'EXECUTE'),
      'service_role can execute ' || v_sig
    );
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE')
        and not has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      'clients cannot execute ' || v_sig
    );
  end loop;
end;
$$;

-- 2. PIN assignment refuses non-demo accounts and malformed hashes.
do $$
begin
  begin
    perform public.set_demo_access(
      'c1000000-0000-0000-0000-000000000003',
      'pbkdf2-sha256$210000$saltOneForDemoPin1234$hashOneForDemoPin0123456789abcdefGHIJKLM'
    );
    raise exception 'expected a non-demo account to be refused';
  exception when insufficient_privilege then
    null;
  end;

  begin
    perform public.set_demo_access(
      'c1000000-0000-0000-0000-000000000001', 'not-a-hash');
    raise exception 'expected a malformed hash to be refused';
  exception when invalid_parameter_value then
    null;
  end;

  perform public.test_assert(
    not exists (select 1 from private.demo_access),
    'refused assignments wrote no row'
  );
end;
$$;

-- 3. Lookup returns the demo row and ignores unknown or non-E.164 input.
select public.set_demo_access(
  'c1000000-0000-0000-0000-000000000001',
  'pbkdf2-sha256$210000$saltOneForDemoPin1234$hashOneForDemoPin0123456789abcdefGHIJKLM'
);

do $$
declare
  v_row record;
begin
  select * into v_row from public.demo_login_lookup('+639170000007');
  perform public.test_assert(
    v_row.user_id = 'c1000000-0000-0000-0000-000000000001',
    'lookup finds the demo account by E.164 phone'
  );
  perform public.test_assert(
    v_row.account_status = 'active',
    'lookup reports the profile status'
  );
  perform public.test_assert(
    v_row.failed_attempts = 0 and v_row.locked_until is null,
    'a fresh account is unlocked'
  );

  -- Normalization is the Edge Function's job; the RPC matches E.164 only.
  perform public.test_assert(
    not exists (select 1 from public.demo_login_lookup('09170000007')),
    'lookup does not accept the local 09 form directly'
  );
  perform public.test_assert(
    not exists (select 1 from public.demo_login_lookup('+639179999999')),
    'unknown phone returns no row'
  );
end;
$$;

-- 4. Five failures lock for 15 minutes; success clears the state.
do $$
declare
  v_row record;
  i integer;
begin
  for i in 1..4 loop
    select * into v_row
      from public.demo_login_record_failure(
        'c1000000-0000-0000-0000-000000000001');
    perform public.test_assert(
      v_row.failed_attempts = i and v_row.locked_until is null,
      format('failure %s does not lock yet', i)
    );
  end loop;

  select * into v_row
    from public.demo_login_record_failure(
      'c1000000-0000-0000-0000-000000000001');
  perform public.test_assert(
    v_row.failed_attempts = 5 and v_row.locked_until > now(),
    'the fifth failure locks the account'
  );

  -- A retry while locked must not push the unlock time out.
  select * into v_row
    from public.demo_login_record_failure(
      'c1000000-0000-0000-0000-000000000001');
  perform public.test_assert(
    v_row.failed_attempts = 5,
    'a retry while locked does not add a failure'
  );

  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000001');
  select * into v_row from public.demo_login_lookup('+639170000007');
  perform public.test_assert(
    v_row.failed_attempts = 0 and v_row.locked_until is null,
    'success clears the failure count and lock'
  );
end;
$$;

-- 5. An expired lock starts a fresh count instead of re-locking instantly.
update private.demo_access
   set failed_attempts = 5,
       locked_until = now() - interval '1 minute'
 where user_id = 'c1000000-0000-0000-0000-000000000001';

do $$
declare
  v_row record;
begin
  select * into v_row
    from public.demo_login_record_failure(
      'c1000000-0000-0000-0000-000000000001');
  perform public.test_assert(
    v_row.failed_attempts = 1,
    'the first miss after an expired lock restarts the count'
  );
  perform public.test_assert(
    v_row.locked_until is null,
    'one miss after expiry does not lock again'
  );
end;
$$;

-- 6. A suspended demo profile is reported but never changed by PIN activity.
select public.set_demo_access(
  'c1000000-0000-0000-0000-000000000002',
  'pbkdf2-sha256$210000$saltTwoForDemoPin5678$hashTwoForDemoPin0123456789abcdefGHIJKLMN'
);

do $$
declare
  v_row record;
begin
  select * into v_row from public.demo_login_lookup('+639170000003');
  perform public.test_assert(
    v_row.user_id = 'c1000000-0000-0000-0000-000000000002'
      and v_row.account_status = 'suspended',
    'lookup returns a suspended demo account so the function can refuse it'
  );

  perform public.demo_login_record_failure(
    'c1000000-0000-0000-0000-000000000002');
  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000002');

  perform public.test_assert(
    (select account_status from public.profiles
      where id = 'c1000000-0000-0000-0000-000000000002') = 'suspended',
    'PIN activity never changes the account status'
  );
end;
$$;

-- 7. Unknown ids are a no-op rather than an error.
do $$
begin
  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000009');
  perform public.test_assert(
    not exists (
      select 1 from public.demo_login_record_failure(
        'c1000000-0000-0000-0000-000000000009')
    ),
    'unknown user ids return no lockout row'
  );
end;
$$;

rollback;
