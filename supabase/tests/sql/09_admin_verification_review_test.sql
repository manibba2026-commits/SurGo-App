begin;

-- Fixtures created as the database owner (bypasses RLS).
insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('a1000000-0000-0000-0000-000000000001', 'ada.admin@example.com',
   '+639180000201', '{"full_name":"Ada Admin"}'::jsonb),
  ('a1000000-0000-0000-0000-000000000002', 'ravi.apply@example.com',
   '+639180000202', '{"full_name":"Ravi Applicant"}'::jsonb),
  ('a1000000-0000-0000-0000-000000000003', 'oren.other@example.com',
   '+639180000203', '{"full_name":"Oren Other"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('a1000000-0000-0000-0000-000000000001', 'admin', 'approved', now());

-- One rider application with two documents: the first has a stored file, the
-- second points at a storage_path that was never uploaded. The dashboard has
-- to render that difference honestly.
insert into public.verification_applications (
  id, profile_id, capability_type, status, submitted_at
) values
  ('a2000000-0000-0000-0000-000000000001',
   'a1000000-0000-0000-0000-000000000002', 'rider', 'submitted', now()),
  ('a2000000-0000-0000-0000-000000000002',
   'a1000000-0000-0000-0000-000000000002', 'earner', 'under_review', now());

insert into public.verification_documents (
  id, application_id, document_type, label, document_number,
  storage_path, expires_at
) values
  ('a3000000-0000-0000-0000-000000000001',
   'a2000000-0000-0000-0000-000000000001', 'drivers_license',
   'Driver''s license', 'DL-90012',
   'a1000000-0000-0000-0000-000000000002/dl.pdf', date '2030-01-31'),
  ('a3000000-0000-0000-0000-000000000002',
   'a2000000-0000-0000-0000-000000000001', 'certificate_of_ownership',
   'COC', null, 'a1000000-0000-0000-0000-000000000002/gone.pdf', null),
  ('a3000000-0000-0000-0000-000000000003',
   'a2000000-0000-0000-0000-000000000002', 'tax_identification',
   'TIN', 'TIN-4', null, null);

insert into public.vehicles (
  id, owner_profile_id, service_area_id, name, vehicle_type, category,
  plate_number, status
) values (
  'a4000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000002',
  (select id from public.service_areas), 'Ravi Multicab', 'tricycle',
  '3-Wheel', 'VER 9001', 'pending_verification'
);

insert into public.vehicle_documents (
  id, vehicle_id, document_type, document_number, storage_path
) values (
  'a5000000-0000-0000-0000-000000000001',
  'a4000000-0000-0000-0000-000000000001', 'franchise', 'FR-9',
  'a1000000-0000-0000-0000-000000000002/franchise.pdf'
);

-- Only two of the three referenced files actually exist in Storage.
insert into storage.objects (bucket_id, name) values
  ('verification-documents',
   'a1000000-0000-0000-0000-000000000002/dl.pdf'),
  ('vehicle-documents',
   'a1000000-0000-0000-0000-000000000002/franchise.pdf');

-- 1. EXECUTE boundary of the dashboard RPCs.
do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.is_admin()',
    'public.admin_review_verification(uuid,text,text)',
    'public.admin_review_document(text,uuid,text,text)',
    'public.admin_set_account_status(uuid,text,text)',
    'public.admin_set_vehicle_status(uuid,text,text)',
    'public.admin_update_remittance(uuid,text,text,text)',
    'public.admin_overview()',
    'public.admin_daily_activity(int)'
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

  foreach v_sig in array array[
    'public._admin_audit(text,text,uuid,jsonb,jsonb)'
  ]
  loop
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE'),
      'anon must not execute the internal audit helper'
    );
    perform public.test_assert(
      not has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      'an admin must not write the audit log directly'
    );
  end loop;

  perform public.test_assert(
    (select proconfig from pg_proc
      where oid = 'public.admin_review_verification(uuid,text,text)'::regprocedure)
      @> array['search_path=""'],
    'admin_review_verification must pin search_path'
  );
end;
$$;

-- 2. Reading a document list is bucket-scoped and admin-only for other people.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000002', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.verification_applications) = 2,
    'an applicant sees their own applications'
  );
  perform public.test_assert(
    (select count(*) from storage.objects) = 2,
    'a user lists only their own storage folder'
  );
end;
$$;

-- 3. A signed-in user who is not an admin cannot review anything.
do $$
begin
  begin
    perform public.admin_review_verification(
      'a2000000-0000-0000-0000-000000000001', 'approved'
    );
    raise exception 'a non-admin must not approve an application';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_review_document(
      'verification', 'a3000000-0000-0000-0000-000000000001', 'approved'
    );
    raise exception 'a non-admin must not approve a document';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.admin_overview();
    raise exception 'a non-admin must not read the overview aggregate';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public._admin_audit(
      'hand_written', 'profile', auth.uid(), null, null
    );
    raise exception 'the audit helper must not be callable directly';
  exception when insufficient_privilege then null;
  end;

  perform public.test_assert(
    not public.is_admin(),
    'is_admin() is false for an approved passenger'
  );
end;
$$;

reset role;

do $$
begin
  perform public.test_assert(
    (select status from public.verification_applications
      where id = 'a2000000-0000-0000-0000-000000000001') = 'submitted',
    'a rejected call must not change the application'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs) = 0,
    'a denied call must not leave an audit row'
  );
end;
$$;

-- 4. Admin reads are not limited to their own rows, including document buckets.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
begin
  perform public.test_assert(
    public.is_admin(), 'is_admin() is true for an approved admin'
  );
  perform public.test_assert(
    (select count(*) from public.verification_applications) = 2,
    'an admin sees every application'
  );
  perform public.test_assert(
    (select count(*) from storage.objects
      where bucket_id in ('verification-documents', 'vehicle-documents')) = 2,
    'an admin lists document files from other people''s folders'
  );

  -- What the dashboard asks when it decides between a preview and
  -- "No file on record": one referenced path, no stored object.
  perform public.test_assert(
    (select count(*)
       from public.verification_documents d
       left join storage.objects o
         on o.bucket_id = 'verification-documents'
        and o.name = d.storage_path
      where d.storage_path is not null
        and o.name is null) = 1,
    'exactly one verification document is missing its file'
  );
end;
$$;

-- 5. Document review, including the reason rule.
do $$
begin
  begin
    perform public.admin_review_document(
      'verification', 'a3000000-0000-0000-0000-000000000002', 'rejected'
    );
    raise exception 'rejecting a document without a reason must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_review_document(
      'verification', 'a3000000-0000-0000-0000-000000000002', 'deleted'
    );
    raise exception 'an unknown decision must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_review_document(
      'passport', 'a3000000-0000-0000-0000-000000000002', 'approved'
    );
    raise exception 'an unknown document kind must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_review_document(
      'verification', 'a3000000-0000-0000-0000-000000000009', 'approved'
    );
    raise exception 'an unknown document id must fail';
  exception when raise_exception then null;
  end;

  perform public.admin_review_document(
    'verification', 'a3000000-0000-0000-0000-000000000001', 'approved'
  );
  perform public.admin_review_document(
    'verification', 'a3000000-0000-0000-0000-000000000002', 'rejected',
    'Photo is unreadable'
  );
  perform public.admin_review_document(
    'vehicle', 'a5000000-0000-0000-0000-000000000001', 'approved'
  );
end;
$$;

reset role;

do $$
declare
  v_doc record;
  v_roles integer;
begin
  select status, reviewed_by, reviewed_at, rejection_reason into v_doc
    from public.verification_documents
   where id = 'a3000000-0000-0000-0000-000000000001';
  perform public.test_assert(
    v_doc.status = 'approved'
      and v_doc.reviewed_by = 'a1000000-0000-0000-0000-000000000001'
      and v_doc.reviewed_at is not null
      and v_doc.rejection_reason is null,
    'approved document must record the reviewer and clear the reason'
  );

  select status, rejection_reason into v_doc
    from public.verification_documents
   where id = 'a3000000-0000-0000-0000-000000000002';
  perform public.test_assert(
    v_doc.status = 'rejected' and v_doc.rejection_reason = 'Photo is unreadable',
    'rejected document must keep the reason'
  );

  select status, reviewed_by into v_doc
    from public.vehicle_documents
   where id = 'a5000000-0000-0000-0000-000000000001';
  perform public.test_assert(
    v_doc.status = 'approved'
      and v_doc.reviewed_by = 'a1000000-0000-0000-0000-000000000001',
    'vehicle documents go through the same reviewed path'
  );

  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'document.approved') = 2,
    'each approved document writes one audit row'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'document.rejected'
        and after_state ->> 'reason' = 'Photo is unreadable') = 1,
    'a rejected document audits the reason'
  );
end;
$$;

-- 6. Application decisions, role granting and the reviewable-status rule.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
begin
  begin
    perform public.admin_review_verification(
      'a2000000-0000-0000-0000-000000000001', 'needs_resubmission'
    );
    raise exception 'resubmission without a reason must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_review_verification(
      'a2000000-0000-0000-0000-000000000001', 'promoted'
    );
    raise exception 'an unknown decision must fail';
  exception when raise_exception then null;
  end;

  begin
    perform public.admin_review_verification(
      'a2000000-0000-0000-0000-000000000009', 'approved'
    );
    raise exception 'an unknown application must fail';
  exception when raise_exception then null;
  end;

  perform public.admin_review_verification(
    'a2000000-0000-0000-0000-000000000002', 'needs_resubmission',
    'Add the LTFRB franchise'
  );
  perform public.test_assert(
    (select status from public.verification_applications
      where id = 'a2000000-0000-0000-0000-000000000002')::text
      = 'needs_resubmission',
    'a needs_resubmission decision is stored'
  );
  perform public.test_assert(
    not exists (
      select 1 from public.user_roles
       where profile_id = 'a1000000-0000-0000-0000-000000000002'
         and role = 'earner'
    ),
    'a resubmission request grants no role'
  );

  -- A resubmission request stays reviewable, so the approve path is still open.
  perform public.admin_review_verification(
    'a2000000-0000-0000-0000-000000000002', 'approved'
  );
  perform public.admin_review_verification(
    'a2000000-0000-0000-0000-000000000001', 'approved'
  );

  begin
    perform public.admin_review_verification(
      'a2000000-0000-0000-0000-000000000001', 'rejected', 'Changed his mind'
    );
    raise exception 'a decided application must not be reviewable again';
  exception when raise_exception then null;
  end;
end;
$$;

reset role;

do $$
declare
  v_roles integer;
begin
  perform public.test_assert(
    (select status from public.verification_applications
      where id = 'a2000000-0000-0000-0000-000000000001')::text = 'approved'
      and (select decided_at from public.verification_applications
        where id = 'a2000000-0000-0000-0000-000000000001') is not null
      and (select rejection_reason from public.verification_applications
        where id = 'a2000000-0000-0000-0000-000000000001') is null,
    'approval clears the reason and stamps the decision'
  );

  -- The trigger already granted a passenger role, so approving a rider
  -- application must leave exactly one rider row, not a duplicate.
  select count(*) into v_roles from public.user_roles
   where profile_id = 'a1000000-0000-0000-0000-000000000002'
     and role = 'rider' and status = 'approved';
  perform public.test_assert(
    v_roles = 1, 'approving an application grants the role exactly once'
  );

  perform public.test_assert(
    (select approved_by from public.user_roles
      where profile_id = 'a1000000-0000-0000-0000-000000000002'
        and role = 'earner') = 'a1000000-0000-0000-0000-000000000001',
    'the granting admin is recorded on the role'
  );

  perform public.test_assert(
    (select count(*) from public.user_roles
      where profile_id = 'a1000000-0000-0000-0000-000000000002'
        and role = 'passenger') = 1,
    'granting a provider role must not touch the passenger role'
  );

  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'verification.approved') = 2,
    'each application approval writes one audit row'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'verification.needs_resubmission'
        and after_state ->> 'reason' = 'Add the LTFRB franchise') = 1,
    'a resubmission audits the reason'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs where actor_id is null) = 0,
    'every audit row names its actor'
  );
end;
$$;

-- 7. The aggregates the dashboard reads stay available after a reset.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true
);

do $$
begin
  perform public.test_assert(
    (select public.admin_overview() ->> 'verifications_pending')::int = 0,
    'both applications are decided, so nothing is pending'
  );
  perform public.test_assert(
    (select public.admin_overview() ->> 'vehicle_docs_pending')::int = 0,
    'the reviewed franchise is no longer pending'
  );
  perform public.test_assert(
    (select count(*) from public.admin_daily_activity(7)) = 7,
    'the daily activity aggregate returns one row per day'
  );
end;
$$;

reset role;

rollback;
