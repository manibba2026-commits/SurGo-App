-- Status and type enums.
--
-- These mirror the Dart state machines in lib/state/*.dart. Keeping them as
-- Postgres enums means an invalid status is rejected by the database, not just
-- by the client, and makes the API self-documenting.

create type public.account_status as enum ('active', 'suspended');

-- Mirrors CapabilityType plus an admin role for the separate Next.js dashboard.
create type public.user_role_type as enum (
  'passenger',
  'earner',
  'rider',
  'vehicle_owner',
  'admin'
);

create type public.role_approval_status as enum (
  'pending',
  'approved',
  'suspended',
  'revoked'
);

create type public.provider_type as enum ('earner', 'vehicle_owner');

-- Mirrors EarnerCapability: what work an earner accepts.
create type public.earner_capability as enum (
  'rides',
  'errands',
  'deliveries'
);

create type public.vehicle_status as enum (
  'pending_verification',
  'active',
  'inactive',
  'suspended'
);

create type public.document_review_status as enum (
  'pending',
  'approved',
  'rejected',
  'expired'
);

create type public.verification_status as enum (
  'draft',
  'submitted',
  'under_review',
  'approved',
  'rejected',
  'needs_resubmission'
);

-- Mirrors RideStatus.
create type public.ride_status as enum (
  'searching',
  'awaiting_acceptance',
  'accepted',
  'heading_to_pickup',
  'arrived',
  'in_progress',
  'completed',
  'cancelled'
);

-- Mirrors RentalStatus.
create type public.rental_status as enum (
  'requested',
  'awaiting_owner',
  'accepted',
  'active',
  'returned',
  'completed',
  'declined',
  'cancelled'
);

-- Mirrors PasuyoStatus.
create type public.pasuyo_status as enum (
  'available',
  'accepted',
  'going_to_pickup',
  'at_pickup',
  'picked_up',
  'delivering',
  'at_customer',
  'delivered',
  'cancelled'
);

-- Mirrors PasuyoCategory.
create type public.pasuyo_category as enum (
  'groceries',
  'food_delivery',
  'pharmacy',
  'parcel',
  'laundry',
  'other'
);

create type public.service_type as enum ('ride', 'rental', 'pasuyo');

create type public.transaction_status as enum (
  'pending',
  'completed',
  'voided',
  'refunded',
  'failed'
);

create type public.wallet_account_type as enum (
  'passenger',
  'earner',
  'provider',
  'platform'
);

create type public.wallet_transaction_type as enum (
  'top_up',
  'earning',
  'payout',
  'platform_fee',
  'adjustment',
  'refund'
);

create type public.remittance_status as enum (
  'pending',
  'remitted',
  'overdue',
  'waived'
);

create type public.device_platform as enum ('android', 'ios', 'web');
