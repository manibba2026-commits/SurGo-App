-- Vehicle rental bookings.

-- Redundant key so a booking's owner must actually own the booked vehicle.
alter table public.vehicles
  add constraint vehicles_id_owner_key unique (id, owner_profile_id);

create table public.rental_bookings (
  id uuid primary key default gen_random_uuid(),
  renter_id uuid not null references public.profiles (id) on delete restrict,
  owner_id uuid not null references public.profiles (id) on delete restrict,
  vehicle_id uuid not null,
  service_area_id uuid not null
    references public.service_areas (id) on delete restrict,
  status public.rental_status not null default 'requested',

  start_at timestamptz not null,
  end_at timestamptz not null,
  duration_hours integer check (duration_hours > 0),

  pickup_location text,
  pickup_barangay_id uuid,
  pickup_purok_id uuid,
  pickup_latitude double precision check (pickup_latitude between -90 and 90),
  pickup_longitude double precision check (pickup_longitude between -180 and 180),
  current_location text,
  vehicle_latitude double precision check (vehicle_latitude between -90 and 90),
  vehicle_longitude double precision check (vehicle_longitude between -180 and 180),

  total_fare_centavos bigint not null default 0
    check (total_fare_centavos >= 0),
  platform_fee_centavos bigint not null default 0
    check (platform_fee_centavos >= 0),
  payment_method text not null default 'cash' check (payment_method = 'cash'),

  accepted_at timestamptz,
  started_at timestamptz,
  returned_at timestamptz,
  completed_at timestamptz,
  declined_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint rental_bookings_vehicle_owner_fkey
    foreign key (vehicle_id, owner_id)
    references public.vehicles (id, owner_profile_id)
    on delete restrict,
  constraint rental_bookings_pickup_barangay_fkey
    foreign key (pickup_barangay_id, service_area_id)
    references public.barangays (id, service_area_id),
  constraint rental_bookings_pickup_purok_fkey
    foreign key (pickup_purok_id, pickup_barangay_id)
    references public.puroks (id, barangay_id),

  constraint rental_bookings_window_check check (end_at > start_at),
  constraint rental_bookings_renter_is_not_owner_check check (renter_id <> owner_id),
  constraint rental_bookings_accepted_timestamp_check
    check (status not in ('accepted', 'active', 'returned', 'completed')
      or accepted_at is not null),
  constraint rental_bookings_started_timestamp_check
    check (status not in ('active', 'returned', 'completed') or started_at is not null),
  constraint rental_bookings_returned_timestamp_check
    check (status not in ('returned', 'completed') or returned_at is not null),
  constraint rental_bookings_completed_timestamp_check
    check (status <> 'completed' or completed_at is not null),
  constraint rental_bookings_declined_timestamp_check
    check (status <> 'declined' or declined_at is not null),
  constraint rental_bookings_cancelled_timestamp_check
    check (status <> 'cancelled' or cancelled_at is not null)
);

create index rental_bookings_renter_idx
  on public.rental_bookings (renter_id, start_at desc);

create index rental_bookings_owner_idx
  on public.rental_bookings (owner_id, start_at desc);

create index rental_bookings_vehicle_idx
  on public.rental_bookings (vehicle_id, start_at desc);

create index rental_bookings_status_idx on public.rental_bookings (status);

create trigger rental_bookings_set_updated_at
  before update on public.rental_bookings
  for each row execute function public.set_updated_at();
