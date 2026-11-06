-- Versioned pricing policies and configurable platform-fee terms.
--
-- No policy is seeded here and nothing is activated. Actual commercial values
-- must be reviewed and inserted deliberately after developer approval.

create type public.platform_fee_mode as enum (
  'customer_addon',
  'provider_deduction'
);

create type public.platform_fee_type as enum (
  'fixed',
  'distance',
  'percentage'
);

alter table public.pricing_policies
  add column version integer,
  add column platform_fee_mode public.platform_fee_mode
    not null default 'customer_addon',
  add column platform_fee_type public.platform_fee_type
    not null default 'fixed',
  add column platform_fee_per_km_centavos bigint not null default 0
    check (platform_fee_per_km_centavos >= 0),
  add column minimum_platform_fee_centavos bigint not null default 0
    check (minimum_platform_fee_centavos >= 0),
  add column maximum_platform_fee_centavos bigint
    check (maximum_platform_fee_centavos is null
      or maximum_platform_fee_centavos >= 0),
  add column superseded_at timestamptz,
  add constraint pricing_policies_fee_bounds_check check (
    maximum_platform_fee_centavos is null
    or maximum_platform_fee_centavos >= minimum_platform_fee_centavos
  );

comment on column public.pricing_policies.version is
  'Monotonic version per service type. Approved terms are immutable; create a new version instead of editing them.';
comment on column public.pricing_policies.platform_fee_mode is
  'customer_addon: customer pays fare + fee. provider_deduction: fee is deducted from provider payout.';
comment on column public.pricing_policies.platform_fee_type is
  'fixed, distance (per-km fee) or percentage (basis points of fare).';

-- Existing rows (if any) get a stable version before the column is enforced.
update public.pricing_policies p
   set version = v.rn
  from (
    select id,
           row_number() over (
             partition by service_type order by created_at, id
           ) as rn
      from public.pricing_policies
  ) v
 where p.id = v.id;

alter table public.pricing_policies alter column version set not null;

create unique index pricing_policies_service_version_key
  on public.pricing_policies (service_type, version);

-- Every new row becomes the next version for its service type.
create or replace function public.assign_pricing_policy_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  select coalesce(max(pp.version), 0) + 1
    into new.version
    from public.pricing_policies pp
   where pp.service_type = new.service_type;
  return new;
end;
$$;

comment on function public.assign_pricing_policy_version() is
  'Assigns the next per-service policy version on INSERT.';

create trigger pricing_policies_assign_version
  before insert on public.pricing_policies
  for each row execute function public.assign_pricing_policy_version();

-- Once approved, commercial terms are immutable. Activation/deactivation and
-- retirement metadata may still change; anything that changes the price must
-- be a new version.
create or replace function public.guard_pricing_policy_terms()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.approved_at is not null then
    if new.name is distinct from old.name
       or new.service_type is distinct from old.service_type
       or new.currency is distinct from old.currency
       or new.version is distinct from old.version
       or new.base_fare_centavos is distinct from old.base_fare_centavos
       or new.per_km_centavos is distinct from old.per_km_centavos
       or new.per_minute_centavos is distinct from old.per_minute_centavos
       or new.minimum_fare_centavos is distinct from old.minimum_fare_centavos
       or new.platform_fee_fixed_centavos
            is distinct from old.platform_fee_fixed_centavos
       or new.platform_fee_bps is distinct from old.platform_fee_bps
       or new.platform_fee_mode is distinct from old.platform_fee_mode
       or new.platform_fee_type is distinct from old.platform_fee_type
       or new.platform_fee_per_km_centavos
            is distinct from old.platform_fee_per_km_centavos
       or new.minimum_platform_fee_centavos
            is distinct from old.minimum_platform_fee_centavos
       or new.maximum_platform_fee_centavos
            is distinct from old.maximum_platform_fee_centavos
       or new.effective_from is distinct from old.effective_from
       or new.effective_to is distinct from old.effective_to
    then
      raise exception
        'Approved pricing policy terms are immutable; create a new version'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create trigger pricing_policies_guard_terms
  before update on public.pricing_policies
  for each row execute function public.guard_pricing_policy_terms();

revoke all on function public.assign_pricing_policy_version()
  from public, anon, authenticated, service_role;
revoke all on function public.guard_pricing_policy_terms()
  from public, anon, authenticated, service_role;





