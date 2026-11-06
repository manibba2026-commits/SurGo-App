-- Storage buckets for avatars and private verification/vehicle documents.
--
-- Object paths are expected to start with the owner's profile id:
--   <profile_id>/<filename>
-- The policies below enforce that convention.

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values
      ('avatars', 'avatars', true, 5242880,
        array['image/jpeg', 'image/png', 'image/webp']),
      ('verification-documents', 'verification-documents', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png']),
      ('vehicle-documents', 'vehicle-documents', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png'])
    on conflict (id) do nothing;
  end if;
end;
$$;

do $$
begin
  if to_regclass('storage.objects') is not null
     and to_regproc('storage.foldername') is not null then
    drop policy if exists "surgo documents read own" on storage.objects;
    create policy "surgo documents read own"
      on storage.objects for select to authenticated
      using (
        bucket_id in ('verification-documents', 'vehicle-documents')
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo storage insert own" on storage.objects;
    create policy "surgo storage insert own"
      on storage.objects for insert to authenticated
      with check (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo storage update own" on storage.objects;
    create policy "surgo storage update own"
      on storage.objects for update to authenticated
      using (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and (storage.foldername(name))[1] = auth.uid()::text
      )
      with check (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo storage delete own" on storage.objects;
    create policy "surgo storage delete own"
      on storage.objects for delete to authenticated
      using (
        bucket_id in ('avatars', 'verification-documents', 'vehicle-documents')
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;
end;
$$;
