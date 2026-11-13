-- Owner vehicle management and notification acknowledgements.
--
-- Two client write surfaces that were missing:
--   * notifications: a signed-in user can mark their own notifications read.
--   * vehicles: an approved vehicle owner can create or edit a listing and take
--     it off the rental catalogue without deleting rental history.
--
-- Both are SECURITY DEFINER RPCs. The tables remain SELECT-only for clients, so
-- a client cannot invent a row or rewrite someone else's. Vehicle photos live in
-- a private bucket and only their storage paths are kept on the vehicle row;
-- every preview uses a short-lived signed URL.

-- ---------------------------------------------------------------------------
-- 1. Vehicle photos
-- ---------------------------------------------------------------------------

alter table public.vehicles
  add column if not exists photo_paths text[] not null default '{}'::text[];

alter table public.vehicles
  drop constraint if exists vehicles_photo_paths_count_check;
alter table public.vehicles
  add constraint vehicles_photo_paths_count_check
  check (cardinality(photo_paths) <= 6);

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (
      id, name, public, file_size_limit, allowed_mime_types
    ) values (
      'vehicle-photos', 'vehicle-photos', false, 10485760,
      array['image/jpeg', 'image/png', 'image/webp']
    )
    on conflict (id) do update set
      public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
  end if;
end;
$$;

do $$
begin
  if to_regclass('storage.objects') is not null
     and to_regproc('storage.foldername') is not null then
    -- Listing photos are visible to any signed-in account. The bucket is still
    -- private: the client only gets a short-lived signed URL after RLS passes.
    drop policy if exists "surgo vehicle photos read" on storage.objects;
    create policy "surgo vehicle photos read"
      on storage.objects for select to authenticated
      using (bucket_id = 'vehicle-photos');

    -- Uploads stay under the owner's profile folder, matching the bucket
    -- convention used by avatars and documents.
    drop policy if exists "surgo vehicle photos insert own" on storage.objects;
    create policy "surgo vehicle photos insert own"
      on storage.objects for insert to authenticated
      with check (
        bucket_id = 'vehicle-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo vehicle photos update own" on storage.objects;
    create policy "surgo vehicle photos update own"
      on storage.objects for update to authenticated
      using (
        bucket_id = 'vehicle-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
      )
      with check (
        bucket_id = 'vehicle-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
      );

    drop policy if exists "surgo vehicle photos delete own" on storage.objects;
    create policy "surgo vehicle photos delete own"
      on storage.objects for delete to authenticated
      using (
        bucket_id = 'vehicle-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;
end;
$$;

-- A photo path is accepted only when it names a real object in the private
-- bucket and lives under the caller's own profile folder. The RPCs below use
-- this so a client cannot point a listing at another owner's file or at a path
-- that was never uploaded.
create or replace function public._vehicle_photo_path_valid(
  p_owner_profile_id uuid,
  p_path text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_owner_profile_id is not null
    and p_path is not null
    and length(p_path) between 3 and 1024
    and position('..' in p_path) = 0
    and position(chr(92) in p_path) = 0
    and left(p_path, length(p_owner_profile_id::text) + 1)
        = p_owner_profile_id::text || '/'
    and exists (
      select 1
        from storage.objects o
       where o.bucket_id = 'vehicle-photos'
         and o.name = p_path
    );
$$;

revoke all on function public._vehicle_photo_path_valid(uuid, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Owner vehicle RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_vehicle(
  p_name text,
  p_vehicle_type text,
  p_category text,
  p_plate_number text,
  p_price_per_day_centavos bigint,
  p_service_area_id uuid default null,
  p_make text default null,
  p_model text default null,
  p_model_year integer default null,
  p_color text default null,
  p_photo_paths text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_type text := nullif(trim(coalesce(p_vehicle_type, '')), '');
  v_plate text := upper(
    regexp_replace(trim(coalesce(p_plate_number, '')), '\s+', ' ', 'g')
  );
  v_area uuid := p_service_area_id;
  v_id uuid;
  v_path text;
begin
  if v_uid is null then
    raise exception 'Sign in to manage vehicles.' using errcode = '42501';
  end if;
  if not (
    public.has_approved_role('vehicle_owner')
    or public.has_approved_role('admin')
  ) then
    raise exception 'An approved vehicle owner account is required.'
      using errcode = '42501';
  end if;

  if v_name is null or length(v_name) > 120 then
    raise exception 'Enter a vehicle name of 120 characters or fewer.'
      using errcode = '22023';
  end if;
  if v_type is null or length(v_type) > 80 then
    raise exception 'Enter a vehicle type of 80 characters or fewer.'
      using errcode = '22023';
  end if;
  if p_category is null
     or p_category not in ('2-Wheel', '3-Wheel', '4-Wheel', 'Truck') then
    raise exception 'Choose a valid vehicle category.' using errcode = '22023';
  end if;
  if v_plate is null or length(v_plate) > 32 then
    raise exception 'Enter a plate number of 32 characters or fewer.'
      using errcode = '22023';
  end if;
  if p_price_per_day_centavos is null or p_price_per_day_centavos < 0 then
    raise exception 'The daily price cannot be negative.' using errcode = '22023';
  end if;
  if p_model_year is not null and (p_model_year < 1950 or p_model_year > 2100) then
    raise exception 'Enter a model year between 1950 and 2100.'
      using errcode = '22023';
  end if;
  if length(coalesce(p_make, '')) > 80
     or length(coalesce(p_model, '')) > 80
     or length(coalesce(p_color, '')) > 40 then
    raise exception 'Vehicle details are too long.' using errcode = '22023';
  end if;

  if v_area is null then
    select id into v_area
      from public.service_areas
     where is_active
     order by name
     limit 1;
  end if;
  if v_area is null
     or not exists (select 1 from public.service_areas where id = v_area) then
    raise exception 'Choose an active service area.' using errcode = '22023';
  end if;

  if p_photo_paths is not null then
    if cardinality(p_photo_paths) > 6 then
      raise exception 'A vehicle can have at most 6 photos.'
        using errcode = '22023';
    end if;
    foreach v_path in array p_photo_paths loop
      if not public._vehicle_photo_path_valid(v_uid, v_path) then
        raise exception 'A vehicle photo is missing or not yours.'
          using errcode = '22023';
      end if;
    end loop;
  end if;

  insert into public.vehicles (
    owner_profile_id, service_area_id, name, vehicle_type, category,
    make, model, model_year, color, plate_number,
    price_per_day_centavos, status, photo_paths
  ) values (
    v_uid, v_area, v_name, v_type, p_category,
    nullif(trim(coalesce(p_make, '')), ''),
    nullif(trim(coalesce(p_model, '')), ''),
    p_model_year,
    nullif(trim(coalesce(p_color, '')), ''),
    v_plate,
    p_price_per_day_centavos, 'active',
    coalesce(p_photo_paths, '{}'::text[])
  ) returning id into v_id;

  return v_id;
exception
  when unique_violation then
    raise exception 'That plate number is already listed in this service area.'
      using errcode = '23505';
end;
$$;

create or replace function public.update_vehicle(
  p_vehicle_id uuid,
  p_name text,
  p_vehicle_type text,
  p_category text,
  p_plate_number text,
  p_price_per_day_centavos bigint,
  p_service_area_id uuid default null,
  p_make text default null,
  p_model text default null,
  p_model_year integer default null,
  p_color text default null,
  p_listed boolean default null,
  p_photo_paths text[] default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_current public.vehicle_status;
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_type text := nullif(trim(coalesce(p_vehicle_type, '')), '');
  v_plate text := upper(
    regexp_replace(trim(coalesce(p_plate_number, '')), '\s+', ' ', 'g')
  );
  v_area uuid := p_service_area_id;
  v_path text;
begin
  if v_uid is null then
    raise exception 'Sign in to manage vehicles.' using errcode = '42501';
  end if;
  if not (
    public.has_approved_role('vehicle_owner')
    or public.has_approved_role('admin')
  ) then
    raise exception 'An approved vehicle owner account is required.'
      using errcode = '42501';
  end if;

  select status into v_current
    from public.vehicles
   where id = p_vehicle_id
     and owner_profile_id = v_uid
   for update;
  if not found then
    raise exception 'That vehicle is not in your fleet.' using errcode = 'P0002';
  end if;

  if v_name is null or length(v_name) > 120 then
    raise exception 'Enter a vehicle name of 120 characters or fewer.'
      using errcode = '22023';
  end if;
  if v_type is null or length(v_type) > 80 then
    raise exception 'Enter a vehicle type of 80 characters or fewer.'
      using errcode = '22023';
  end if;
  if p_category is null
     or p_category not in ('2-Wheel', '3-Wheel', '4-Wheel', 'Truck') then
    raise exception 'Choose a valid vehicle category.' using errcode = '22023';
  end if;
  if v_plate is null or length(v_plate) > 32 then
    raise exception 'Enter a plate number of 32 characters or fewer.'
      using errcode = '22023';
  end if;
  if p_price_per_day_centavos is null or p_price_per_day_centavos < 0 then
    raise exception 'The daily price cannot be negative.' using errcode = '22023';
  end if;
  if p_model_year is not null and (p_model_year < 1950 or p_model_year > 2100) then
    raise exception 'Enter a model year between 1950 and 2100.'
      using errcode = '22023';
  end if;
  if length(coalesce(p_make, '')) > 80
     or length(coalesce(p_model, '')) > 80
     or length(coalesce(p_color, '')) > 40 then
    raise exception 'Vehicle details are too long.' using errcode = '22023';
  end if;

  if p_listed is true and v_current not in ('active', 'inactive') then
    raise exception 'This vehicle cannot be listed until its review is complete.'
      using errcode = '22023';
  end if;

  if v_area is null then
    select service_area_id into v_area
      from public.vehicles
     where id = p_vehicle_id;
  end if;
  if v_area is null then
    select id into v_area
      from public.service_areas
     where is_active
     order by name
     limit 1;
  end if;
  if v_area is null
     or not exists (select 1 from public.service_areas where id = v_area) then
    raise exception 'Choose an active service area.' using errcode = '22023';
  end if;

  if p_photo_paths is not null then
    if cardinality(p_photo_paths) > 6 then
      raise exception 'A vehicle can have at most 6 photos.'
        using errcode = '22023';
    end if;
    foreach v_path in array p_photo_paths loop
      if not public._vehicle_photo_path_valid(v_uid, v_path) then
        raise exception 'A vehicle photo is missing or not yours.'
          using errcode = '22023';
      end if;
    end loop;
  end if;

  update public.vehicles
     set service_area_id = v_area,
         name = v_name,
         vehicle_type = v_type,
         category = p_category,
         make = nullif(trim(coalesce(p_make, '')), ''),
         model = nullif(trim(coalesce(p_model, '')), ''),
         model_year = p_model_year,
         color = nullif(trim(coalesce(p_color, '')), ''),
         plate_number = v_plate,
         price_per_day_centavos = p_price_per_day_centavos,
         status = case
           when p_listed is null then status
           when p_listed then 'active'::public.vehicle_status
           when v_current in ('pending_verification', 'suspended') then v_current
           else 'inactive'::public.vehicle_status
         end,
         photo_paths = coalesce(p_photo_paths, photo_paths),
         updated_at = now()
   where id = p_vehicle_id
     and owner_profile_id = v_uid;
exception
  when unique_violation then
    raise exception 'That plate number is already listed in this service area.'
      using errcode = '23505';
end;
$$;

-- A small, separate action for the fleet card's availability toggle. Editing
-- details should not be able to unlist a vehicle as a side effect.
create or replace function public.set_vehicle_listing(
  p_vehicle_id uuid,
  p_listed boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_current public.vehicle_status;
begin
  if v_uid is null then
    raise exception 'Sign in to manage vehicles.' using errcode = '42501';
  end if;
  if not (
    public.has_approved_role('vehicle_owner')
    or public.has_approved_role('admin')
  ) then
    raise exception 'An approved vehicle owner account is required.'
      using errcode = '42501';
  end if;
  if p_listed is null then
    raise exception 'Choose whether the vehicle is listed.'
      using errcode = '22023';
  end if;

  select status into v_current
    from public.vehicles
   where id = p_vehicle_id
     and owner_profile_id = v_uid
   for update;
  if not found then
    raise exception 'That vehicle is not in your fleet.' using errcode = 'P0002';
  end if;

  if p_listed and v_current not in ('active', 'inactive') then
    raise exception 'This vehicle cannot be listed until its review is complete.'
      using errcode = '22023';
  end if;

  update public.vehicles
     set status = case
           when p_listed then 'active'::public.vehicle_status
           when v_current in ('pending_verification', 'suspended') then v_current
           else 'inactive'::public.vehicle_status
         end,
         updated_at = now()
   where id = p_vehicle_id
     and owner_profile_id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Notification acknowledgements
-- ---------------------------------------------------------------------------

create or replace function public.mark_notification_read(
  p_notification_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'Sign in to update notifications.' using errcode = '42501';
  end if;

  -- The profile predicate is the authorization check: a notification id from
  -- another account matches no row, so the caller cannot probe or rewrite it.
  update public.notifications
     set read_at = coalesce(read_at, now())
   where id = p_notification_id
     and profile_id = auth.uid();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'Sign in to update notifications.' using errcode = '42501';
  end if;

  update public.notifications
     set read_at = now()
   where profile_id = auth.uid()
     and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges
-- ---------------------------------------------------------------------------

revoke all on function public.create_vehicle(
  text, text, text, text, bigint, uuid, text, text, integer, text, text[]
) from public, anon, authenticated;
grant execute on function public.create_vehicle(
  text, text, text, text, bigint, uuid, text, text, integer, text, text[]
) to authenticated, service_role;

revoke all on function public.update_vehicle(
  uuid, text, text, text, text, bigint, uuid, text, text, integer, text, boolean,
  text[]
) from public, anon, authenticated;
grant execute on function public.update_vehicle(
  uuid, text, text, text, text, bigint, uuid, text, text, integer, text, boolean,
  text[]
) to authenticated, service_role;

revoke all on function public.set_vehicle_listing(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.set_vehicle_listing(uuid, boolean)
  to authenticated, service_role;

revoke all on function public.mark_notification_read(uuid)
  from public, anon, authenticated;
grant execute on function public.mark_notification_read(uuid)
  to authenticated, service_role;

revoke all on function public.mark_all_notifications_read()
  from public, anon, authenticated;
grant execute on function public.mark_all_notifications_read()
  to authenticated, service_role;
