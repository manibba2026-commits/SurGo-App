-- Applicant-side verification submission.
--
-- The authenticated role is SELECT-only on the verification tables, so the app
-- cannot insert an application or a document row directly. This function is the
-- single write path: it derives the applicant from auth.uid(), refuses to touch
-- another profile's rows, and leaves every decision field for
-- admin_review_verification().
--
-- Nothing here approves a capability. A submission always lands as
-- 'submitted' with pending documents; only an admin decision grants a role.

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
  v_path text;
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

  if (
    select count(distinct d ->> 'document_type')
      from jsonb_array_elements(p_documents) as d
  ) <> jsonb_array_length(p_documents) then
    raise exception 'each document type may appear only once'
      using errcode = '22023';
  end if;

  -- Every row must name a file this account uploaded into its own folder. The
  -- bucket policy enforces the same prefix, so a tampered path cannot file a
  -- document under another person even if it reaches this function.
  for v_document in
    select value from jsonb_array_elements(p_documents)
  loop
    if coalesce(trim(v_document ->> 'document_type'), '') = '' then
      raise exception 'document type is required' using errcode = '22023';
    end if;
    v_path := trim(coalesce(v_document ->> 'storage_path', ''));
    if v_path = ''
       or left(v_path, length(v_uid::text) + 1) <> v_uid::text || '/' then
      raise exception 'document % is not stored under your folder',
        v_document ->> 'document_type' using errcode = '42501';
    end if;
    if not exists (
      select 1
        from storage.objects o
       where o.bucket_id = 'verification-documents'
         and o.name = v_path
    ) then
      raise exception 'document % was not uploaded',
        v_document ->> 'document_type' using errcode = '22023';
    end if;
  end loop;

  select id, status
    into v_application_id, v_status
    from public.verification_applications
   where profile_id = v_uid
     and capability_type = v_capability
     and status in ('draft', 'submitted', 'under_review', 'needs_resubmission')
   for update;

  if found then
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
  else
    insert into public.verification_applications (
      profile_id, capability_type, status, submitted_at
    )
    values (v_uid, v_capability, 'submitted', now())
    returning id into v_application_id;
  end if;

  insert into public.verification_documents (
    application_id, document_type, label, document_number, storage_path,
    expires_at, status
  )
  select v_application_id,
         d ->> 'document_type',
         nullif(trim(d ->> 'label'), ''),
         nullif(trim(d ->> 'document_number'), ''),
         trim(d ->> 'storage_path'),
         case
           when nullif(trim(d ->> 'expires_at'), '') is null then null
           else (d ->> 'expires_at')::date
         end,
         'pending'
    from jsonb_array_elements(p_documents) as d;

  return v_application_id;
end;
$$;

comment on function public.submit_verification_application(text, jsonb) is
  'Applicant write path: submits or resubmits the caller''s own application. Never approves.';

revoke all on function public.submit_verification_application(text, jsonb)
  from public, anon;
grant execute on function public.submit_verification_application(text, jsonb)
  to authenticated, service_role;
