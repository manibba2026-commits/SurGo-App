-- Keep public.profiles in sync with auth.users.
--
-- Supabase Auth owns credentials; this trigger gives every new user a profile
-- and an approved passenger role. Provider roles are granted later by the
-- verification flow, so this trigger never elevates anyone beyond passenger.

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name text;
  v_first_name text;
begin
  v_first_name := nullif(trim(coalesce(
    new.raw_user_meta_data ->> 'given_name',
    new.raw_user_meta_data ->> 'first_name'
  )), '');

  v_full_name := nullif(trim(coalesce(
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    concat_ws(
      ' ',
      new.raw_user_meta_data ->> 'given_name',
      new.raw_user_meta_data ->> 'family_name'
    )
  )), '');

  if v_full_name is null then
    v_full_name := coalesce(
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      nullif(new.phone, ''),
      'SurGo User'
    );
  end if;

  insert into public.profiles (id, full_name, first_name, email, phone)
  values (new.id, v_full_name, v_first_name, new.email, new.phone)
  on conflict (id) do nothing;

  insert into public.user_roles (profile_id, role, status, approved_at)
  values (new.id, 'passenger', 'approved', now())
  on conflict (profile_id, role) do nothing;

  return new;
end;
$$;

comment on function public.handle_new_auth_user() is
  'Creates the matching profile and an approved passenger role for a new auth.users row.';

create or replace function public.handle_auth_user_updated()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set email = new.email,
         phone = new.phone,
         full_name = coalesce(
           nullif(trim(coalesce(
             new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name'
           )), ''),
           full_name
         )
   where id = new.id;

  return new;
end;
$$;

comment on function public.handle_auth_user_updated() is
  'Mirrors auth.users email, phone and name changes onto public.profiles.';

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update of email, phone, raw_user_meta_data on auth.users
  for each row execute function public.handle_auth_user_updated();
