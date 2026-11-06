-- Money: service settlement, wallet ledger and cash platform-fee remittances.
--
-- Invariants enforced here:
--   * customer_pays = fare + platform_fee
--   * provider_payout + platform_revenue = customer_pays
--   * provider_payout <= fare  (the provider keeps up to 100% of the agreed
--     fare; this schema does not bake in a commission percentage)
--   * cash is the only payment method for the pilot
--   * one settlement row per ride / rental / service request

create table public.service_transactions (
  id uuid primary key default gen_random_uuid(),
  service_type public.service_type not null,
  ride_id uuid references public.ride_requests (id) on delete restrict,
  rental_id uuid references public.rental_bookings (id) on delete restrict,
  service_request_id uuid references public.service_requests (id)
    on delete restrict,
  customer_id uuid not null references public.profiles (id) on delete restrict,
  provider_id uuid not null references public.profiles (id) on delete restrict,
  currency char(3) not null default 'PHP',
  fare_centavos bigint not null check (fare_centavos >= 0),
  platform_fee_centavos bigint not null default 0
    check (platform_fee_centavos >= 0),
  customer_pays_centavos bigint not null check (customer_pays_centavos >= 0),
  provider_payout_centavos bigint not null
    check (provider_payout_centavos >= 0),
  platform_revenue_centavos bigint not null
    check (platform_revenue_centavos >= 0),
  payment_method text not null default 'cash' check (payment_method = 'cash'),
  status public.transaction_status not null default 'pending',
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint service_transactions_one_service_check check (
    (service_type = 'ride' and ride_id is not null
      and rental_id is null and service_request_id is null)
    or (service_type = 'rental' and rental_id is not null
      and ride_id is null and service_request_id is null)
    or (service_type = 'pasuyo' and service_request_id is not null
      and ride_id is null and rental_id is null)
  ),
  constraint service_transactions_party_check
    check (customer_id <> provider_id),
  constraint service_transactions_total_check
    check (customer_pays_centavos = fare_centavos + platform_fee_centavos),
  constraint service_transactions_conservation_check
    check (provider_payout_centavos + platform_revenue_centavos
      = customer_pays_centavos),
  constraint service_transactions_payout_within_fare_check
    check (provider_payout_centavos <= fare_centavos),
  constraint service_transactions_settled_timestamp_check
    check (status <> 'completed' or settled_at is not null)
);

-- Double-settlement guards.
create unique index service_transactions_ride_key
  on public.service_transactions (ride_id)
  where ride_id is not null;

create unique index service_transactions_rental_key
  on public.service_transactions (rental_id)
  where rental_id is not null;

create unique index service_transactions_service_request_key
  on public.service_transactions (service_request_id)
  where service_request_id is not null;

create index service_transactions_customer_idx
  on public.service_transactions (customer_id, created_at desc);

create index service_transactions_provider_idx
  on public.service_transactions (provider_id, created_at desc);

create index service_transactions_status_idx
  on public.service_transactions (status, created_at);

create table public.wallet_accounts (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles (id) on delete restrict,
  account_type public.wallet_account_type not null,
  currency char(3) not null default 'PHP',
  balance_centavos bigint not null default 0 check (balance_centavos >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint wallet_accounts_owner_check
    check (account_type = 'platform' or profile_id is not null)
);

create unique index wallet_accounts_profile_type_key
  on public.wallet_accounts (profile_id, account_type)
  where profile_id is not null;

create unique index wallet_accounts_platform_key
  on public.wallet_accounts (account_type)
  where account_type = 'platform';

create index wallet_accounts_profile_idx
  on public.wallet_accounts (profile_id)
  where profile_id is not null;

create table public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  wallet_account_id uuid not null
    references public.wallet_accounts (id) on delete restrict,
  transaction_type public.wallet_transaction_type not null,
  direction text not null check (direction in ('credit', 'debit')),
  amount_centavos bigint not null check (amount_centavos > 0),
  balance_after_centavos bigint not null check (balance_after_centavos >= 0),
  service_transaction_id uuid
    references public.service_transactions (id) on delete set null,
  external_reference text,
  description text,
  created_at timestamptz not null default now()
);

create index wallet_transactions_account_idx
  on public.wallet_transactions (wallet_account_id, created_at desc);

create index wallet_transactions_service_idx
  on public.wallet_transactions (service_transaction_id)
  where service_transaction_id is not null;

create table public.cash_fee_remittances (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.profiles (id) on delete restrict,
  service_transaction_id uuid
    references public.service_transactions (id) on delete restrict,
  currency char(3) not null default 'PHP',
  amount_centavos bigint not null check (amount_centavos > 0),
  status public.remittance_status not null default 'pending',
  due_at timestamptz not null,
  remitted_at timestamptz,
  remitted_to_profile_id uuid references public.profiles (id)
    on delete set null,
  reference_number text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cash_fee_remittances_remitted_timestamp_check
    check (status <> 'remitted' or remitted_at is not null)
);

create unique index cash_fee_remittances_transaction_key
  on public.cash_fee_remittances (service_transaction_id)
  where service_transaction_id is not null;

create index cash_fee_remittances_provider_idx
  on public.cash_fee_remittances (provider_id, status, due_at);

create index cash_fee_remittances_due_idx
  on public.cash_fee_remittances (status, due_at)
  where status in ('pending', 'overdue');

create trigger service_transactions_set_updated_at
  before update on public.service_transactions
  for each row execute function public.set_updated_at();

create trigger wallet_accounts_set_updated_at
  before update on public.wallet_accounts
  for each row execute function public.set_updated_at();

create trigger cash_fee_remittances_set_updated_at
  before update on public.cash_fee_remittances
  for each row execute function public.set_updated_at();
