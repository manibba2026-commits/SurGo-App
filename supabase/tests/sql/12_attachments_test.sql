begin;

-- General attachments: private bucket, owner/admin storage policies, and the
-- register/replace/delete RPCs that are the only write path for metadata.
--
-- Fixtures are created as the database owner (bypasses RLS). The auth trigger
-- creates a profile and an approved passenger role for every auth user.

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('c1000000-0000-0000-0000-000000000001', 'cara.admin@example.com',
   '+639180000401', '{"full_name":"Cara Admin"}'::jsonb),
  ('c1000000-0000-0000-0000-000000000002', 'carlo.owner@example.com',
   '+639180000402', '{"full_name":"Carlo Owner"}'::jsonb),
  ('c1000000-0000-0000-0000-000000000003', 'cora.other@example.com',
   '+639180000403', '{"full_name":"Cora Other"}'::jsonb);

insert into public.user_roles (profile_id, role, status, approved_at) values
  ('c1000000-0000-0000-0000-000000000001', 'admin', 'approved', now());

-- Objects that really exist in the bucket, with the metadata Supabase Storage
-- records. `report.pdf` has a deliberate mismatch for the size check.
insert into storage.objects (bucket_id, name, metadata) values
  ('attachments',
   'c1000000-0000-0000-0000-000000000002/report.pdf',
   '{"size": 1234, "mimetype": "application/pdf"}'::jsonb),
  ('attachments',
   'c1000000-0000-0000-0000-000000000002/sheet.xlsx',
   '{"size": 2048, "mimetype": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}'::jsonb),
  ('attachments',
   'c1000000-0000-0000-0000-000000000002/clip.mp4',
   '{"size": 4096, "mimetype": "video/mp4"}'::jsonb),
  ('attachments',
   'c1000000-0000-0000-0000-000000000002/replacement.pdf',
   '{"size": 3000, "mimetype": "application/pdf"}'::jsonb),
  ('attachments',
   'c1000000-0000-0000-0000-000000000002/admin-upload.zip',
   '{"size": 5000, "mimetype": "application/zip"}'::jsonb),
  ('attachments',
   'c1000000-0000-0000-0000-000000000002/wrong-size.pdf',
   '{"size": 10, "mimetype": "application/pdf"}'::jsonb),
  ('attachments',
   'c1000000-0000-0000-0000-000000000003/secret.pdf',
   '{"size": 700, "mimetype": "application/pdf"}'::jsonb);

-- 1. Bucket and privilege surface.
do $$
begin
  perform public.test_assert(
    (select file_size_limit from storage.buckets where id = 'attachments') = 20971520,
    'the attachments bucket defaults to 20 MB'
  );
  perform public.test_assert(
    (select public from storage.buckets where id = 'attachments') = false,
    'the attachments bucket is private'
  );
  perform public.test_assert(
    (select allowed_mime_types from storage.buckets where id = 'attachments')
      @> array[
        'application/pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'text/csv',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'text/plain',
        'application/zip',
        'audio/mpeg',
        'video/mp4'
      ],
    'the bucket accepts every required family'
  );

  perform public.test_assert(
    not has_table_privilege('anon', 'public.attachments', 'SELECT'),
    'anon must not read attachment metadata'
  );
  perform public.test_assert(
    has_table_privilege('authenticated', 'public.attachments', 'SELECT'),
    'authenticated may read attachment metadata (RLS narrows the rows)'
  );
end;
$$;

do $$
begin
  perform public.test_assert(
    not has_table_privilege('authenticated', 'public.attachments', 'INSERT')
      and not has_table_privilege('authenticated', 'public.attachments', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.attachments', 'DELETE'),
    'authenticated must not write metadata directly'
  );
end;
$$;

do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.register_attachment(uuid,text,text,text,bigint,text)',
    'public.replace_attachment(uuid,text,text,text,bigint,text)',
    'public.delete_attachment(uuid)'
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
    (select count(*) from pg_policies
      where schemaname = 'storage'
        and policyname in (
          'surgo attachments read own',
          'surgo attachments insert own',
          'surgo attachments update own',
          'surgo attachments delete own',
          'surgo admin attachments read',
          'surgo admin attachments insert',
          'surgo admin attachments update',
          'surgo admin attachments delete'
        )) = 8,
    'owner and admin storage policies exist for the bucket'
  );
end;
$$;

-- 2. A signed-in owner registers a real object, and repeat registration is
--    idempotent rather than a duplicate row.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000002', true
);

select set_config(
  'surgo.test_attachment',
  public.register_attachment(
    'c1000000-0000-0000-0000-000000000002',
    'c1000000-0000-0000-0000-000000000002/report.pdf',
    'report.pdf', 'application/pdf', 1234, 'Q4 report'
  )::text,
  true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_attachment')::uuid;
begin
  perform public.test_assert(
    (select count(*) from public.attachments
      where id = v_id
        and owner_profile_id = 'c1000000-0000-0000-0000-000000000002'
        and bucket_id = 'attachments'
        and storage_path = 'c1000000-0000-0000-0000-000000000002/report.pdf'
        and file_name = 'report.pdf'
        and mime_type = 'application/pdf'
        and size_bytes = 1234
        and category = 'document'
        and label = 'Q4 report'
        and uploaded_by = 'c1000000-0000-0000-0000-000000000002') = 1,
    'the owner row records the uploaded object and its metadata'
  );

  perform public.test_assert(
    public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000002/report.pdf',
      'report.pdf', 'application/pdf', 1234, null
    ) = v_id,
    're-registering the same object is idempotent'
  );
  perform public.test_assert(
    (select count(*) from public.attachments) = 1,
    'idempotent registration did not duplicate the row'
  );
end;
$$;

-- 3. Categories are derived from the MIME type, not trusted from the client.
select public.register_attachment(
  'c1000000-0000-0000-0000-000000000002',
  'c1000000-0000-0000-0000-000000000002/sheet.xlsx',
  'sheet.xlsx',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 2048, null
);
select public.register_attachment(
  'c1000000-0000-0000-0000-000000000002',
  'c1000000-0000-0000-0000-000000000002/clip.mp4',
  'clip.mp4', 'video/mp4', 4096, null
);

do $$
begin
  perform public.test_assert(
    (select category from public.attachments
      where storage_path = 'c1000000-0000-0000-0000-000000000002/sheet.xlsx') = 'spreadsheet',
    'spreadsheets get their own category'
  );
  perform public.test_assert(
    (select category from public.attachments
      where storage_path = 'c1000000-0000-0000-0000-000000000002/clip.mp4') = 'video',
    'videos get their own category'
  );
end;
$$;

-- 4. Validation failures never create a row.
do $$
begin
  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000002/report.pdf',
      'report.pdf', 'application/x-msdownload', 1234, null
    );
    raise exception 'an unsupported MIME type must be refused';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000002/report.pdf',
      'report.pdf', 'application/pdf', 20971521, null
    );
    raise exception 'a file over 20 MB must be refused';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000002/missing.pdf',
      'missing.pdf', 'application/pdf', 1234, null
    );
    raise exception 'a path with no stored object must be refused';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000002/../escape.pdf',
      'escape.pdf', 'application/pdf', 1234, null
    );
    raise exception 'a traversal path must be refused';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000002/wrong-size.pdf',
      'wrong-size.pdf', 'application/pdf', 11, null
    );
    raise exception 'a size that disagrees with storage metadata must be refused';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000003',
      'c1000000-0000-0000-0000-000000000003/secret.pdf',
      'secret.pdf', 'application/pdf', 700, null
    );
    raise exception 'an owner must not register a file for another account';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.register_attachment(
      'c1000000-0000-0000-0000-000000000002',
      'c1000000-0000-0000-0000-000000000003/secret.pdf',
      'secret.pdf', 'application/pdf', 700, null
    );
    raise exception 'an owner must not point at another account''s folder';
  exception when invalid_parameter_value then null;
  end;

  perform public.test_assert(
    (select count(*) from public.attachments) = 3,
    'failed validation left the table unchanged'
  );
end;
$$;

-- 5. RLS: the owner sees their files, the other account sees none.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000003', true
);

do $$
begin
  perform public.test_assert(
    (select count(*) from public.attachments) = 0,
    'another account cannot read the owner''s attachment rows'
  );
  begin
    perform public.delete_attachment(
      (select id from public.attachments limit 1)
    );
    raise exception 'there is no row to delete, so this must fail';
  exception when no_data_found then null;
  end;
end;
$$;

-- The other account cannot insert metadata directly either.
do $$
begin
  begin
    insert into public.attachments (
      owner_profile_id, storage_path, file_name, mime_type, size_bytes, uploaded_by
    ) values (
      'c1000000-0000-0000-0000-000000000003',
      'c1000000-0000-0000-0000-000000000003/secret.pdf',
      'secret.pdf', 'application/pdf', 700,
      'c1000000-0000-0000-0000-000000000003'
    );
    raise exception 'direct metadata inserts must be denied';
  exception when insufficient_privilege then null;
  end;
end;
$$;

-- 6. The admin can register for someone else, replace, and delete; every action
--    is audited and the previous path is returned for object cleanup.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', true
);

select set_config(
  'surgo.test_admin_attachment',
  public.register_attachment(
    'c1000000-0000-0000-0000-000000000002',
    'c1000000-0000-0000-0000-000000000002/admin-upload.zip',
    'admin-upload.zip', 'application/zip', 5000, 'Added by staff'
  )::text,
  true
);

do $$
declare
  v_id uuid := current_setting('surgo.test_admin_attachment')::uuid;
  v_previous text;
begin
  perform public.test_assert(
    (select count(*) from public.attachments) = 4,
    'the admin can read every attachment row'
  );

  v_previous := public.replace_attachment(
    v_id,
    'c1000000-0000-0000-0000-000000000002/replacement.pdf',
    'replacement.pdf', 'application/pdf', 3000, null
  );
  perform public.test_assert(
    v_previous = 'c1000000-0000-0000-0000-000000000002/admin-upload.zip',
    'replace returns the previous path so the caller can delete the old object'
  );
  perform public.test_assert(
    (select storage_path from public.attachments where id = v_id) =
      'c1000000-0000-0000-0000-000000000002/replacement.pdf',
    'the row points at the replacement object'
  );
  perform public.test_assert(
    (select category from public.attachments where id = v_id) = 'document',
    'the category is recomputed from the replacement MIME type'
  );

  perform public.test_assert(
    public.delete_attachment(v_id) =
      'c1000000-0000-0000-0000-000000000002/replacement.pdf',
    'delete returns the path so the caller can remove the object'
  );
  perform public.test_assert(
    not exists (select 1 from public.attachments where id = v_id),
    'delete removes the metadata row'
  );
end;
$$;

-- 7. A non-admin cannot replace or delete someone else's row.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000003', true
);

do $$
declare
  v_id uuid;
begin
  select id into v_id from public.attachments limit 1;
  -- RLS hides the owner's rows, so resolve the id as the database owner would
  -- by using a fixture id fetched before the role switch.
  if v_id is null then
    v_id := current_setting('surgo.test_attachment')::uuid;
  end if;

  begin
    perform public.replace_attachment(
      v_id,
      'c1000000-0000-0000-0000-000000000003/secret.pdf',
      'secret.pdf', 'application/pdf', 700, null
    );
    raise exception 'a non-admin must not replace another account''s file';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.delete_attachment(v_id);
    raise exception 'a non-admin must not delete another account''s file';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;

do $$
begin
  perform public.test_assert(
    (select count(*) from public.attachments) = 3,
    'denied replace/delete calls left the owner rows intact'
  );

  -- Authenticated has no SELECT on the audit table, so audit assertions run
  -- only after the owner role is restored.
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'attachment.registered'
        and after_state ->> 'owner_profile_id' =
          'c1000000-0000-0000-0000-000000000002') = 1,
    'admin registration is audited'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'attachment.replaced') = 1,
    'admin replacement is audited'
  );
  perform public.test_assert(
    (select count(*) from public.admin_audit_logs
      where action = 'attachment.deleted') = 1,
    'admin deletion is audited'
  );
end;
$$;

rollback;
