-- Cash collection, disputes, receivables and remittance records.
--
-- Cash received by the provider is never automatically treated as cash
-- received by SurGo. The provider's platform fee remains a receivable until a
-- remittance is verified by an admin. Real top-ups/withdrawals stay disabled.

create type public.cash_collection_status as enum (
  'pending',
  'confirmed',
  'failed'
);

create type public.cash_dispute_status as enum (
  'open',
  'under_review',
  'resolved',
  'rejected',
  'withdrawn'
);

create type public.platform_fee_receivable_status as enum (
  'open',
  'partially_remitted',
  'remitted',
  'waived',
  'disputed'
);

create type public.fee_remittance_status as enum (
  'submitted',
  'verified',
  'rejected',
  'cancelled'
);

-- Immutable pricing snapshot attached to each settlement.
alter table public.service_transactions
  add column pricing_policy_id uuid
    references public.pricing_policies (id) on delete restrict,
  add column pricing_policy_version integer,
  add column fee_mode public.platform_fee_mode not null default 'customer_addon',
  add column fee_type public.platform_fee_type not null default 'fixed',
  add column distance_km numeric(8, 2) not null default 0
    check (distance_km >= 0),
  add column duration_minutes integer not null default 0
    check (duration_minutes >= 0),
  add column pricing_snapshot jsonb not null default '{}'::jsonb;

comment on column public.service_transactions.pricing_snapshot is
  'Immutable copy of the policy terms and computed amounts used at settlement.';

-- The legacy total check assumed the fee was always added on top of the fare.
-- A provider_deduction fee is already inside the fare, so the customer pays the
-- fare only. Conservation (payout + revenue = customer pays) still holds.
alter table public.service_transactions
  drop constraint service_transactions_total_check;

alter table public.service_transactions
  add constraint service_transactions_total_check check (
    (fee_mode = 'customer_addon'
      and customer_pays_centavos = fare_centavos + platform_fee_centavos)
    or (fee_mode = 'provider_deduction'
      and customer_pays_centavos = fare_centavos)
  );

create index service_transactions_policy_idx
  on public.service_transactions (pricing_policy_id, pricing_policy_version)
  where pricing_policy_id is not null;

create or replace function public.guard_settled_transaction_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'completed' then
    if new.service_type is distinct from old.service_type
       or new.ride_id is distinct from old.ride_id
       or new.rental_id is distinct from old.rental_id
       or new.service_request_id is distinct from old.service_request_id
       or new.customer_id is distinct from old.customer_id
       or new.provider_id is distinct from old.provider_id
       or new.currency is distinct from old.currency
       or new.fare_centavos is distinct from old.fare_centavos
       or new.platform_fee_centavos
            is distinct from old.platform_fee_centavos
       or new.customer_pays_centavos
            is distinct from old.customer_pays_centavos
       or new.provider_payout_centavos
            is distinct from old.provider_payout_centavos
       or new.platform_revenue_centavos
            is distinct from old.platform_revenue_centavos
       or new.payment_method is distinct from old.payment_method
       or new.pricing_policy_id is distinct from old.pricing_policy_id
       or new.pricing_policy_version
            is distinct from old.pricing_policy_version
       or new.fee_mode is distinct from old.fee_mode
       or new.fee_type is distinct from old.fee_type
       or new.distance_km is distinct from old.distance_km
       or new.duration_minutes is distinct from old.duration_minutes
       or new.pricing_snapshot is distinct from old.pricing_snapshot
    then
      raise exception
        'Completed transaction financial snapshots are immutable'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.guard_settled_transaction_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'completed' then
    raise exception 'Completed service transactions cannot be deleted'
      using errcode = 'P0001';
  end if;
  return old;
end;
$$;

create trigger service_transactions_guard_snapshot
  before update on public.service_transactions
  for each row execute function public.guard_settled_transaction_snapshot();

create trigger service_transactions_guard_delete
  before delete on public.service_transactions
  for each row execute function public.guard_settled_transaction_delete();

create table public.cash_collections (
  id uuid primary key default gen_random_uuid(),
  service_transaction_id uuid not null unique
    references public.service_transactions (id) on delete restrict,
  customer_id uuid not null references public.profiles (id) on delete restrict,
  provider_id uuid not null references public.profiles (id) on delete restrict,
  amount_expected_centavos bigint not null
    check (amount_expected_centavos >= 0),
  amount_collected_centavos bigint not null default 0
    check (amount_collected_centavos >= 0),
  status public.cash_collection_status not null default 'pending',
  confirmed_by uuid references public.profiles (id) on delete set null,
  confirmed_at timestamptz,
  reference_number text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cash_collections_party_check check (customer_id <> provider_id),
  constraint cash_collections_amount_cap_check
    check (amount_collected_centavos <= amount_expected_centavos),
  constraint cash_collections_confirmed_check check (
    status <> 'confirmed'
    or (confirmed_at is not null
      and amount_collected_centavos = amount_expected_centavos)
  ),
  constraint cash_collections_failed_check check (
    status <> 'failed'
    or (failure_reason is not null and length(trim(failure_reason)) > 0)
  )
);

comment on table public.cash_collections is
  'Cash the customer handed to the provider. Confirmation does not credit SurGo cash.';

create index cash_collections_provider_idx
  on public.cash_collections (provider_id, status, created_at desc);

create table public.cash_payment_disputes (
  id uuid primary key default gen_random_uuid(),
  service_transaction_id uuid not null
    references public.service_transactions (id) on delete restrict,
  cash_collection_id uuid
    references public.cash_collections (id) on delete set null,
  raised_by uuid references public.profiles (id) on delete set null,
  against_profile_id uuid references public.profiles (id) on delete set null,
  amount_centavos bigint not null check (amount_centavos > 0),
  reason text not null check (length(trim(reason)) > 0),
  status public.cash_dispute_status not null default 'open',
  resolution text,
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cash_payment_disputes_closed_check check (
    status not in ('resolved', 'rejected')
    or (resolved_at is not null
      and resolution is not null and length(trim(resolution)) > 0)
  )
);

-- Only one live dispute per transaction.
create unique index cash_payment_disputes_open_key
  on public.cash_payment_disputes (service_transaction_id)
  where status in ('open', 'under_review');

create index cash_payment_disputes_status_idx
  on public.cash_payment_disputes (status, created_at);

create table public.platform_fee_receivables (
  id uuid primary key default gen_random_uuid(),
  service_transaction_id uuid not null unique
    references public.service_transactions (id) on delete restrict,
  provider_id uuid not null references public.profiles (id) on delete restrict,
  currency char(3) not null default 'PHP',
  amount_centavos bigint not null check (amount_centavos > 0),
  amount_remitted_centavos bigint not null default 0
    check (amount_remitted_centavos >= 0),
  status public.platform_fee_receivable_status not null default 'open',
  due_at timestamptz not null,
  last_remittance_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint platform_fee_receivables_cap_check
    check (amount_remitted_centavos <= amount_centavos),
  constraint platform_fee_receivables_remitted_check check (
    status <> 'remitted' or amount_remitted_centavos = amount_centavos
  ),
  constraint platform_fee_receivables_partial_check check (
    status <> 'partially_remitted'
    or (amount_remitted_centavos > 0
      and amount_remitted_centavos < amount_centavos)
  ),
  constraint platform_fee_receivables_open_check check (
    status <> 'open' or amount_remitted_centavos = 0
  )
);

comment on table public.platform_fee_receivables is
  'Platform fees a provider still owes from cash already collected.';

create index platform_fee_receivables_provider_idx
  on public.platform_fee_receivables (provider_id, status, due_at);

create table public.provider_fee_remittances (
  id uuid primary key default gen_random_uuid(),
  receivable_id uuid not null
    references public.platform_fee_receivables (id) on delete restrict,
  service_transaction_id uuid not null
    references public.service_transactions (id) on delete restrict,
  provider_id uuid not null references public.profiles (id) on delete restrict,
  currency char(3) not null default 'PHP',
  amount_centavos bigint not null check (amount_centavos > 0),
  method text not null default 'cash' check (method = 'cash'),
  reference_number text,
  status public.fee_remittance_status not null default 'submitted',
  submitted_by uuid references public.profiles (id) on delete set null,
  submitted_at timestamptz not null default now(),
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  rejection_reason text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provider_fee_remittances_verified_check check (
    status <> 'verified' or verified_at is not null
  ),
  constraint provider_fee_remittances_rejected_check check (
    status <> 'rejected'
    or (rejection_reason is not null and length(trim(rejection_reason)) > 0)
  )
);

-- A reference number cannot be reused by the same provider.
create unique index provider_fee_remittances_reference_key
  on public.provider_fee_remittances (provider_id, reference_number)
  where reference_number is not null;

create index provider_fee_remittances_receivable_idx
  on public.provider_fee_remittances (receivable_id, status);

create trigger cash_collections_set_updated_at
  before update on public.cash_collections
  for each row execute function public.set_updated_at();

create trigger cash_payment_disputes_set_updated_at
  before update on public.cash_payment_disputes
  for each row execute function public.set_updated_at();

create trigger platform_fee_receivables_set_updated_at
  before update on public.platform_fee_receivables
  for each row execute function public.set_updated_at();

create trigger provider_fee_remittances_set_updated_at
  before update on public.provider_fee_remittances
  for each row execute function public.set_updated_at();

revoke all on function public.guard_settled_transaction_snapshot()
  from public, anon, authenticated, service_role;
revoke all on function public.guard_settled_transaction_delete()
  from public, anon, authenticated, service_role;

-- Read-own RLS. Writes go through the reviewed financial functions or the
-- service_role admin dashboard.
alter table public.cash_collections enable row level security;
alter table public.cash_payment_disputes enable row level security;
alter table public.platform_fee_receivables enable row level security;
alter table public.provider_fee_remittances enable row level security;

create policy cash_collections_read_participants
  on public.cash_collections for select to authenticated
  using (
    customer_id = auth.uid()
    or provider_id = auth.uid()
    or public.has_approved_role('admin')
  );

create policy cash_payment_disputes_read_participants
  on public.cash_payment_disputes for select to authenticated
  using (
    raised_by = auth.uid()
    or against_profile_id = auth.uid()
    or exists (
      select 1 from public.service_transactions st
       where st.id = service_transaction_id
         and (st.customer_id = auth.uid() or st.provider_id = auth.uid())
    )
    or public.has_approved_role('admin')
  );

create policy platform_fee_receivables_read_own
  on public.platform_fee_receivables for select to authenticated
  using (provider_id = auth.uid() or public.has_approved_role('admin'));

create policy provider_fee_remittances_read_own
  on public.provider_fee_remittances for select to authenticated
  using (provider_id = auth.uid() or public.has_approved_role('admin'));

grant select on public.cash_collections to authenticated;
grant select on public.cash_payment_disputes to authenticated;
grant select on public.platform_fee_receivables to authenticated;
grant select on public.provider_fee_remittances to authenticated;

grant all on public.cash_collections to service_role;
grant all on public.cash_payment_disputes to service_role;
grant all on public.platform_fee_receivables to service_role;
grant all on public.provider_fee_remittances to service_role;

revoke all on public.cash_collections from anon;
revoke all on public.cash_payment_disputes from anon;
revoke all on public.platform_fee_receivables from anon;
revoke all on public.provider_fee_remittances from anon;








