-- Admin account management.
--
-- Adds the missing write paths the dashboard needs, all as admin-checked
-- SECURITY DEFINER functions that audit through _admin_audit():
--   * profile detail edits (name, address, barangay, avatar)
--   * explicit role grant / revoke / suspend for the four operational roles
--   * admin-managed verification and vehicle documents (attach, replace, remove)
--
-- Rider and Vehicle Owner approval is refused unless an approved verification
-- application exists with at least one document and every document approved,
-- mirroring the gate in admin_review_verification().
--
-- "Helper" in the product is the existing public.user_role_type 'earner'.
-- No enum value is added, so the Flutter app and seeded roles stay compatible.

-- 1. Profile detail fields ------------------------------------------------

alter table public.profiles add column if not exists address text;
alter table public.profiles add column if not exists barangay text;

comment on column public.profiles.address is
  'Street address entered by the account holder or an administrator. Display data only.';
comment on column public.profiles.barangay is
  'Barangay name for the account. Display data only; service areas stay separate.';

-- 2. Admin profile update ------------------------------------------------

create or replace function public.admin_update_profile(
  p_profile_id uuid,
  p_full_name text,
  p_first_name text default null,
  p_address text default null,
  p_barangay text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row public.profiles;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_full_name is null or length(trim(p_full_name)) = 0 then
    raise exception 'full name is required' using errcode = '22023';
  end if;

  select * into old_row from public.profiles where id = p_profile_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  update public.profiles
     set full_name = trim(p_full_name),
         first_name = nullif(trim(coalesce(p_first_name, '')), ''),
         address = nullif(trim(coalesce(p_address, '')), ''),
         barangay = nullif(trim(coalesce(p_barangay, '')), ''),
         updated_at = now()
   where id = p_profile_id;

  perform public._admin_audit(
    'profile.updated', 'profile', p_profile_id,
    jsonb_build_object(
      'full_name', old_row.full_name, 'first_name', old_row.first_name,
      'address', old_row.address, 'barangay', old_row.barangay
    ),
    jsonb_build_object(
      'full_name', trim(p_full_name), 'first_name', nullif(trim(coalesce(p_first_name, '')), ''),
      'address', nullif(trim(coalesce(p_address, '')), ''),
      'barangay', nullif(trim(coalesce(p_barangay, '')), '')
    )
  );
end;
$$;

create or replace function public.admin_set_avatar(
  p_profile_id uuid,
  p_avatar_path text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_path text;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_avatar_path is not null then
    if position('..' in p_avatar_path) > 0
       or position('\\' in p_avatar_path) > 0
       or left(p_avatar_path, length(p_profile_id::text) + 1) <> p_profile_id::text || '/'
    then
      raise exception 'avatar path must be inside the account folder' using errcode = '22023';
    end if;
    if not exists (
      select 1 from storage.objects
       where bucket_id = 'avatars' and name = p_avatar_path
    ) then
      raise exception 'avatar file not found in storage' using errcode = '22023';
    end if;
  end if;

  select avatar_path into old_path
    from public.profiles where id = p_profile_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  update public.profiles
     set avatar_path = p_avatar_path, updated_at = now()
   where id = p_profile_id;

  perform public._admin_audit(
    'profile.avatar_updated', 'profile', p_profile_id,
    jsonb_build_object('avatar_path', old_path),
    jsonb_build_object('avatar_path', p_avatar_path)
  );
end;
$$;

-- Contact fields live in auth.users; the Admin API route changes those and
-- then calls this function so the mirrored profile columns and the audit row
-- stay consistent.
create or replace function public.admin_update_profile_contact(
  p_profile_id uuid,
  p_email text,
  p_phone text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row public.profiles;
  v_email text;
  v_phone text;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_email := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_phone := nullif(trim(coalesce(p_phone, '')), '');
  if v_email is null and v_phone is null then
    raise exception 'an email address or phone number is required' using errcode = '22023';
  end if;
  if v_email is not null and v_email !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$' then
    raise exception 'invalid email address' using errcode = '22023';
  end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9][0-9 ()-]{6,19}$' then
    raise exception 'invalid phone number' using errcode = '22023';
  end if;

  select * into old_row from public.profiles where id = p_profile_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  update public.profiles
     set email = v_email, phone = v_phone, updated_at = now()
   where id = p_profile_id;

  perform public._admin_audit(
    'profile.contact_updated', 'profile', p_profile_id,
    jsonb_build_object('email', old_row.email, 'phone', old_row.phone),
    jsonb_build_object('email', v_email, 'phone', v_phone)
  );
end;
$$;

-- 3. Role grant / revoke / suspend ---------------------------------------

create or replace function public.admin_set_user_role(
  p_profile_id uuid,
  p_role text,
  p_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role_type;
  v_status public.role_approval_status;
  old_status public.role_approval_status;
  v_role_id uuid;
  v_documents integer;
  v_unapproved integer;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('passenger', 'earner', 'rider', 'vehicle_owner') then
    raise exception 'invalid role' using errcode = '22023';
  end if;
  if p_status is null or p_status not in ('pending', 'approved', 'suspended', 'revoked') then
    raise exception 'invalid role status' using errcode = '22023';
  end if;
  v_role := p_role::public.user_role_type;
  v_status := p_status::public.role_approval_status;

  perform 1 from public.profiles where id = p_profile_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  -- Approving a capability that requires documents is only allowed after a
  -- complete, approved review. Both the application and every attached file
  -- must carry an approved status.
  if v_status = 'approved' and v_role in ('rider', 'vehicle_owner') then
    if not exists (
      select 1 from public.verification_applications
       where profile_id = p_profile_id
         and capability_type = v_role
         and status = 'approved'
    ) then
      raise exception 'cannot approve % without an approved verification application', p_role
        using errcode = '22023';
    end if;

    select count(*), count(*) filter (where d.status <> 'approved')
      into v_documents, v_unapproved
      from public.verification_documents d
      join public.verification_applications a on a.id = d.application_id
     where a.profile_id = p_profile_id
       and a.capability_type = v_role
       and a.status = 'approved';

    if v_documents = 0 then
      raise exception 'cannot approve % without at least one reviewed document', p_role
        using errcode = '22023';
    end if;
    if v_unapproved > 0 then
      raise exception 'cannot approve %: % document(s) are not approved', p_role, v_unapproved
        using errcode = '22023';
    end if;
  end if;

  select status, id into old_status, v_role_id
    from public.user_roles
   where profile_id = p_profile_id and role = v_role
   for update;

  insert into public.user_roles(profile_id, role, status, approved_at, approved_by)
  values (
    p_profile_id, v_role, v_status,
    case when v_status = 'approved' then now() end,
    case when v_status = 'approved' then auth.uid() end
  )
  on conflict (profile_id, role) do update
     set status = excluded.status,
         approved_at = case when excluded.status = 'approved' then now() else null end,
         approved_by = case when excluded.status = 'approved' then auth.uid() else null end,
         updated_at = now()
  returning id into v_role_id;

  perform public._admin_audit(
    'role.' || p_status, 'user_role', v_role_id,
    jsonb_build_object('role', p_role, 'status', old_status),
    jsonb_build_object('role', p_role, 'status', p_status, 'reason', p_reason)
  );
end;
$$;

-- 4. Admin-managed verification applications and documents ---------------

create or replace function public.admin_ensure_verification_application(
  p_profile_id uuid,
  p_capability text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_capability public.user_role_type;
  v_id uuid;
  v_status public.verification_status;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_capability is null or p_capability not in ('earner', 'rider', 'vehicle_owner') then
    raise exception 'invalid capability' using errcode = '22023';
  end if;
  v_capability := p_capability::public.user_role_type;

  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'profile not found';
  end if;
  if exists (
    select 1 from public.user_roles
     where profile_id = p_profile_id and role = v_capability and status = 'approved'
  ) then
    raise exception 'that capability is already approved' using errcode = '22023';
  end if;

  select id, status into v_id, v_status
    from public.verification_applications
   where profile_id = p_profile_id
     and capability_type = v_capability
     and status in ('draft', 'submitted', 'under_review', 'needs_resubmission')
   for update;

  if found then
    if v_status = 'draft' then
      update public.verification_applications
         set status = 'submitted', submitted_at = coalesce(submitted_at, now()), updated_at = now()
       where id = v_id;
      perform public._admin_audit(
        'verification.reopened', 'verification_application', v_id,
        jsonb_build_object('status', 'draft'), jsonb_build_object('status', 'submitted')
      );
    end if;
    return v_id;
  end if;

  begin
    insert into public.verification_applications(profile_id, capability_type, status, submitted_at)
    values (p_profile_id, v_capability, 'submitted', now())
    returning id into v_id;
  exception when unique_violation then
    select id into v_id
      from public.verification_applications
     where profile_id = p_profile_id
       and capability_type = v_capability
       and status in ('draft', 'submitted', 'under_review', 'needs_resubmission')
     limit 1;
  end;

  perform public._admin_audit(
    'verification.created', 'verification_application', v_id,
    null, jsonb_build_object('capability', p_capability, 'status', 'submitted')
  );
  return v_id;
end;
$$;

create or replace function public.admin_attach_verification_document(
  p_application_id uuid,
  p_document_type text,
  p_label text,
  p_storage_path text,
  p_document_number text default null,
  p_expires_at date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.verification_applications;
  v_id uuid;
  v_before public.verification_documents;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_document_type is null or length(trim(p_document_type)) = 0
     or length(p_document_type) > 80 then
    raise exception 'valid document type required' using errcode = '22023';
  end if;
  if p_storage_path is null or length(trim(p_storage_path)) = 0 then
    raise exception 'a stored file is required' using errcode = '22023';
  end if;

  select * into a from public.verification_applications where id = p_application_id for update;
  if not found then
    raise exception 'application not found';
  end if;
  if a.status not in ('draft', 'submitted', 'under_review', 'needs_resubmission') then
    raise exception 'application is already decided';
  end if;
  if position('..' in p_storage_path) > 0
     or position('\\' in p_storage_path) > 0
     or left(p_storage_path, length(a.profile_id::text) + 1) <> a.profile_id::text || '/'
  then
    raise exception 'document path must be inside the account folder' using errcode = '22023';
  end if;
  if not exists (
    select 1 from storage.objects
     where bucket_id = 'verification-documents' and name = p_storage_path
  ) then
    raise exception 'document file not found in storage' using errcode = '22023';
  end if;

  select * into v_before
    from public.verification_documents
   where application_id = p_application_id and document_type = trim(p_document_type);

  insert into public.verification_documents(
    application_id, document_type, label, document_number, storage_path, expires_at,
    status, reviewed_by, reviewed_at, rejection_reason
  )
  values (
    p_application_id, trim(p_document_type), nullif(trim(coalesce(p_label, '')), ''),
    nullif(trim(coalesce(p_document_number, '')), ''), p_storage_path, p_expires_at,
    'pending', null, null, null
  )
  on conflict (application_id, document_type) do update
     set label = excluded.label,
         document_number = excluded.document_number,
         storage_path = excluded.storage_path,
         expires_at = excluded.expires_at,
         status = 'pending',
         reviewed_by = null,
         reviewed_at = null,
         rejection_reason = null,
         updated_at = now()
  returning id into v_id;

  perform public._admin_audit(
    case when v_before.id is null then 'document.attached' else 'document.replaced' end,
    'verification_document', v_id,
    jsonb_build_object(
      'storage_path', v_before.storage_path, 'status', v_before.status,
      'document_number', v_before.document_number, 'expires_at', v_before.expires_at
    ),
    jsonb_build_object(
      'storage_path', p_storage_path, 'status', 'pending',
      'document_type', trim(p_document_type), 'document_number', p_document_number,
      'expires_at', p_expires_at
    )
  );
  return v_id;
end;
$$;

create or replace function public.admin_detach_verification_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.verification_documents;
  a public.verification_applications;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into d from public.verification_documents where id = p_document_id for update;
  if not found then
    raise exception 'document not found';
  end if;
  select * into a from public.verification_applications where id = d.application_id for update;
  if a.status not in ('draft', 'submitted', 'under_review', 'needs_resubmission') then
    raise exception 'application is already decided';
  end if;

  delete from public.verification_documents where id = d.id;
  perform public._admin_audit(
    'document.removed', 'verification_document', d.id,
    jsonb_build_object(
      'storage_path', d.storage_path, 'status', d.status, 'document_type', d.document_type
    ),
    null
  );
end;
$$;

create or replace function public.admin_attach_vehicle_document(
  p_vehicle_id uuid,
  p_document_type text,
  p_storage_path text,
  p_document_number text default null,
  p_expires_at date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.vehicles;
  v_id uuid;
  v_before public.vehicle_documents;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_document_type is null or length(trim(p_document_type)) = 0
     or length(p_document_type) > 80 then
    raise exception 'valid document type required' using errcode = '22023';
  end if;
  if p_storage_path is null or length(trim(p_storage_path)) = 0 then
    raise exception 'a stored file is required' using errcode = '22023';
  end if;

  select * into v from public.vehicles where id = p_vehicle_id for update;
  if not found then
    raise exception 'vehicle not found';
  end if;
  if position('..' in p_storage_path) > 0
     or position('\\' in p_storage_path) > 0
     or left(p_storage_path, length(v.owner_profile_id::text) + 1) <> v.owner_profile_id::text || '/'
  then
    raise exception 'document path must be inside the owner folder' using errcode = '22023';
  end if;
  if not exists (
    select 1 from storage.objects
     where bucket_id = 'vehicle-documents' and name = p_storage_path
  ) then
    raise exception 'document file not found in storage' using errcode = '22023';
  end if;

  select * into v_before
    from public.vehicle_documents
   where vehicle_id = p_vehicle_id and document_type = trim(p_document_type);

  insert into public.vehicle_documents(
    vehicle_id, document_type, document_number, storage_path, expires_at,
    status, reviewed_by, reviewed_at, rejection_reason
  )
  values (
    p_vehicle_id, trim(p_document_type), nullif(trim(coalesce(p_document_number, '')), ''),
    p_storage_path, p_expires_at, 'pending', null, null, null
  )
  on conflict (vehicle_id, document_type) do update
     set document_number = excluded.document_number,
         storage_path = excluded.storage_path,
         expires_at = excluded.expires_at,
         status = 'pending',
         reviewed_by = null,
         reviewed_at = null,
         rejection_reason = null,
         updated_at = now()
  returning id into v_id;

  perform public._admin_audit(
    case when v_before.id is null then 'vehicle_document.attached' else 'vehicle_document.replaced' end,
    'vehicle_document', v_id,
    jsonb_build_object(
      'storage_path', v_before.storage_path, 'status', v_before.status,
      'document_number', v_before.document_number, 'expires_at', v_before.expires_at
    ),
    jsonb_build_object(
      'storage_path', p_storage_path, 'status', 'pending',
      'document_type', trim(p_document_type), 'document_number', p_document_number,
      'expires_at', p_expires_at
    )
  );
  return v_id;
end;
$$;

create or replace function public.admin_detach_vehicle_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.vehicle_documents;
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into d from public.vehicle_documents where id = p_document_id for update;
  if not found then
    raise exception 'document not found';
  end if;

  delete from public.vehicle_documents where id = d.id;
  perform public._admin_audit(
    'vehicle_document.removed', 'vehicle_document', d.id,
    jsonb_build_object(
      'storage_path', d.storage_path, 'status', d.status, 'document_type', d.document_type
    ),
    null
  );
end;
$$;

-- 5. Admin storage writes -------------------------------------------------
-- Admins may upload/replace/remove files for any account. The row-level
-- document RPCs above still validate the path and require the object to exist.

do $$
begin
  if to_regclass('storage.objects') is not null then
    drop policy if exists "surgo admin insert documents" on storage.objects;
    create policy "surgo admin insert documents"
      on storage.objects for insert to authenticated
      with check (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and public.is_admin()
      );

    drop policy if exists "surgo admin update documents" on storage.objects;
    create policy "surgo admin update documents"
      on storage.objects for update to authenticated
      using (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and public.is_admin()
      )
      with check (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and public.is_admin()
      );

    drop policy if exists "surgo admin delete documents" on storage.objects;
    create policy "surgo admin delete documents"
      on storage.objects for delete to authenticated
      using (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and public.is_admin()
      );
  end if;
end;
$$;

-- 6. Execution boundary ---------------------------------------------------

do $$
declare
  f text;
begin
  foreach f in array array[
    'admin_update_profile(uuid,text,text,text,text)',
    'admin_set_avatar(uuid,text)',
    'admin_update_profile_contact(uuid,text,text)',
    'admin_set_user_role(uuid,text,text,text)',
    'admin_ensure_verification_application(uuid,text)',
    'admin_attach_verification_document(uuid,text,text,text,text,date)',
    'admin_detach_verification_document(uuid)',
    'admin_attach_vehicle_document(uuid,text,text,text,date)',
    'admin_detach_vehicle_document(uuid)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

comment on function public.admin_set_user_role(uuid, text, text, text) is
  'Admin role decision, audited. Rider and Vehicle Owner approval requires an approved application whose documents are all approved.';
comment on function public.admin_attach_verification_document(uuid, text, text, text, text, date) is
  'Admin attaches or replaces a verification document. Replacing resets the file to pending so it must be reviewed again.';
comment on function public.admin_attach_vehicle_document(uuid, text, text, text, date) is
  'Admin attaches or replaces a vehicle document, validating the owner folder and the stored object.';
