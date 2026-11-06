-- Ride lifecycle: requests, append-only status history, GPS breadcrumbs, ratings.

create table public.ride_requests (
  id uuid primary key default gen_random_uuid(),
  passenger_id uuid not null references public.profiles (id) on delete restrict,
  rider_id uuid references public.profiles (id) on delete set null,
  service_area_id uuid not null
    references public.service_areas (id) on delete restrict,
  status public.ride_status not null default 'searching',

  pickup_address text not null check (length(trim(pickup_address)) > 0),
  pickup_barangay_id uuid not null,
  pickup_purok_id uuid,
  pickup_latitude double precision check (pickup_latitude between -90 and 90),
  pickup_longitude double precision check (pickup_longitude between -180 and 180),

  dropoff_address text not null check (length(trim(dropoff_address)) > 0),
  dropoff_barangay_id uuid,
  dropoff_purok_id uuid,
  dropoff_latitude double precision check (dropoff_latitude between -90 and 90),
  dropoff_longitude double precision check (dropoff_longitude between -180 and 180),

  distance_km numeric(8, 2) not null default 0 check (distance_km >= 0),
  eta_minutes integer not null default 0 check (eta_minutes >= 0),
  fare_centavos bigint not null default 0 check (fare_centavos >= 0),
  platform_fee_centavos bigint not null default 0
    check (platform_fee_centavos >= 0),
  payment_method text not null default 'cash' check (payment_method = 'cash'),
  note text,

  requested_at timestamptz not null default now(),
  accepted_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Composite FKs keep purok -> barangay -> service area consistent.
  constraint ride_requests_pickup_barangay_fkey
    foreign key (pickup_barangay_id, service_area_id)
    references public.barangays (id, service_area_id),
  constraint ride_requests_pickup_purok_fkey
    foreign key (pickup_purok_id, pickup_barangay_id)
    references public.puroks (id, barangay_id),
  constraint ride_requests_dropoff_barangay_fkey
    foreign key (dropoff_barangay_id, service_area_id)
    references public.barangays (id, service_area_id),
  constraint ride_requests_dropoff_purok_fkey
    foreign key (dropoff_purok_id, dropoff_barangay_id)
    references public.puroks (id, barangay_id),

  constraint ride_requests_passenger_is_not_rider_check
    check (rider_id is null or rider_id <> passenger_id),
  constraint ride_requests_rider_required_after_accept_check
    check (status in ('searching', 'awaiting_acceptance', 'cancelled')
      or rider_id is not null),
  constraint ride_requests_accepted_timestamp_check
    check (status not in ('accepted', 'heading_to_pickup', 'arrived',
      'in_progress', 'completed') or accepted_at is not null),
  constraint ride_requests_started_timestamp_check
    check (status not in ('in_progress', 'completed') or started_at is not null),
  constraint ride_requests_completed_timestamp_check
    check (status <> 'completed' or completed_at is not null),
  constraint ride_requests_cancelled_timestamp_check
    check (status <> 'cancelled' or cancelled_at is not null)
);

create index ride_requests_passenger_idx
  on public.ride_requests (passenger_id, requested_at desc);

create index ride_requests_rider_idx
  on public.ride_requests (rider_id, requested_at desc)
  where rider_id is not null;

create index ride_requests_open_pool_idx
  on public.ride_requests (service_area_id, requested_at)
  where status in ('searching', 'awaiting_acceptance');

create index ride_requests_status_idx on public.ride_requests (status);

create table public.ride_status_events (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.ride_requests (id) on delete cascade,
  status public.ride_status not null,
  actor_profile_id uuid references public.profiles (id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index ride_status_events_ride_idx
  on public.ride_status_events (ride_id, created_at);

create table public.ride_locations (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.ride_requests (id) on delete cascade,
  rider_id uuid references public.profiles (id) on delete set null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  heading_degrees numeric(5, 2) check (heading_degrees between 0 and 360),
  speed_kph numeric(6, 2) check (speed_kph >= 0),
  recorded_at timestamptz not null default now()
);

create index ride_locations_ride_idx
  on public.ride_locations (ride_id, recorded_at desc);

create table public.ride_ratings (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null unique
    references public.ride_requests (id) on delete cascade,
  rater_id uuid not null references public.profiles (id) on delete restrict,
  ratee_id uuid not null references public.profiles (id) on delete restrict,
  stars smallint not null check (stars between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  constraint ride_ratings_rater_is_not_ratee_check check (rater_id <> ratee_id)
);

create index ride_ratings_ratee_idx on public.ride_ratings (ratee_id);

create trigger ride_requests_set_updated_at
  before update on public.ride_requests
  for each row execute function public.set_updated_at();
