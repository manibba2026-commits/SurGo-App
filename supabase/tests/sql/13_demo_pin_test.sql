begin;

-- Demo PIN access: storage boundary, atomic reservation, lockout recovery and
-- status preservation.
--
-- The hashes here are format-valid placeholders. Hashing and comparison live
-- in the demo-login Edge Function; this test covers the SQL contract.

insert into auth.users (id, email, phone, raw_user_meta_data, raw_app_meta_data) values
  ('c1000000-0000-0000-0000-000000000001',
   'rhea.demo@surgo-demo.test', '+639170000017',
   '{"full_name":"Rhea Puno"}'::jsonb,
   '{"surgo_demo":true}'::jsonb),
  ('c1000000-0000-0000-0000-000000000002',
   'junel.demo@surgo-demo.test', '+639170000011',
   '{"full_name":"Junel Ramos"}'::jsonb,
   '{"surgo_demo":true}'::jsonb),
  ('c1000000-0000-0000-0000-000000000003',
   'real.user@example.com', '+639180000399',
   '{"full_name":"Real User"}'::jsonb,
   '{}'::jsonb),
  ('c1000000-0000-0000-0000-000000000004',
   'user.meta@example.com', '+639180000400',
   '{"full_name":"User Meta","surgo_demo":true}'::jsonb,
   '{}'::jsonb);

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
    'public.demo_login_reserve_attempt(text)',
    'public.demo_login_record_success(uuid)',
    'public.demo_login_clear_lockout(uuid)'
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

-- 2. PIN assignment trusts only app_metadata, never user_metadata.
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

  -- The row carries surgo_demo in user_metadata, which the account holder can
  -- write. It must still be refused.
  begin
    perform public.set_demo_access(
      'c1000000-0000-0000-0000-000000000004',
      'pbkdf2-sha256$210000$saltOneForDemoPin1234$hashOneForDemoPin0123456789abcdefGHIJKLM'
    );
    raise exception 'expected a user_metadata flag to be ignored';
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

  -- The trusted app_metadata flag is what the guard accepts.
  update auth.users
     set raw_app_meta_data = '{"surgo_demo":true}'::jsonb
   where id = 'c1000000-0000-0000-0000-000000000004';
  perform public.set_demo_access(
    'c1000000-0000-0000-0000-000000000004',
    'pbkdf2-sha256$210000$saltFourForDemoPin123$hashFourForDemoPin0123456789abcdefGHIJKL'
  );
  perform public.test_assert(
    exists (
      select 1 from private.demo_access
       where user_id = 'c1000000-0000-0000-0000-000000000004'
    ),
    'an app_metadata demo flag is accepted'
  );
  delete from private.demo_access
   where user_id = 'c1000000-0000-0000-0000-000000000004';
end;
$$;

-- 3. Reservation returns the demo row, consumes one attempt, and ignores
--    unknown, local-form or malformed input.
select public.set_demo_access(
  'c1000000-0000-0000-0000-000000000001',
  'pbkdf2-sha256$210000$saltOneForDemoPin1234$hashOneForDemoPin0123456789abcdefGHIJKLM'
);

do $$
declare
  v_row record;
begin
  select * into v_row from public.demo_login_reserve_attempt('+639170000017');
  perform public.test_assert(
    v_row.user_id = 'c1000000-0000-0000-0000-000000000001',
    'reservation finds the demo account by E.164 phone'
  );
  perform public.test_assert(
    v_row.account_status = 'active',
    'reservation reports the profile status'
  );
  perform public.test_assert(
    v_row.failed_attempts = 1 and v_row.locked_until is null,
    'the first reservation consumes one attempt without locking'
  );
  perform public.test_assert(
    not v_row.was_locked,
    'a fresh reservation reports no pre-existing lock'
  );

  -- Normalization is the Edge Function's job; the RPC matches E.164 only.
  perform public.test_assert(
    not exists (select 1 from public.demo_login_reserve_attempt('09170000017')),
    'reservation does not accept the local 09 form directly'
  );
  perform public.test_assert(
    not exists (select 1 from public.demo_login_reserve_attempt('+639179999999')),
    'unknown phone returns no row'
  );
  perform public.test_assert(
    not exists (select 1 from public.demo_login_reserve_attempt(null::text)),
    'null phone returns no row'
  );

  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000001');
end;
$$;

-- 4. Five reservations lock for 15 minutes; a retry while locked neither adds
--    an attempt nor extends the window; success clears the state.
do $$
declare
  v_row record;
  v_locked timestamptz;
  i integer;
begin
  for i in 1..4 loop
    select * into v_row
      from public.demo_login_reserve_attempt('+639170000017');
    perform public.test_assert(
      v_row.failed_attempts = i and v_row.locked_until is null,
      format('reservation %s does not lock yet', i)
    );
  end loop;

  select * into v_row
    from public.demo_login_reserve_attempt('+639170000017');
  v_locked := v_row.locked_until;
  perform public.test_assert(
    v_row.failed_attempts = 5 and v_locked > now(),
    'the fifth reservation locks the account'
  );
  perform public.test_assert(
    not v_row.was_locked,
    'the reservation that sets the lock still allows verification'
  );

  -- The Edge Function still gets the hash on the fifth reservation, so a
  -- correct fifth PIN can succeed; a sixth call is refused before verifying.
  select * into v_row
    from public.demo_login_reserve_attempt('+639170000017');
  perform public.test_assert(
    v_row.was_locked,
    'a reservation against a live lock reports was_locked'
  );
  perform public.test_assert(
    v_row.failed_attempts = 5,
    'a retry while locked does not add an attempt'
  );
  perform public.test_assert(
    v_row.locked_until = v_locked,
    'a retry while locked does not extend the window'
  );

  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000001');
  select * into v_row
    from public.demo_login_reserve_attempt('+639170000017');
  perform public.test_assert(
    v_row.failed_attempts = 1 and v_row.locked_until is null,
    'success clears the failure count and lock before the next attempt'
  );
  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000001');
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
    from public.demo_login_reserve_attempt('+639170000017');
  perform public.test_assert(
    v_row.failed_attempts = 1,
    'the first reservation after an expired lock restarts the count'
  );
  perform public.test_assert(
    v_row.locked_until is null,
    'one reservation after expiry does not lock again'
  );
  perform public.test_assert(
    not v_row.was_locked,
    'an expired lock is not reported as a live lock'
  );
  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000001');
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
  select * into v_row from public.demo_login_reserve_attempt('+639170000011');
  perform public.test_assert(
    v_row.user_id = 'c1000000-0000-0000-0000-000000000002'
      and v_row.account_status = 'suspended',
    'reservation returns a suspended demo account so the function can refuse it'
  );

  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000002');

  perform public.test_assert(
    (select account_status from public.profiles
      where id = 'c1000000-0000-0000-0000-000000000002') = 'suspended',
    'PIN activity never changes the account status'
  );
end;
$$;

-- 7. Lockout recovery clears the counter without rotating the PIN.
do $$
declare
  v_hash text;
  v_cleared boolean;
  i integer;
begin
  select pin_hash into v_hash
    from private.demo_access
   where user_id = 'c1000000-0000-0000-0000-000000000001';

  for i in 1..5 loop
    perform public.demo_login_reserve_attempt('+639170000017');
  end loop;
  perform public.test_assert(
    (select locked_until from private.demo_access
      where user_id = 'c1000000-0000-0000-0000-000000000001') > now(),
    'the account is locked before recovery'
  );

  v_cleared := public.demo_login_clear_lockout(
    'c1000000-0000-0000-0000-000000000001');
  perform public.test_assert(v_cleared, 'lockout recovery reports a cleared row');
  perform public.test_assert(
    (select failed_attempts = 0 and locked_until is null
       from private.demo_access
      where user_id = 'c1000000-0000-0000-0000-000000000001'),
    'lockout recovery clears the counter and window'
  );
  perform public.test_assert(
    (select pin_hash from private.demo_access
      where user_id = 'c1000000-0000-0000-0000-000000000001') = v_hash,
    'lockout recovery does not rotate the PIN'
  );

  v_cleared := public.demo_login_clear_lockout(
    'c1000000-0000-0000-0000-000000000009');
  perform public.test_assert(
    not v_cleared,
    'lockout recovery reports an unknown id as unchanged'
  );
end;
$$;

-- 8. Unknown ids are a no-op rather than an error.
do $$
begin
  perform public.demo_login_record_success(
    'c1000000-0000-0000-0000-000000000009');
  perform public.test_assert(true, 'success on an unknown id is a no-op');
end;
$$;

rollback;
