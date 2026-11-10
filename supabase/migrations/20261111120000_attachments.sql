-- General-purpose file attachments.
--
-- A private bucket for user and admin uploads, plus one metadata row per stored
-- object. The browser/Flutter client uploads bytes straight to Storage under
-- its own profile folder; the RPCs below are the only write path for the
-- metadata row and they verify the object really exists before recording it.
--
-- Security model:
--   * Storage path must be <owner_profile_id>/<file>, enforced by both the
--     storage policies and the table check constraint.
--   * A signed-in account may register/replace/delete only its own files. An
--     admin may act for any account; those actions are written to the audit log.
--   * The table is SELECT-only for authenticated. INSERT/UPDATE/DELETE are
--     revoked, so a client cannot invent a row that points at nothing.
--   * The bucket is private. Every read uses a short-lived signed URL.
--
-- Default limit: 20 MB per file.

-- 1. Bucket ---------------------------------------------------------------

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values (
      'attachments',
      'attachments',
      false,
      20971520,
      array[
        -- documents
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/rtf',
        'text/rtf',
        'text/plain',
        -- spreadsheets
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'text/csv',
        'application/csv',
        -- presentations
        'application/vnd.ms-powerpoint',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        -- images (raster only; SVG is deliberately excluded because a signed
        -- URL can render it as an active document in a browser)
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/gif',
        'image/heic',
        'image/heif',
        'image/bmp',
        'image/tiff',
        -- archives
        'application/zip',
        'application/x-zip-compressed',
        -- audio
        'audio/mpeg',
        'audio/mp4',
        'audio/aac',
        'audio/ogg',
        'audio/wav',
        'audio/x-wav',
        'audio/webm',
        'audio/flac',
        -- video
        'video/mp4',
        'video/webm',
        'video/quicktime',
        'video/x-msvideo',
        'video/x-matroska',
        'video/mpeg',
        'video/ogg',
        'video/3gpp'
      ]
    )
    on conflict (id) do update
      set public = false,
          file_size_limit = excluded.file_size_limit,
          allowed_mime_types = excluded.allowed_mime_types;
  end if;
end;
$$;

-- 2. Helpers --------------------------------------------------------------

-- The single allowlist used by the bucket, the table check constraint and the
-- RPCs. Keep the three in sync when adding a type.
create or replace function public.attachment_mime_allowed(p_mime_type text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_mime_type = any (array[
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/rtf',
    'text/rtf',
    'text/plain',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv',
    'application/csv',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/heic',
    'image/heif',
    'image/bmp',
    'image/tiff',
    'application/zip',
    'application/x-zip-compressed',
    'audio/mpeg',
    'audio/mp4',
    'audio/aac',
    'audio/ogg',
    'audio/wav',
    'audio/x-wav',
    'audio/webm',
    'audio/flac',
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'video/x-msvideo',
    'video/x-matroska',
    'video/mpeg',
    'video/ogg',
    'video/3gpp'
  ]);
$$;

revoke all on function public.attachment_mime_allowed(text) from public, anon;
grant execute on function public.attachment_mime_allowed(text) to authenticated, service_role;

-- Human-facing grouping used by the clients to pick an icon / preview mode.
create or replace function public.attachment_category(p_mime_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_mime_type like 'image/%' then 'image'
    when p_mime_type like 'audio/%' then 'audio'
    when p_mime_type like 'video/%' then 'video'
    when p_mime_type in (
      'application/pdf', 'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/rtf', 'text/rtf', 'text/plain'
    ) then 'document'
    when p_mime_type in (
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'text/csv', 'application/csv'
    ) then 'spreadsheet'
    when p_mime_type in (
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation'
    ) then 'presentation'
    when p_mime_type in ('application/zip', 'application/x-zip-compressed') then 'archive'
    else 'other'
  end;
$$;

revoke all on function public.attachment_category(text) from public, anon;
grant execute on function public.attachment_category(text) to authenticated, service_role;

-- 3. Metadata table -------------------------------------------------------

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles (id) on delete cascade,
  bucket_id text not null default 'attachments',
  storage_path text not null,
  file_name text not null,
  mime_type text not null,
  size_bytes bigint not null,
  category text not null generated always as (public.attachment_category(mime_type)) stored,
  label text,
  uploaded_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attachments_bucket_check check (bucket_id = 'attachments'),
  constraint attachments_size_check check (size_bytes between 1 and 20971520),
  constraint attachments_mime_check check (public.attachment_mime_allowed(mime_type)),
  constraint attachments_path_check check (
    length(storage_path) between 3 and 1024
    and position('..' in storage_path) = 0
    and position(chr(92) in storage_path) = 0
    and left(storage_path, length(owner_profile_id::text) + 1) = owner_profile_id::text || '/'
  ),
  constraint attachments_file_name_check check (
    length(file_name) between 1 and 255
    and position('/' in file_name) = 0
    and position(chr(92) in file_name) = 0
  ),
  constraint attachments_label_check check (label is null or length(label) <= 120),
  constraint attachments_path_unique unique (bucket_id, storage_path)
);

create index attachments_owner_created_idx
  on public.attachments (owner_profile_id, created_at desc);

create trigger attachments_set_updated_at
  before update on public.attachments
  for each row execute function public.set_updated_at();

comment on table public.attachments is
  'Private file metadata. Bytes live in storage.objects under <owner_profile_id>/<file>; rows are written only by register_attachment/replace_attachment.';
comment on column public.attachments.storage_path is
  'Object name inside the attachments bucket. Must start with the owner profile id.';
comment on column public.attachments.uploaded_by is
  'Account that performed the upload (owner, or an admin acting on the owner''s behalf).';

-- 4. RLS and table privileges --------------------------------------------
-- Reads are owner-or-admin. Writes go through the RPCs below, so no
-- INSERT/UPDATE/DELETE policy exists and the table privileges are revoked.

alter table public.attachments enable row level security;

create policy attachments_read_own
  on public.attachments for select to authenticated
  using (owner_profile_id = auth.uid() or public.is_admin());

revoke all on public.attachments from public, anon, authenticated;
grant select on public.attachments to authenticated;
grant all on public.attachments to service_role;

-- 5. Shared validation ----------------------------------------------------

create or replace function public._attachment_validate(
  p_owner_profile_id uuid,
  p_storage_path text,
  p_file_name text,
  p_mime_type text,
  p_size_bytes bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_metadata jsonb;
begin
  if p_owner_profile_id is null then
    raise exception 'an owner profile is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_owner_profile_id) then
    raise exception 'owner profile not found' using errcode = '22023';
  end if;
  if p_storage_path is null or length(p_storage_path) = 0 or length(p_storage_path) > 1024 then
    raise exception 'a valid storage path is required' using errcode = '22023';
  end if;
  if position('..' in p_storage_path) > 0
     or position(chr(92) in p_storage_path) > 0
     or left(p_storage_path, length(p_owner_profile_id::text) + 1) <> p_owner_profile_id::text || '/'
  then
    raise exception 'storage path must be inside the owner folder' using errcode = '22023';
  end if;
  if p_file_name is null or length(trim(p_file_name)) = 0 or length(p_file_name) > 255
     or position('/' in p_file_name) > 0 or position(chr(92) in p_file_name) > 0
  then
    raise exception 'a valid file name is required' using errcode = '22023';
  end if;
  if p_mime_type is null or not public.attachment_mime_allowed(p_mime_type) then
    raise exception 'unsupported file type: %', coalesce(p_mime_type, 'unknown')
      using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > 20971520 then
    raise exception 'files must be between 1 byte and 20 MB' using errcode = '22023';
  end if;

  -- The bytes must already be in the bucket. Storage records size and MIME in
  -- object metadata; when present, they must match the values being recorded.
  select o.metadata into v_metadata
    from storage.objects o
   where o.bucket_id = 'attachments'
     and o.name = p_storage_path;
  if not found then
    raise exception 'the uploaded file was not found in storage' using errcode = '22023';
  end if;
  if v_metadata is not null and v_metadata ? 'size'
     and (v_metadata ->> 'size')::bigint <> p_size_bytes
  then
    raise exception 'the recorded size does not match the stored file' using errcode = '22023';
  end if;
  if v_metadata is not null and v_metadata ? 'mimetype'
     and v_metadata ->> 'mimetype' <> p_mime_type
  then
    raise exception 'the recorded type does not match the stored file' using errcode = '22023';
  end if;
end;
$$;

revoke all on function public._attachment_validate(uuid,text,text,text,bigint)
  from public, anon, authenticated;

-- 6. Register / replace / delete -----------------------------------------

create or replace function public.register_attachment(
  p_owner_profile_id uuid,
  p_storage_path text,
  p_file_name text,
  p_mime_type text,
  p_size_bytes bigint,
  p_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_label text := nullif(trim(coalesce(p_label, '')), '');
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;
  if v_uid <> p_owner_profile_id and not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  perform public._attachment_validate(
    p_owner_profile_id, p_storage_path, p_file_name, p_mime_type, p_size_bytes
  );

  insert into public.attachments (
    owner_profile_id, bucket_id, storage_path, file_name, mime_type,
    size_bytes, label, uploaded_by
  )
  values (
    p_owner_profile_id, 'attachments', p_storage_path, trim(p_file_name),
    p_mime_type, p_size_bytes, v_label, v_uid
  )
  on conflict (bucket_id, storage_path) do update
    set file_name = excluded.file_name,
        mime_type = excluded.mime_type,
        size_bytes = excluded.size_bytes,
        label = coalesce(excluded.label, public.attachments.label),
        uploaded_by = excluded.uploaded_by,
        updated_at = now()
    where public.attachments.owner_profile_id = excluded.owner_profile_id
  returning id into v_id;

  if v_id is null then
    raise exception 'that file is already registered to another account'
      using errcode = '23505';
  end if;

  if v_uid <> p_owner_profile_id then
    perform public._admin_audit(
      'attachment.registered', 'attachment', v_id,
      null,
      jsonb_build_object(
        'owner_profile_id', p_owner_profile_id,
        'storage_path', p_storage_path,
        'mime_type', p_mime_type,
        'size_bytes', p_size_bytes
      )
    );
  end if;
  return v_id;
end;
$$;

create or replace function public.replace_attachment(
  p_attachment_id uuid,
  p_storage_path text,
  p_file_name text,
  p_mime_type text,
  p_size_bytes bigint,
  p_label text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.attachments;
  v_previous text;
  v_label text := nullif(trim(coalesce(p_label, '')), '');
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;

  select * into v_row from public.attachments where id = p_attachment_id for update;
  if not found then
    raise exception 'attachment not found' using errcode = 'P0002';
  end if;
  if v_uid <> v_row.owner_profile_id and not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  perform public._attachment_validate(
    v_row.owner_profile_id, p_storage_path, p_file_name, p_mime_type, p_size_bytes
  );

  v_previous := v_row.storage_path;
  update public.attachments
     set storage_path = p_storage_path,
         file_name = trim(p_file_name),
         mime_type = p_mime_type,
         size_bytes = p_size_bytes,
         label = coalesce(v_label, label),
         uploaded_by = v_uid,
         updated_at = now()
   where id = v_row.id;

  if v_uid <> v_row.owner_profile_id then
    perform public._admin_audit(
      'attachment.replaced', 'attachment', v_row.id,
      jsonb_build_object('storage_path', v_previous, 'file_name', v_row.file_name),
      jsonb_build_object('storage_path', p_storage_path, 'file_name', trim(p_file_name))
    );
  end if;
  return v_previous;
end;
$$;

create or replace function public.delete_attachment(p_attachment_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.attachments;
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;

  select * into v_row from public.attachments where id = p_attachment_id for update;
  if not found then
    raise exception 'attachment not found' using errcode = 'P0002';
  end if;
  if v_uid <> v_row.owner_profile_id and not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.attachments where id = v_row.id;

  if v_uid <> v_row.owner_profile_id then
    perform public._admin_audit(
      'attachment.deleted', 'attachment', v_row.id,
      jsonb_build_object(
        'owner_profile_id', v_row.owner_profile_id,
        'storage_path', v_row.storage_path,
        'file_name', v_row.file_name
      ),
      null
    );
  end if;
  return v_row.storage_path;
end;
$$;

revoke all on function public.register_attachment(uuid,text,text,text,bigint,text)
  from public, anon;
revoke all on function public.replace_attachment(uuid,text,text,text,bigint,text)
  from public, anon;
revoke all on function public.delete_attachment(uuid)
  from public, anon;

grant execute on function public.register_attachment(uuid,text,text,text,bigint,text)
  to authenticated;
grant execute on function public.replace_attachment(uuid,text,text,text,bigint,text)
  to authenticated;
grant execute on function public.delete_attachment(uuid)
  to authenticated;

comment on function public.register_attachment(uuid,text,text,text,bigint,text) is
  'Records an already-uploaded attachments object. Owner or admin only; verifies folder, MIME, size and that the object exists.';
comment on function public.replace_attachment(uuid,text,text,text,bigint,text) is
  'Points an existing attachment at a new object and returns the previous path so the caller can remove it.';
comment on function public.delete_attachment(uuid) is
  'Deletes the metadata row and returns the storage path so the caller can remove the object.';

-- 7. Storage policies -----------------------------------------------------
-- Owner folder rules mirror the verification buckets. Admins may write into
-- any account folder so they can upload on a user's behalf.

do $$
begin
  if to_regclass('storage.objects') is not null
     and to_regproc('storage.foldername') is not null then
    drop policy if exists "surgo attachments read own" on storage.objects;
    create policy "surgo attachments read own"
      on storage.objects for select to authenticated
      using (
        bucket_id = 'attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo attachments insert own" on storage.objects;
    create policy "surgo attachments insert own"
      on storage.objects for insert to authenticated
      with check (
        bucket_id = 'attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo attachments update own" on storage.objects;
    create policy "surgo attachments update own"
      on storage.objects for update to authenticated
      using (
        bucket_id = 'attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
      )
      with check (
        bucket_id = 'attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo attachments delete own" on storage.objects;
    create policy "surgo attachments delete own"
      on storage.objects for delete to authenticated
      using (
        bucket_id = 'attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo admin attachments read" on storage.objects;
    create policy "surgo admin attachments read"
      on storage.objects for select to authenticated
      using (bucket_id = 'attachments' and public.is_admin());

    drop policy if exists "surgo admin attachments insert" on storage.objects;
    create policy "surgo admin attachments insert"
      on storage.objects for insert to authenticated
      with check (bucket_id = 'attachments' and public.is_admin());

    drop policy if exists "surgo admin attachments update" on storage.objects;
    create policy "surgo admin attachments update"
      on storage.objects for update to authenticated
      using (bucket_id = 'attachments' and public.is_admin())
      with check (bucket_id = 'attachments' and public.is_admin());

    drop policy if exists "surgo admin attachments delete" on storage.objects;
    create policy "surgo admin attachments delete"
      on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.is_admin());
  end if;
end;
$$;
