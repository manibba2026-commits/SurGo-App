begin;

-- Fixtures created as the database owner (bypasses RLS).
insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('b1000000-0000-0000-0000-000000000001', 'bea.admin@example.com',
   '+639180000301', '{"full_name":"Bea Admin"}'::jsonb),
  ('b1000000-0000-0000-0000-000000000002', 'ben.applicant@example.com',
   '+639180000302', '{"full_name":"Ben Applicant"}'::jsonb),
  ('b1000000-0000-0000-0000-000000000003', 'bela.other@example.com',
   '+639180000303', '{"full_name":"Bela Other"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('b1000000-0000-0000-0000-000000000001', 'admin', 'approved', now());

-- The applicant uploaded both files into their own folder; the other account
-- uploaded one into its own folder and must never reach the applicant's.
insert into storage.objects (bucket_id, name) values
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/dl.pdf'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/orcr.jpg'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/earner-dl.pdf'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/earner-ok.pdf'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000002/owner-orcr.pdf'),
  ('verification-documents',
   'b1000000-0000-0000-0000-000000000003/dl.pdf');

-- A draft waiting to be completed: the next submission must reuse it instead of
-- inserting a second open vehicle_owner application.
insert into public.verification_applications (
  id, profile_id, capability_type, status
) values (
  'b2000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000002', 'vehicle_owner', 'draft'
);

-- 1. The write path exists for authenticated and nobody else.
do $$
begin
  perform public.test_assert(
    not has_function_privilege(
      'anon', 'public.submit_verification_application(text,jsonb)', 'EXECUTE'
    ),
    'anon must not execute the submission function'
  );
  perform public.test_assert(
    has_function_privilege(
      'authenticated', 'public.submit_verification_application(text,jsonb)',
      'EXECUTE'
    ),
    'authenticated must be able to submit verification'
  );
end;
$$;

-- 2. A signed-in applicant submits two documents. The row lands as
--    'submitted' with pending documents and no role grant.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000002', true
);

select set_config(
  'surgo.test_application',
  public.submit_verification_application(
    'rider',
    '[{"document_type":"dl","label":"Driver license",
       "document_number":"DL-1",
       "storage_path":"b1000000-0000-0000-0000-000000000002/dl.pdf"},
      {"document_type":"orcr","label":"Vehicle OR/CR",
       "storage_path":"b1000000-0000-0000-0000-000000000002/orcr.jpg"}]'::jsonb
  )::text,
  true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_application')::uuid;
begin
  perform public.test_assert(v_id is not null, 'submission returns the application id');
  perform public.test_assert(
    (select status from public.verification_applications where id = v_id)
      = 'submitted',
    'a submission must land as submitted, never approved'
  );
  perform public.test_assert(
    (select submitted_at from public.verification_applications where id = v_id)
      is not null,
    'submitted_at is stamped by the server'
  );
  perform public.test_assert(
    (select count(*) from public.verification_documents
      where application_id = v_id and status = 'pending') = 2,
    'both documents are recorded as pending'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'rider' and status = 'approved') = 0,
    'submitting never grants the capability'
  );
  perform public.test_assert(
    (select profile_id from public.verification_applications where id = v_id)
      = 'b1000000-0000-0000-0000-000000000002',
    'the application is filed under the caller, not a parameter'
  );
end;
$$;

-- 3. A second submission while the first is waiting on a reviewer is refused.
do $$
declare
  v_refused boolean := false;
  v_message text := '';
begin
  begin
    perform public.submit_verification_application(
      'rider',
      '[{"document_type":"dl",
         "storage_path":"b1000000-0000-0000-0000-000000000002/dl.pdf"}]'::jsonb
    );
  exception
    when others then
      v_refused := true;
      v_message := sqlerrm;
  end;
  perform public.test_assert(
    v_refused, 'a submission already in review must be refused'
  );
  perform public.test_assert(
    v_message like '%already in review%',
    'the refusal names the review state, got: ' || v_message
  );
end;
$$;

reset role;

-- 4. The same statement run by another account cannot file a document under
--    the applicant's folder, and cannot read their application or files.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000003', true
);

do $$
declare
  v_refused boolean := false;
  v_message text := '';
  v_id uuid := current_setting('surgo.test_application')::uuid;
begin
  begin
    perform public.submit_verification_application(
      'rider',
      '[{"document_type":"dl",
         "storage_path":"b1000000-0000-0000-0000-000000000002/dl.pdf"}]'::jsonb
    );
  exception
    when others then
      v_refused := true;
      v_message := sqlerrm;
  end;
  perform public.test_assert(
    v_refused, 'another user''s storage path must be refused'
  );
  perform public.test_assert(
    v_message like '%not stored under your folder%',
    'the refusal names the ownership rule, got: ' || v_message
  );
  perform public.test_assert(
    (select count(*) from public.verification_applications where id = v_id) = 0,
    'RLS must hide another user''s application'
  );
  perform public.test_assert(
    (select count(*) from public.verification_documents
      where application_id = v_id) = 0,
    'RLS must hide another user''s documents'
  );
  perform public.test_assert(
    (select count(*) from storage.objects
      where bucket_id = 'verification-documents'
        and name like 'b1000000-0000-0000-0000-000000000002/%') = 0,
    'Storage must hide another user''s uploaded files'
  );
end;
$$;

reset role;

-- 5. An admin asks for a clearer scan. The applicant resubmits the same
--    application in place, and the decision fields are cleared for the next
--    reviewer.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', true
);

select public.admin_review_verification(
  current_setting('surgo.test_application')::uuid,
  'needs_resubmission',
  'Scan is blurry'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_application')::uuid;
  v_returned uuid;
begin
  perform public.test_assert(
    (select rejection_reason from public.verification_applications
      where id = v_id) = 'Scan is blurry',
    'the applicant can read the reviewer''s reason'
  );
  v_returned := public.submit_verification_application(
    'rider',
    '[{"document_type":"dl","label":"Driver license (retry)",
       "storage_path":"b1000000-0000-0000-0000-000000000002/dl.pdf"}]'::jsonb
  );
  perform public.test_assert(
    v_returned = v_id,
    'a resubmission reuses the open application instead of stacking a new one'
  );
  perform public.test_assert(
    (select status from public.verification_applications where id = v_id)
      = 'submitted',
    'the resubmitted application is back in review'
  );
  perform public.test_assert(
    (select rejection_reason from public.verification_applications
      where id = v_id) is null,
    'the old reason is cleared so it cannot be mistaken for the new decision'
  );
  perform public.test_assert(
    (select count(*) from public.verification_documents
      where application_id = v_id) = 1,
    'the document list is replaced by the resubmission'
  );
  perform public.test_assert(
    (select count(*) from public.verification_applications
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and capability_type = 'rider') = 1,
    'only one rider application exists for this profile'
  );
end;
$$;

reset role;

-- 6. Field validation: a submission that breaks a rule writes nothing, and a
--    valid one is normalised before it lands. Every refusal targets the draft
--    vehicle_owner application, so the draft also proves the write path is
--    transactional.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000002', true
);

do $$
declare
  v_case record;
  v_refused boolean;
  v_message text;
  v_draft uuid := 'b2000000-0000-0000-0000-000000000001';
begin
  for v_case in
    select * from (values
      ('a malformed expiry date',
       '[{"document_type":"dl",
          "storage_path":"b1000000-0000-0000-0000-000000000002/owner-orcr.pdf",
          "expires_at":"31/03/2027"}]'::jsonb,
       'invalid expiry date'),
      ('an impossible expiry date',
       '[{"document_type":"dl",
          "storage_path":"b1000000-0000-0000-0000-000000000002/owner-orcr.pdf",
          "expires_at":"2027-02-31"}]'::jsonb,
       'invalid expiry date'),
      ('an overlong label',
       jsonb_build_array(jsonb_build_object(
         'document_type', 'dl',
         'label', repeat('x', 121),
         'storage_path', 'b1000000-0000-0000-0000-000000000002/owner-orcr.pdf'
       )),
       'label is too long'),
      ('an overlong document number',
       jsonb_build_array(jsonb_build_object(
         'document_type', 'dl',
         'document_number', repeat('9', 61),
         'storage_path', 'b1000000-0000-0000-0000-000000000002/owner-orcr.pdf'
       )),
       'number is too long'),
      ('a path with a traversal segment',
       '[{"document_type":"dl",
          "storage_path":"b1000000-0000-0000-0000-000000000002/../dl.pdf"}]'::jsonb,
       'not stored under your folder'),
      ('a path in another account''s folder',
       '[{"document_type":"dl",
          "storage_path":"b1000000-0000-0000-0000-000000000003/dl.pdf"}]'::jsonb,
       'not stored under your folder'),
      ('a path that was never uploaded',
       '[{"document_type":"dl",
          "storage_path":"b1000000-0000-0000-0000-000000000002/missing.pdf"}]'::jsonb,
       'was not uploaded'),
      ('two spellings of the same document type',
       '[{"document_type":"DL",
          "storage_path":"b1000000-0000-0000-0000-000000000002/earner-dl.pdf"},
         {"document_type":" dl ",
          "storage_path":"b1000000-0000-0000-0000-000000000002/earner-ok.pdf"}]'::jsonb,
       'each document type may appear only once'),
      ('a document type with a space',
       '[{"document_type":"dl card",
          "storage_path":"b1000000-0000-0000-0000-000000000002/owner-orcr.pdf"}]'::jsonb,
       'document type must be')
    ) as t(why, documents, expected)
  loop
    v_refused := false;
    v_message := '';
    begin
      perform public.submit_verification_application(
        'vehicle_owner', v_case.documents
      );
      -- Reaching this line means the invalid payload was accepted; the
      -- assertion below then fails with the case name.
      raise exception 'accepted: %', v_case.why;
    exception
      when others then
        v_refused := true;
        v_message := sqlerrm;
    end;
    perform public.test_assert(
      v_refused and v_message not like 'accepted:%',
      v_case.why || ' must be refused'
    );
    perform public.test_assert(
      position(v_case.expected in v_message) > 0,
      v_case.why || ' was refused with an unexpected message: ' || v_message
    );
  end loop;

  perform public.test_assert(
    (select status from public.verification_applications where id = v_draft)
      = 'draft',
    'a refused submission leaves the open draft untouched'
  );
  perform public.test_assert(
    (select count(*) from public.verification_documents
      where application_id = v_draft) = 0,
    'a refused submission attaches no documents'
  );
end;
$$;

-- 7. A valid submission reuses the draft, normalises the text and parses the
--    date. Nothing is granted: the row still waits for a reviewer.
do $$
declare
  v_draft uuid := 'b2000000-0000-0000-0000-000000000001';
  v_returned uuid;
  v_doc record;
begin
  v_returned := public.submit_verification_application(
    'vehicle_owner',
    '[{"document_type":" DL ",
       "label":"  Vehicle DL  ",
       "document_number":"  N01-2027  ",
       "storage_path":" b1000000-0000-0000-0000-000000000002/owner-orcr.pdf ",
       "expires_at":" 2027-03-31 "}]'::jsonb
  );

  perform public.test_assert(
    v_returned = v_draft,
    'a submission completes the open draft instead of inserting a second row'
  );
  perform public.test_assert(
    (select status from public.verification_applications where id = v_draft)
      = 'submitted'
      and (select submitted_at from public.verification_applications
        where id = v_draft) is not null,
    'the reused draft moves to submitted with a fresh timestamp'
  );
  perform public.test_assert(
    (select count(*) from public.verification_applications
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and capability_type = 'vehicle_owner') = 1,
    'only one vehicle_owner application exists for this profile'
  );

  select * into v_doc
    from public.verification_documents
   where application_id = v_draft;
  perform public.test_assert(
    v_doc.document_type = 'dl',
    'the document type is stored lowercase and trimmed, got: ' || v_doc.document_type
  );
  perform public.test_assert(
    v_doc.label = 'Vehicle DL' and v_doc.document_number = 'N01-2027',
    'label and document number are trimmed'
  );
  perform public.test_assert(
    v_doc.storage_path
      = 'b1000000-0000-0000-0000-000000000002/owner-orcr.pdf',
    'the storage path is trimmed to the stored object name'
  );
  perform public.test_assert(
    v_doc.expires_at = date '2027-03-31',
    'the expiry date is parsed, not kept as text'
  );
  perform public.test_assert(
    v_doc.is_required and v_doc.status = 'pending',
    'a submitted document is required and starts pending'
  );
  perform public.test_assert(
    (select count(*) from public.user_roles
      where profile_id = 'b1000000-0000-0000-0000-000000000002'
        and role = 'vehicle_owner' and status = 'approved') = 0,
    'submitting never grants the capability'
  );
end;
$$;

reset role;

-- An applicant cannot read admin_audit_logs, so check the absence of an audit
-- row as the database owner after leaving the applicant's session.
do $$
begin
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where entity_id = 'b2000000-0000-0000-0000-000000000001') = 0,
    'an applicant submission writes no admin audit row'
  );
end;
$$;

rollback;
