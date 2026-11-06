-- Identity, provider profiles, vehicles and verification.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null check (length(trim(full_name)) > 0),
  first_name text,
  email text,
  phone text,
  avatar_path text,
  account_status public.account_status not null default 'active',
  rating numeric(3, 2) not null default 5.00 check (rating between 1 and 5),
  total_rides integer not null default 0 check (total_rides >= 0),
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'One row per auth.users row. Public identity lives here; credentials stay in auth.users.';

create unique index profiles_email_key
  on public.profiles (lower(email))
  where email is not null;

create unique index profiles_phone_key
  on public.profiles (phone)
  where phone is not null;

create index profiles_account_status_idx on public.profiles (account_status);

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  role public.user_role_type not null,
  status public.role_approval_status not null default 'pending',
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_roles_profile_role_key unique (profile_id, role),
  constraint user_roles_approval_timestamp_check
    check (status <> 'approved' or approved_at is not null)
);

create index user_roles_role_status_idx on public.user_roles (role, status);

create table public.provider_profiles (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles (id) on delete cascade,
  provider_type public.provider_type not null,
  service_area_id uuid references public.service_areas (id) on delete restrict,
  display_name text,
  bio text,
  -- Earners only. Owners operate vehicles and leave this empty.
  capabilities public.earner_capability[] not null default '{}',
  is_available boolean not null default false,
  rating numeric(3, 2) not null default 5.00 check (rating between 1 and 5),
  total_trips integer not null default 0 check (total_trips >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provider_profiles_capabilities_check
    check (provider_type = 'vehicle_owner' or cardinality(capabilities) > 0)
);

create index provider_profiles_service_area_idx
  on public.provider_profiles (service_area_id)
  where service_area_id is not null;

create index provider_profiles_available_idx
  on public.provider_profiles (provider_type, service_area_id)
  where is_available;

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles (id) on delete cascade,
  service_area_id uuid references public.service_areas (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  vehicle_type text not null check (length(trim(vehicle_type)) > 0),
  category text not null check (category in ('2-Wheel', '3-Wheel', '4-Wheel', 'Truck')),
  make text,
  model text,
  model_year integer check (model_year between 1950 and 2100),
  color text,
  plate_number text not null check (length(trim(plate_number)) > 0),
  price_per_day_centavos bigint not null default 0
    check (price_per_day_centavos >= 0),
  status public.vehicle_status not null default 'pending_verification',
  rating numeric(3, 2) not null default 5.00 check (rating between 1 and 5),
  total_rentals integer not null default 0 check (total_rentals >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index vehicles_plate_per_area_key
  on public.vehicles (service_area_id, upper(plate_number))
  where service_area_id is not null;

create index vehicles_owner_idx on public.vehicles (owner_profile_id);
create index vehicles_listing_idx
  on public.vehicles (service_area_id, status)
  where status = 'active';

create table public.vehicle_documents (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  document_type text not null check (length(trim(document_type)) > 0),
  document_number text,
  storage_path text,
  issued_at date,
  expires_at date,
  status public.document_review_status not null default 'pending',
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vehicle_documents_type_key unique (vehicle_id, document_type),
  constraint vehicle_documents_expiry_check
    check (expires_at is null or issued_at is null or expires_at > issued_at),
  constraint vehicle_documents_review_timestamp_check
    check (status in ('pending', 'expired') or reviewed_at is not null)
);

create index vehicle_documents_vehicle_idx on public.vehicle_documents (vehicle_id);
create index vehicle_documents_status_idx on public.vehicle_documents (status);

create table public.verification_applications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  capability_type public.user_role_type not null,
  status public.verification_status not null default 'draft',
  submitted_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  decided_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint verification_applications_capability_check
    check (capability_type in ('earner', 'rider', 'vehicle_owner')),
  constraint verification_applications_submitted_timestamp_check
    check (status = 'draft' or submitted_at is not null),
  constraint verification_applications_decided_timestamp_check
    check (status not in ('approved', 'rejected') or decided_at is not null)
);

-- One open application per profile and capability; history rows may pile up.
create unique index verification_applications_open_key
  on public.verification_applications (profile_id, capability_type)
  where status in ('draft', 'submitted', 'under_review', 'needs_resubmission');

create index verification_applications_status_idx
  on public.verification_applications (status, created_at);

create table public.verification_documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null
    references public.verification_applications (id) on delete cascade,
  document_type text not null check (length(trim(document_type)) > 0),
  label text,
  document_number text,
  storage_path text,
  expires_at date,
  is_required boolean not null default true,
  status public.document_review_status not null default 'pending',
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint verification_documents_type_key unique (application_id, document_type),
  constraint verification_documents_review_timestamp_check
    check (status in ('pending', 'expired') or reviewed_at is not null)
);

create index verification_documents_application_idx
  on public.verification_documents (application_id);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger user_roles_set_updated_at
  before update on public.user_roles
  for each row execute function public.set_updated_at();

create trigger provider_profiles_set_updated_at
  before update on public.provider_profiles
  for each row execute function public.set_updated_at();

create trigger vehicles_set_updated_at
  before update on public.vehicles
  for each row execute function public.set_updated_at();

create trigger vehicle_documents_set_updated_at
  before update on public.vehicle_documents
  for each row execute function public.set_updated_at();

create trigger verification_applications_set_updated_at
  before update on public.verification_applications
  for each row execute function public.set_updated_at();

create trigger verification_documents_set_updated_at
  before update on public.verification_documents
  for each row execute function public.set_updated_at();
