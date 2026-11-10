-- Verification review integrity.
--
-- Closes the gaps found in the pre-deployment audit:
--   1. An application could be approved while a document was still pending,
--      rejected or expired. Approval now requires every attached document to be
--      approved, inside the database.
--   2. Documents of an already-decided application could still be reviewed,
--      leaving an approved application pointing at a rejected file. Document
--      review is now only allowed while the application is open.
--   3. The submission RPC accepted unbounded label/number/path text, malformed
--      dates and paths with traversal segments. It now validates and normalises
--      every field before writing anything.
--   4. Two simultaneous first submissions could race past the "select for
--      update" and surface a raw 23505. The insert now uses the partial unique
--      index with ON CONFLICT DO NOTHING and re-reads the winning row.
--
-- Still no applicant path can grant a role: only admin_review_verification()
-- writes user_roles, and only after the document gate passes.
--
-- Known limitation (not fixed here): the Flutter client uploads files before
-- calling the RPC, so a refused submission can leave orphaned private objects.
-- Deleting them client-side would be unsafe (the RPC may have committed before
-- a network failure) and needs a separate service-role cleanup job. Track that
-- as an operational task rather than an unsafe workaround.

-- 1. Applicant submission: validation, normalisation, race-safe upsert -----

create or replace function public.submit_verification_application(
  p_capability text,
  p_documents jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_capability public.user_role_type;
  v_application_id uuid;
  v_status public.verification_status;
  v_document jsonb;
  v_type text;
  v_path text;
  v_expires text;
  v_expires_date date;
  v_types text[];
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  if p_capability is null
     or p_capability not in ('earner', 'rider', 'vehicle_owner') then
    raise exception 'invalid capability' using errcode = '22023';
  end if;
  v_capability := p_capability::public.user_role_type;

  if not exists (
    select 1
      from public.profiles
     where id = v_uid
       and account_status = 'active'
  ) then
    raise exception 'only an active account can submit verification'
      using errcode = '42501';
  end if;

  if exists (
    select 1
      from public.user_roles
     where profile_id = v_uid
       and role = v_capability
       and status = 'approved'
  ) then
    raise exception 'that capability is already approved'
      using errcode = '22023';
  end if;

  if p_documents is null
     or jsonb_typeof(p_documents) <> 'array'
     or jsonb_array_length(p_documents) < 1
     or jsonb_array_length(p_documents) > 8 then
    raise exception 'at least one document is required'
      using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(p_documents) as d
     where jsonb_typeof(d) <> 'object'
  ) then
    raise exception 'each document must be an object'
      using errcode = '22023';
  end if;

  -- Normalise the type before checking duplicates, so 'DL' and 'dl' cannot
  -- both slip past this check and then collide on the unique constraint.
  select array_agg(lower(btrim(d ->> 'document_type')))
    into v_types
    from jsonb_array_elements(p_documents) as d;

  if exists (
    select 1
      from unnest(v_types) as u(t)
     where u.t is null
        or u.t = ''
        or u.t !~ '^[a-z0-9_]{1,40}$'
  ) then
    raise exception 'document type must be 1-40 lowercase letters, digits or underscores'
      using errcode = '22023';
  end if;

  if (
    select count(distinct u.t)
      from unnest(v_types) as u(t)
  ) <> cardinality(v_types) then
    raise exception 'each document type may appear only once'
      using errcode = '22023';
  end if;

  -- Every row must name a file this account uploaded into its own folder. The
  -- bucket policy enforces the same prefix, so a tampered path cannot file a
  -- document under another person even if it reaches this function.
  for v_document in
    select value from jsonb_array_elements(p_documents)
  loop
    v_type := lower(btrim(v_document ->> 'document_type'));

    if char_length(btrim(coalesce(v_document ->> 'label', ''))) > 120 then
      raise exception 'document % label is too long (max 120 characters)', v_type
        using errcode = '22023';
    end if;
    if char_length(btrim(coalesce(v_document ->> 'document_number', ''))) > 60 then
      raise exception 'document % number is too long (max 60 characters)', v_type
        using errcode = '22023';
    end if;

    v_path := btrim(coalesce(v_document ->> 'storage_path', ''));
    if v_path = ''
       or char_length(v_path) > 512
       or left(v_path, length(v_uid::text) + 1) <> v_uid::text || '/'
       or v_path ~ '[^A-Za-z0-9._/-]'
       or v_path ~ '(^|/)\.\.?(/|$)'
       or v_path like '%//%'
       or right(v_path, 1) = '/' then
      raise exception 'document % is not stored under your folder', v_type
        using errcode = '42501';
    end if;
    if not exists (
      select 1
        from storage.objects o
       where o.bucket_id = 'verification-documents'
         and o.name = v_path
    ) then
      raise exception 'document % was not uploaded', v_type
        using errcode = '22023';
    end if;

    v_expires := nullif(btrim(coalesce(v_document ->> 'expires_at', '')), '');
    if v_expires is not null then
      if v_expires !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        raise exception 'document % has an invalid expiry date; use YYYY-MM-DD', v_type
          using errcode = '22023';
      end if;
      begin
        v_expires_date := v_expires::date;
      exception when others then
        raise exception 'document % has an invalid expiry date', v_type
          using errcode = '22023';
      end;
    end if;
  end loop;

  -- The partial unique index (profile_id, capability_type) serialises one open
  -- application. A concurrent first submission loses the insert and re-reads
  -- the winner instead of surfacing a raw unique violation.
  insert into public.verification_applications (
    profile_id, capability_type, status, submitted_at
  )
  values (v_uid, v_capability, 'submitted', now())
  on conflict (profile_id, capability_type)
    where status in ('draft', 'submitted', 'under_review', 'needs_resubmission')
  do nothing
  returning id into v_application_id;

  if v_application_id is null then
    select id, status
      into v_application_id, v_status
      from public.verification_applications
     where profile_id = v_uid
       and capability_type = v_capability
       and status in ('draft', 'submitted', 'under_review', 'needs_resubmission')
     for update;
    if not found then
      raise exception 'the application changed while submitting; try again'
        using errcode = '22023';
    end if;

    -- A submission already waiting on a reviewer is not silently replaced:
    -- the applicant waits for the decision or asks support to withdraw it.
    if v_status in ('submitted', 'under_review') then
      raise exception 'this application is already in review'
        using errcode = '22023';
    end if;

    update public.verification_applications
       set status = 'submitted',
           submitted_at = now(),
           reviewed_by = null,
           reviewed_at = null,
           decided_at = null,
           rejection_reason = null
     where id = v_application_id;
    delete from public.verification_documents
     where application_id = v_application_id;
  end if;

  insert into public.verification_documents (
    application_id, document_type, label, document_number, storage_path,
    expires_at, is_required, status
  )
  select v_application_id,
         lower(btrim(d ->> 'document_type')),
         nullif(btrim(d ->> 'label'), ''),
         nullif(btrim(d ->> 'document_number'), ''),
         btrim(d ->> 'storage_path'),
         case
           when nullif(btrim(d ->> 'expires_at'), '') is null then null
           else (d ->> 'expires_at')::date
         end,
         true,
         'pending'
    from jsonb_array_elements(p_documents) as d;

  return v_application_id;
end;
$$;

comment on function public.submit_verification_application(text, jsonb) is
  'Applicant write path: submits or resubmits the caller''s own application with validated, normalised documents. Never approves.';

-- 2. Application decisions: approval requires every document approved ------

create or replace function public.admin_review_verification(
  p_application_id uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.verification_applications;
  new_status public.verification_status;
  v_documents integer;
  v_pending integer;
  v_rejected integer;
  v_expired integer;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected', 'needs_resubmission') then
    raise exception 'invalid decision';
  end if;
  if p_decision <> 'approved' and coalesce(trim(p_reason), '') = '' then
    raise exception 'reason required';
  end if;

  select * into a
    from public.verification_applications
   where id = p_application_id
   for update;
  if not found then
    raise exception 'application not found';
  end if;
  if a.status not in ('submitted', 'under_review', 'needs_resubmission') then
    raise exception 'application not reviewable in status %', a.status;
  end if;

  select count(*),
         count(*) filter (where status = 'pending'),
         count(*) filter (where status = 'rejected'),
         count(*) filter (where status = 'expired')
    into v_documents, v_pending, v_rejected, v_expired
    from public.verification_documents
   where application_id = a.id;

  if p_decision = 'approved' then
    if v_documents = 0 then
      raise exception 'cannot approve an application without documents'
        using errcode = '22023';
    end if;
    if v_pending > 0 then
      raise exception 'cannot approve: % document(s) are still pending review',
        v_pending using errcode = '22023';
    end if;
    if v_rejected > 0 then
      raise exception 'cannot approve: % document(s) were rejected',
        v_rejected using errcode = '22023';
    end if;
    if v_expired > 0 then
      raise exception 'cannot approve: % document(s) have expired',
        v_expired using errcode = '22023';
    end if;
  end if;

  new_status := p_decision::public.verification_status;
  update public.verification_applications
     set status = new_status, reviewed_by = auth.uid(), reviewed_at = now(),
         decided_at = now(),
         rejection_reason = case when p_decision = 'approved' then null else p_reason end
   where id = a.id;

  if p_decision = 'approved' then
    -- The document gate above guarantees every attached file is approved, so
    -- an approved application can no longer point at an unreviewed document.
    insert into public.user_roles(profile_id, role, status, approved_at, approved_by)
      values (a.profile_id, a.capability_type, 'approved', now(), auth.uid())
    on conflict do nothing;
    update public.user_roles
       set status = 'approved', approved_at = now(), approved_by = auth.uid()
     where profile_id = a.profile_id
       and role = a.capability_type
       and status <> 'approved';
  end if;

  perform public._admin_audit(
    'verification.' || p_decision,
    'verification_application',
    p_application_id,
    jsonb_build_object('status', a.status),
    jsonb_build_object(
      'status', p_decision, 'reason', p_reason,
      'documents', v_documents, 'pending', v_pending,
      'rejected', v_rejected, 'expired', v_expired
    )
  );
end;
$$;

comment on function public.admin_review_verification(uuid, text, text) is
  'Admin decision: approval is refused unless every attached document is approved. Grants the role and audits the decision.';

-- 3. Document decisions: only while the application is still open -----------

create or replace function public.admin_review_document(
  p_kind text,
  p_document_id uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_application_id uuid;
  v_application_status public.verification_status;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision';
  end if;
  if p_decision = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'reason required';
  end if;

  if p_kind = 'verification' then
    select va.id, va.status
      into v_application_id, v_application_status
      from public.verification_documents vd
      join public.verification_applications va on va.id = vd.application_id
     where vd.id = p_document_id
     for update of va;
    if not found then
      raise exception 'document not found';
    end if;
    if v_application_status not in ('submitted', 'under_review', 'needs_resubmission') then
      raise exception 'documents can only be reviewed while the application is open (status %)',
        v_application_status using errcode = '22023';
    end if;

    update public.verification_documents
       set status = p_decision::public.document_review_status,
           reviewed_by = auth.uid(),
           reviewed_at = now(),
           rejection_reason = case when p_decision = 'approved' then null else p_reason end
     where id = p_document_id;
  elsif p_kind = 'vehicle' then
    update public.vehicle_documents
       set status = p_decision::public.document_review_status,
           reviewed_by = auth.uid(),
           reviewed_at = now(),
           rejection_reason = case when p_decision = 'approved' then null else p_reason end
     where id = p_document_id;
    if not found then
      raise exception 'document not found';
    end if;
  else
    raise exception 'invalid kind';
  end if;

  perform public._admin_audit(
    'document.' || p_decision,
    p_kind || '_document',
    p_document_id,
    null,
    jsonb_build_object('decision', p_decision, 'reason', p_reason)
  );
end;
$$;

comment on function public.admin_review_document(text, uuid, text, text) is
  'Admin document decision, audited. Verification documents are locked once their application is decided.';

-- 4. Re-assert the execution boundary ---------------------------------------

revoke all on function public.submit_verification_application(text, jsonb)
  from public, anon;
grant execute on function public.submit_verification_application(text, jsonb)
  to authenticated, service_role;

revoke all on function public.admin_review_verification(uuid, text, text)
  from public, anon;
grant execute on function public.admin_review_verification(uuid, text, text)
  to authenticated;

revoke all on function public.admin_review_document(text, uuid, text, text)
  from public, anon;
grant execute on function public.admin_review_document(text, uuid, text, text)
  to authenticated;