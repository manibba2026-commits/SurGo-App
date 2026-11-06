-- Service geography and pricing configuration.
--
-- Geography is seeded (Tandag City) by supabase/seed.sql. Pricing is NOT
-- seeded: the table exists so an approved policy can be activated later
-- without another schema change. `is_active` defaults to false and the
-- activation check below refuses an unapproved policy.

create table public.service_areas (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  city text not null check (length(trim(city)) > 0),
  province text not null check (length(trim(province)) > 0),
  country_code char(2) not null default 'PH',
  timezone text not null default 'Asia/Manila',
  center_latitude double precision not null
    check (center_latitude between -90 and 90),
  center_longitude double precision not null
    check (center_longitude between -180 and 180),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint service_areas_name_city_province_key unique (name, city, province)
);

comment on table public.service_areas is
  'Launch markets. The pilot is Tandag City, Surigao del Sur.';

create table public.barangays (
  id uuid primary key default gen_random_uuid(),
  service_area_id uuid not null
    references public.service_areas (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint barangays_service_area_name_key unique (service_area_id, name),
  -- Redundant unique key so child tables can enforce that a purok's barangay
  -- belongs to the same service area through a composite foreign key.
  constraint barangays_id_service_area_key unique (id, service_area_id)
);

create index barangays_service_area_idx
  on public.barangays (service_area_id);

create table public.puroks (
  id uuid primary key default gen_random_uuid(),
  barangay_id uuid not null
    references public.barangays (id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint puroks_barangay_name_key unique (barangay_id, name),
  -- Redundant unique key for composite FKs from ride/service requests.
  constraint puroks_id_barangay_key unique (id, barangay_id)
);

create index puroks_barangay_idx on public.puroks (barangay_id);

create table public.pricing_policies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  description text,
  service_type public.service_type not null,
  currency char(3) not null default 'PHP',
  base_fare_centavos bigint not null default 0 check (base_fare_centavos >= 0),
  per_km_centavos bigint not null default 0 check (per_km_centavos >= 0),
  per_minute_centavos bigint not null default 0
    check (per_minute_centavos >= 0),
  minimum_fare_centavos bigint not null default 0
    check (minimum_fare_centavos >= 0),
  -- Either a fixed customer-facing platform fee or a basis-point fee, or both.
  -- Both default to zero; no policy is activated by this migration or seed.
  platform_fee_fixed_centavos bigint not null default 0
    check (platform_fee_fixed_centavos >= 0),
  platform_fee_bps integer not null default 0
    check (platform_fee_bps between 0 and 10000),
  effective_from timestamptz,
  effective_to timestamptz,
  is_active boolean not null default false,
  approved_by uuid references auth.users (id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pricing_policies_effective_window_check
    check (effective_to is null or effective_from is null
      or effective_to > effective_from),
  -- Refuse to activate a policy nobody approved or scheduled.
  constraint pricing_policies_activation_requires_approval_check
    check (not is_active or (approved_at is not null and effective_from is not null)),
  constraint pricing_policies_minimum_not_below_base_check
    check (minimum_fare_centavos >= base_fare_centavos)
);

comment on table public.pricing_policies is
  'Configurable fare/fee policies. No row is seeded or activated; activate only after an approved pricing decision.';

-- At most one active policy per service type.
create unique index pricing_policies_one_active_per_service_idx
  on public.pricing_policies (service_type)
  where is_active;

create index pricing_policies_service_type_idx
  on public.pricing_policies (service_type, effective_from desc);

create trigger service_areas_set_updated_at
  before update on public.service_areas
  for each row execute function public.set_updated_at();

create trigger barangays_set_updated_at
  before update on public.barangays
  for each row execute function public.set_updated_at();

create trigger puroks_set_updated_at
  before update on public.puroks
  for each row execute function public.set_updated_at();

create trigger pricing_policies_set_updated_at
  before update on public.pricing_policies
  for each row execute function public.set_updated_at();
