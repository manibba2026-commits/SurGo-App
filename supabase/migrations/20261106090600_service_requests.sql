-- Pasuyo errands: requests, line items and append-only status history.

create table public.service_requests (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles (id) on delete restrict,
  provider_id uuid references public.profiles (id) on delete set null,
  service_area_id uuid not null
    references public.service_areas (id) on delete restrict,
  category public.pasuyo_category not null,
  status public.pasuyo_status not null default 'available',

  title text not null check (length(trim(title)) > 0),
  description text,

  pickup_address text not null check (length(trim(pickup_address)) > 0),
  pickup_barangay_id uuid not null,
  pickup_purok_id uuid,
  pickup_latitude double precision check (pickup_latitude between -90 and 90),
  pickup_longitude double precision check (pickup_longitude between -180 and 180),

  dropoff_address text,
  dropoff_barangay_id uuid,
  dropoff_purok_id uuid,
  dropoff_latitude double precision check (dropoff_latitude between -90 and 90),
  dropoff_longitude double precision check (dropoff_longitude between -180 and 180),

  budget_centavos bigint check (budget_centavos >= 0),
  quoted_fee_centavos bigint not null default 0
    check (quoted_fee_centavos >= 0),
  platform_fee_centavos bigint not null default 0
    check (platform_fee_centavos >= 0),
  payment_method text not null default 'cash' check (payment_method = 'cash'),

  requested_at timestamptz not null default now(),
  accepted_at timestamptz,
  picked_up_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint service_requests_pickup_barangay_fkey
    foreign key (pickup_barangay_id, service_area_id)
    references public.barangays (id, service_area_id),
  constraint service_requests_pickup_purok_fkey
    foreign key (pickup_purok_id, pickup_barangay_id)
    references public.puroks (id, barangay_id),
  constraint service_requests_dropoff_barangay_fkey
    foreign key (dropoff_barangay_id, service_area_id)
    references public.barangays (id, service_area_id),
  constraint service_requests_dropoff_purok_fkey
    foreign key (dropoff_purok_id, dropoff_barangay_id)
    references public.puroks (id, barangay_id),

  constraint service_requests_customer_is_not_provider_check
    check (provider_id is null or provider_id <> customer_id),
  constraint service_requests_provider_required_after_accept_check
    check (status in ('available', 'cancelled') or provider_id is not null),
  constraint service_requests_accepted_timestamp_check
    check (status not in ('accepted', 'going_to_pickup', 'at_pickup', 'picked_up',
      'delivering', 'at_customer', 'delivered') or accepted_at is not null),
  constraint service_requests_picked_up_timestamp_check
    check (status not in ('picked_up', 'delivering', 'at_customer', 'delivered')
      or picked_up_at is not null),
  constraint service_requests_delivered_timestamp_check
    check (status <> 'delivered' or delivered_at is not null),
  constraint service_requests_cancelled_timestamp_check
    check (status <> 'cancelled' or cancelled_at is not null)
);

create index service_requests_customer_idx
  on public.service_requests (customer_id, requested_at desc);

create index service_requests_provider_idx
  on public.service_requests (provider_id, requested_at desc)
  where provider_id is not null;

create index service_requests_open_pool_idx
  on public.service_requests (service_area_id, category, requested_at)
  where status = 'available';

create index service_requests_status_idx on public.service_requests (status);

create table public.service_request_items (
  id uuid primary key default gen_random_uuid(),
  service_request_id uuid not null
    references public.service_requests (id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  quantity numeric(10, 2) not null default 1 check (quantity > 0),
  unit text,
  estimated_unit_price_centavos bigint
    check (estimated_unit_price_centavos >= 0),
  actual_unit_price_centavos bigint
    check (actual_unit_price_centavos >= 0),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_request_items_request_idx
  on public.service_request_items (service_request_id);

create table public.service_status_events (
  id uuid primary key default gen_random_uuid(),
  service_request_id uuid not null
    references public.service_requests (id) on delete cascade,
  status public.pasuyo_status not null,
  actor_profile_id uuid references public.profiles (id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index service_status_events_request_idx
  on public.service_status_events (service_request_id, created_at);

create trigger service_requests_set_updated_at
  before update on public.service_requests
  for each row execute function public.set_updated_at();

create trigger service_request_items_set_updated_at
  before update on public.service_request_items
  for each row execute function public.set_updated_at();
