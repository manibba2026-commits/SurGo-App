begin;

-- Admin account management: profile edits, role decisions, and
-- admin-managed verification/vehicle documents.
--
-- Fixtures are created as the database owner (bypasses RLS). The auth trigger
-- creates a profile and an approved passenger role for every auth user.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('b1000000-0000-0000-0000-000000000001', 'bea.admin@example.com',
   '+639180000301', '{"full_name":"Bea Admin"}'::jsonb),
  ('b1000000-0000-0000-0000-000000000002', 'mara.member@example.com',
   '+639180000302', '{"full_name":"Mara Member"}'::jsonb),
  ('b1000000-0000-0000-0000-000000000003', 'noel.other@example.com',
   '+639180000303', '{"full_name":"Noel Other"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('b1000000-0000-0000-0000-000000000001', 'admin', 'approved', now());

-- An earner draft proves admin_ensure_verification_application() reuses and
-- submits an existing open application instead of creating a duplicate.
insert into public.verification_applications (
  id, profile_id, capability_type, status
) values (
  'b2000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000002', 'earner', 'draft'
);

insert into public.vehicles (
  id, owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, status
) values (
  'b4000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000002',
  (select id from public.service_areas limit 1), 'Mara Multicab', 'tricycle',
  '3-Wheel', 'ACC 9001', 'pending_verification'
);

insert into storage.objects (bucket_id, name) values
  ('avatars', 'b1000000-0000-0000-0000-000000000002/me.png'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/dl.pdf'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/dl2.pdf'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/nbi.pdf'),
  ('vehicle-documents',
   'b1000000-0000-0000-0000-000000000002/franchise.pdf'),
  ('vehicle-documents',
   'b1000000-0000-0000-0000-000000000002/franchise2.pdf');

-- 1. EXECUTE boundary of the account-management RPCs.
do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.admin_update_profile(uuid,text,text,text,text)',
    'public.admin_set_avatar(uuid,text)',
    'public.admin_update_profile_contact(uuid,text,text)',
    'public.admin_set_user_role(uuid,text,text,text)',
    'public.admin_ensure_verification_application(uuid,text)',
    'public.admin_attach_verification_document(uuid,text,text,text,text,date)',
    'public.admin_detach_verification_document(uuid)',
    'public.admin_attach_vehicle_document(uuid,text,text,text,date)',
    'public.admin_detach_vehicle_document(uuid)'
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
  end loop;

  perform public.test_assert(
    (select proconfig from pg_proc
      where oid = 'public.admin_set_user_role(uuid,text,text,text)'::regprocedure)
      @> array['search_path=""'],
    'admin_set_user_role must pin search_path'
  );
  perform public.test_assert(
    (select proconfig from pg_proc
      where oid = 'public.admin_attach_verification_document(uuid,text,text,text,text,date)'::regprocedure)
      @> array['search_path=""'],
    'admin_attach_verification_document must pin search_path'
  );

  perform public.test_assert(
    (select count(*) from pg_policies
      where schemaname = 'storage'
        and policyname in (
          'surgo admin insert documents',
          'surgo admin update documents',
          'surgo admin delete documents'
        )) = 3,
    'admins get their own storage write policies'
  );
end;
$$;

-- 2. A signed-in non-admin cannot use any account-management path or write
--    into another account's storage folder.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000002', true
);

do $$
begin
  begin
    perform public.admin_update_profile(
      'b1000000-0000-0000-0000-000000000002', 'Hijacked Name'
    );
    raise exception 'a non-admin must not edit a profile';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_set_avatar(
      'b1000000-0000-0000-0000-000000000002',
      'b1000000-0000-0000-0000-000000000002/me.png'
    );
    raise exception 'a non-admin must not change an avatar';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_update_profile_contact(
      'b1000000-0000-0000-0000-000000000002', 'evil@example.com', null
    );
    raise exception 'a non-admin must not change contact details';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_set_user_role(
      'b1000000-0000-0000-0000-000000000002', 'rider', 'approved'
    );
    raise exception 'a non-admin must not grant a role';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_ensure_verification_application(
      'b1000000-0000-0000-0000-000000000002', 'rider'
    );
    raise exception 'a non-admin must not open an application';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_attach_verification_document(
      'b2000000-0000-0000-0000-000000000001', 'valid_id', null,
      'b1000000-0000-0000-0000-000000000002/dl.pdf'
    );
    raise exception 'a non-admin must not attach a document';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_detach_verification_document(
      'b3000000-0000-0000-0000-000000000001'
    );
    raise exception 'a non-admin must not remove a document';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_attach_vehicle_document(
      'b4000000-0000-0000-0000-000000000001', 'franchise',
      'b1000000-0000-0000-0000-000000000002/franchise.pdf'
    );
    raise exception 'a non-admin must not attach a vehicle document';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_detach_vehicle_document(
      'b5000000-0000-0000-0000-000000000001'
    );
    raise exception 'a non-admin must not remove a vehicle document';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into storage.objects (bucket_id, name)
    values ('avatars', 'b1000000-0000-0000-0000-000000000001/evil.png');
    raise exception 'a non-admin must not write another account''s folder';
  exception when insufficient_privilege then null;
  end;

  perform public.test_assert(
    (select full_name from public.profiles
      where id = 'b1000000-0000-0000-0000-000000000002') = 'Mara Member',
    'denied calls leave the profile untouched'
  );
end;
$$;

reset role;

do $$
begin
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs) = 0,
    'denied calls leave no audit rows'
  );
end;
$$;

-- 3. Profile detail edits, including the avatar folder and object checks.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', true
);

do $$
declare
  v_avatar text;
begin
  -- The admin storage policy lets an administrator upload into another
  -- account's folder; the per-user policy alone would refuse this.
  insert into storage.objects (bucket_id, name) values
    ('avatars', 'b1000000-0000-0000-0000-000000000002/admin.png'),
    ('avatars', 'b1000000-0000-0000-0000-000000000009/me.png'),
    ('verification-documents',
     'b1000000-0000-0000-0000-000000000002/admin-upload.pdf');

  begin
    perform public.admin_update_profile(
      'b1000000-0000-0000-0000-000000000002', '   '
    );
    raise exception 'a blank full name must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_update_profile(
      'b1000000-0000-0000-0000-000000000009', 'Ghost User'
    );
    raise exception 'an unknown profile must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_set_avatar(
      'b1000000-0000-0000-0000-000000000002',
      'b1000000-0000-0000-0000-000000000003/me.png'
    );
    raise exception 'an avatar outside the account folder must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_set_avatar(
      'b1000000-0000-0000-0000-000000000002',
      'b1000000-0000-0000-0000-000000000002/../evil.png'
    );
    raise exception 'an avatar path with traversal must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_set_avatar(
      'b1000000-0000-0000-0000-000000000002',
      'b1000000-0000-0000-0000-000000000002/missing.png'
    );
    raise exception 'an avatar object that is not stored must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_set_avatar(
      'b1000000-0000-0000-0000-000000000009',
      'b1000000-0000-0000-0000-000000000009/me.png'
    );
    raise exception 'an avatar for an unknown profile must fail';
  exception when raise_exception then null;
  end;

  perform public.admin_update_profile(
    'b1000000-0000-0000-0000-000000000002',
    '  Mara Santos  ', '  Mara  ',
    '  12 Mabini Street  ', '  Poblacion  '
  );
  perform public.admin_set_avatar(
    'b1000000-0000-0000-0000-000000000002',
    'b1000000-0000-0000-0000-000000000002/admin.png'
  );

  perform public.test_assert(
    (select full_name = 'Mara Santos'
        and first_name = 'Mara'
        and address = '12 Mabini Street'
        and barangay = 'Poblacion'
        and avatar_path = 'b1000000-0000-0000-0000-000000000002/admin.png'
       from public.profiles
      where id = 'b1000000-0000-0000-0000-000000000002'),
    'profile edits store trimmed values and the new detail fields'
  );

  -- Editing details must not touch the photo, and clearing the photo must not
  -- touch the details.
  perform public.admin_update_profile(
    'b1000000-0000-0000-0000-000000000002',
    'Mara Santos', null, '   ', null
  );
  perform public.test_assert(
    (select first_name is null and address is null
        and avatar_path = 'b1000000-0000-0000-0000-000000000002/admin.png'
       from public.profiles
      where id = 'b1000000-0000-0000-0000-000000000002'),
    'blank optional fields clear without dropping the avatar'
  );
  perform public.admin_set_avatar(
    'b1000000-0000-0000-0000-000000000002', null
  );
  perform public.test_assert(
    (select full_name = 'Mara Santos' and barangay = 'Poblacion'
        and avatar_path is null
       from public.profiles
      where id = 'b1000000-0000-0000-0000-000000000002'),
    'removing the avatar keeps the other profile details'
  );
end;
$$;

-- 3b. Contact details are validated here even though the auth identity is
--     changed by the Admin API route before this function is called.
do $$
begin
  begin
    perform public.admin_update_profile_contact(
      'b1000000-0000-0000-0000-000000000002', 'not-an-email', null
    );
    raise exception 'an invalid email must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_update_profile_contact(
      'b1000000-0000-0000-0000-000000000002', '   ', '   '
    );
    raise exception 'empty contact details must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_update_profile_contact(
      'b1000000-0000-0000-0000-000000000002', null, 'abc'
    );
    raise exception 'an invalid phone number must fail';
  exception when sqlstate '22023' then null;
  end;

  perform public.admin_update_profile_contact(
    'b1000000-0000-0000-0000-000000000002', '  Mara.Santos@Example.com  ', '+639180000999'
  );
  perform public.test_assert(
    (select email = 'mara.santos@example.com' and phone = '+639180000999'
       from public.profiles where id = 'b1000000-0000-0000-0000-000000000002'),
    'contact details are normalized and stored'
  );

  begin
    perform public.admin_update_profile_contact(
      'b1000000-0000-0000-0000-000000000002', 'bea.admin@example.com', null
    );
    raise exception 'a duplicate email must fail';
  exception when unique_violation then null;
  end;

  perform public.test_assert(
    (select email from public.profiles
      where id = 'b1000000-0000-0000-0000-000000000002') = 'mara.santos@example.com',
    'a rejected duplicate leaves the stored email untouched'
  );
end;
$$;

-- 4. Helper (earner) role decisions and application reuse.
do $$
declare
  v_app uuid;
  v_count integer;
begin
  begin
    perform public.admin_set_user_role(
      'b1000000-0000-0000-0000-000000000002', 'admin', 'approved'
    );
    raise exception 'the admin role must not be assignable here';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_set_user_role(
      'b1000000-0000-0000-0000-000000000002', 'earner', 'promoted'
    );
    raise exception 'an unknown role status must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_set_user_role(
      'b1000000-0000-0000-0000-000000000009', 'earner', 'pending'
    );
    raise exception 'an unknown profile must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_ensure_verification_application(
      'b1000000-0000-0000-0000-000000000002', 'admin'
    );
    raise exception 'an invalid capability must fail';
  exception when sqlstate '22023' then null;
  end;

  -- The fixture draft must be submitted, not duplicated.
  v_app := public.admin_ensure_verification_application(
    'b1000000-0000-0000-0000-000000000002', 'earner'
  );
  perform public.test_assert(
    v_app = 'b2000000-0000-0000-0000-000000000001',
    'ensure reuses the existing open application'
  );
  perform public.test_assert(
    (select status from public.verification_applications where id = v_app)
      = 'submitted',
    'a draft is submitted when an admin reopens it'
  );
  select count(*) into v_count from public.verification_applications
   where profile_id = 'b1000000-0000-0000-0000-000000000002'
     and capability_type = 'earner';
  perform public.test_assert(
    v_count = 1, 'ensure does not create a duplicate application'
  );

  perform public.admin_set_user_role(
    'b1000000-0000-0000-0000-000000000002', 'earner', 'pending',
    'Uploading documents'
  );
  perform public.test_assert(
    (select status from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'earner') = 'pending',
    'an admin can park the Helper role as pending'
  );
  perform public.test_assert(
    (select approved_at is null from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'earner'),
    'a pending role carries no approval timestamp'
  );

  perform public.admin_set_user_role(
    'b1000000-0000-0000-0000-000000000002', 'earner', 'approved'
  );
  perform public.test_assert(
    (select status = 'approved'
        and approved_at is not null
        and approved_by = 'b1000000-0000-0000-0000-000000000001'
       from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'earner'),
    'an admin approval records the reviewer'
  );

  begin
    perform public.admin_ensure_verification_application(
      'b1000000-0000-0000-0000-000000000002', 'earner'
    );
    raise exception 'an already approved capability must not reopen an application';
  exception when sqlstate '22023' then null;
  end;
end;
$$;

-- 5. Rider approval is gated on a reviewed application. Documents can be
--    attached, replaced, removed, and then reviewed into a passing state.
do $$
declare
  v_app uuid;
  v_doc uuid;
begin
  v_app := public.admin_ensure_verification_application(
    'b1000000-0000-0000-0000-000000000002', 'rider'
  );

  begin
    perform public.admin_set_user_role(
      'b1000000-0000-0000-0000-000000000002', 'rider', 'approved'
    );
    raise exception 'rider approval without an approved application must fail';
  exception when sqlstate '22023' then null;
  end;
  perform public.test_assert(
    not exists (
      select 1 from public.user_roles
       where profile_id = 'b1000000-0000-0000-0000-000000000002'
         and role = 'rider'
    ),
    'a blocked rider approval grants no role'
  );

  begin
    perform public.admin_attach_verification_document(
      v_app, 'drivers_license', null,
      'b1000000-0000-0000-0000-000000000003/dl.pdf'
    );
    raise exception 'a document outside the account folder must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_attach_verification_document(
      v_app, 'drivers_license', null,
      'b1000000-0000-0000-0000-000000000002/missing.pdf'
    );
    raise exception 'a document that is not stored must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_attach_verification_document(
      v_app, repeat('x', 81), null,
      'b1000000-0000-0000-0000-000000000002/dl.pdf'
    );
    raise exception 'an overlong document type must fail';
  exception when sqlstate '22023' then null;
  end;

  perform public.admin_attach_verification_document(
    v_app, ' drivers_license ', '  License  ', 'b1000000-0000-0000-0000-000000000002/dl.pdf',
    '  DL-777  ', date '2030-01-31'
  );
  perform public.test_assert(
    (select status = 'pending'
        and document_type = 'drivers_license'
        and label = 'License'
        and document_number = 'DL-777'
        and storage_path = 'b1000000-0000-0000-0000-000000000002/dl.pdf'
       from public.verification_documents
      where application_id = v_app and document_type = 'drivers_license'),
    'an attached document is stored as pending with trimmed values'
  );

  perform public.admin_attach_verification_document(
    v_app, 'nbi_clearance', 'NBI', 'b1000000-0000-0000-0000-000000000002/nbi.pdf'
  );

  -- Review the first file, then replace it: replacement must go back to
  -- pending so the new file cannot ride on the old approval.
  select id into v_doc from public.verification_documents
   where application_id = v_app and document_type = 'drivers_license';
  perform public.admin_review_document('verification', v_doc, 'approved');
  perform public.test_assert(
    (select status from public.verification_documents where id = v_doc)
      = 'approved',
    'the first license file is approved'
  );

  perform public.admin_attach_verification_document(
    v_app, 'drivers_license', 'License', 'b1000000-0000-0000-0000-000000000002/dl2.pdf'
  );
  perform public.test_assert(
    (select status = 'pending'
        and reviewed_by is null
        and reviewed_at is null
        and rejection_reason is null
       from public.verification_documents
      where application_id = v_app and document_type = 'drivers_license'),
    'replacing a document resets it to unreviewed pending'
  );

  -- The application cannot be approved while the replaced file is pending.
  begin
    perform public.admin_review_verification(v_app, 'approved');
    raise exception 'an application with a pending document must not be approved';
  exception when sqlstate '22023' then null;
  end;

  perform public.admin_review_document('verification', v_doc, 'approved');
  select id into v_doc from public.verification_documents
   where application_id = v_app and document_type = 'nbi_clearance';
  perform public.admin_review_document('verification', v_doc, 'approved');
  perform public.admin_review_verification(v_app, 'approved');

  perform public.test_assert(
    (select count(*) from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'rider' and status = 'approved') = 1,
    'the reviewed application grants the rider role once'
  );

  -- With the review complete, the explicit role paths now pass, and repeat
  -- decisions stay idempotent.
  perform public.admin_set_user_role(
    'b1000000-0000-0000-0000-000000000002', 'rider', 'approved'
  );
  perform public.admin_set_user_role(
    'b1000000-0000-0000-0000-000000000002', 'rider', 'revoked',
    'Complaint under review'
  );
  perform public.test_assert(
    (select status = 'revoked' and approved_at is null
       from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'rider'),
    'revoking a role clears its approval timestamp'
  );
  perform public.admin_set_user_role(
    'b1000000-0000-0000-0000-000000000002', 'rider', 'approved'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'rider') = 1,
    'role decisions never duplicate the row'
  );

  perform public.admin_set_user_role(
    'b1000000-0000-0000-0000-000000000002', 'earner', 'suspended',
    'Awaiting follow-up'
  );
  perform public.test_assert(
    (select status from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'earner') = 'suspended',
    'an admin can suspend a role'
  );
end;
$$;

-- 6. Vehicle documents validate the owner folder and reset on replacement.
do $$
declare
  v_doc uuid;
begin
  begin
    perform public.admin_attach_vehicle_document(
      'b4000000-0000-0000-0000-000000000001', 'franchise',
      'b1000000-0000-0000-0000-000000000003/franchise.pdf'
    );
    raise exception 'a vehicle document outside the owner folder must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_attach_vehicle_document(
      'b4000000-0000-0000-0000-000000000001', 'franchise',
      'b1000000-0000-0000-0000-000000000002/missing.pdf'
    );
    raise exception 'a vehicle document that is not stored must fail';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.admin_attach_vehicle_document(
      'b4000000-0000-0000-0000-000000000009', 'franchise',
      'b1000000-0000-0000-0000-000000000002/franchise.pdf'
    );
    raise exception 'an unknown vehicle must fail';
  exception when raise_exception then null;
  end;

  perform public.admin_attach_vehicle_document(
    'b4000000-0000-0000-0000-000000000001', 'franchise',
    'b1000000-0000-0000-0000-000000000002/franchise.pdf', ' FR-1 ', date '2031-06-30'
  );
  select id into v_doc from public.vehicle_documents
   where vehicle_id = 'b4000000-0000-0000-0000-000000000001'
     and document_type = 'franchise';
  perform public.test_assert(
    (select status = 'pending' and document_number = 'FR-1'
       from public.vehicle_documents where id = v_doc),
    'a vehicle document starts pending with trimmed values'
  );

  perform public.admin_review_document('vehicle', v_doc, 'approved');
  perform public.admin_attach_vehicle_document(
    'b4000000-0000-0000-0000-000000000001', 'franchise',
    'b1000000-0000-0000-0000-000000000002/franchise2.pdf'
  );
  perform public.test_assert(
    (select status = 'pending' and reviewed_by is null and reviewed_at is null
       from public.vehicle_documents where id = v_doc),
    'replacing a vehicle document resets the review state'
  );
end;
$$;

-- 7. Decided applications and their files are locked.
do $$
declare
  v_app uuid;
  v_doc uuid;
begin
  select id into v_app from public.verification_applications
   where profile_id = 'b1000000-0000-0000-0000-000000000002'
     and capability_type = 'rider' and status = 'approved';
  select id into v_doc from public.verification_documents
   where application_id = v_app and document_type = 'drivers_license';

  begin
    perform public.admin_attach_verification_document(
      v_app, 'police_clearance', 'Clearance',
      'b1000000-0000-0000-0000-000000000002/nbi.pdf'
    );
    raise exception 'a decided application must not accept new documents';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_detach_verification_document(v_doc);
    raise exception 'a decided application must not lose its documents';
  exception when raise_exception then null;
  end;

  perform public.test_assert(
    (select status from public.verification_documents where id = v_doc)
      = 'approved',
    'locked documents keep their approved status'
  );

  -- Removing a document is allowed while the application is still open.
  v_app := public.admin_ensure_verification_application(
    'b1000000-0000-0000-0000-000000000002', 'vehicle_owner'
  );
  perform public.admin_attach_verification_document(
    v_app, 'valid_id', 'Government ID',
    'b1000000-0000-0000-0000-000000000002/admin-upload.pdf'
  );
  select id into v_doc from public.verification_documents
   where application_id = v_app and document_type = 'valid_id';
  perform public.admin_detach_verification_document(v_doc);
  perform public.test_assert(
    not exists (select 1 from public.verification_documents where id = v_doc),
    'an admin can remove a document from an open application'
  );
end;
$$;

-- 8. Vehicle document removal.
do $$
declare
  v_doc uuid;
begin
  select id into v_doc from public.vehicle_documents
   where vehicle_id = 'b4000000-0000-0000-0000-000000000001'
     and document_type = 'franchise';
  perform public.admin_detach_vehicle_document(v_doc);
  perform public.test_assert(
    not exists (select 1 from public.vehicle_documents where id = v_doc),
    'an admin can remove a vehicle document'
  );
  begin
    perform public.admin_detach_vehicle_document(v_doc);
    raise exception 'removing an unknown vehicle document must fail';
  exception when raise_exception then null;
  end;
end;
$$;

reset role;

-- 9. The audit trail names an actor for every write.
do $$
begin
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs where actor_id is null) = 0,
    'every account-management audit row names its actor'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'role.approved') = 3
      and (select count(*) from public.admin_audit_logs
        where action = 'role.pending') = 1
      and (select count(*) from public.admin_audit_logs
        where action = 'role.revoked') = 1
      and (select count(*) from public.admin_audit_logs
        where action = 'role.suspended') = 1,
    'each role decision writes one audit row'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'verification.created') = 2
      and (select count(*) from public.admin_audit_logs
        where action = 'verification.reopened') = 1,
    'application creation and reopening are audited'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'profile.updated') = 2
      and (select count(*) from public.admin_audit_logs
        where action = 'profile.updated'
          and after_state ->> 'barangay' = 'Poblacion') = 1,
    'each profile edit writes one audit row with the edited details'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'profile.avatar_updated') = 2
      and (select count(*) from public.admin_audit_logs
        where action = 'profile.contact_updated'
          and after_state ->> 'email' = 'mara.santos@example.com') = 1,
    'avatar and contact changes are audited'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'document.attached') = 3
      and (select count(*) from public.admin_audit_logs
        where action = 'document.replaced') = 1
      and (select count(*) from public.admin_audit_logs
        where action = 'document.removed') = 1,
    'verification document attach, replace and remove are audited'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'vehicle_document.attached') = 1
      and (select count(*) from public.admin_audit_logs
        where action = 'vehicle_document.replaced') = 1
      and (select count(*) from public.admin_audit_logs
        where action = 'vehicle_document.removed') = 1,
    'vehicle document attach, replace and remove are audited'
  );
end;
$$;

rollback;
