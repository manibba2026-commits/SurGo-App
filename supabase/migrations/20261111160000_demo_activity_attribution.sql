-- Attribute seeded demo history without confusing it with real activity.
--
-- The demo dataset already contained rides, rentals, Pasuyo requests, ledger
-- rows and notifications, but nothing on those rows said they came from the
-- demo accounts. Admin Finance therefore had no way to keep seeded cash out of
-- a "real revenue" figure beyond a hard-coded fixture list.
--
-- This migration adds an explicit `is_simulated` marker to the history tables.
-- The demo seed sets it for rows owned by the demo phone range; a real account
-- leaves it false. Reporting functions then read only real rows for money and
-- expose the demo totals separately.
--
-- Nothing here changes pricing, creates a payment, or marks a demo row as
-- collected money. Every simulated service transaction still carries a zero
-- platform fee.

alter table public.ride_requests
  add column is_simulated boolean not null default false;
alter table public.rental_bookings
  add column is_simulated boolean not null default false;
alter table public.service_requests
  add column is_simulated boolean not null default false;
alter table public.service_transactions
  add column is_simulated boolean not null default false;
alter table public.wallet_transactions
  add column is_simulated boolean not null default false;
alter table public.notifications
  add column is_simulated boolean not null default false;
alter table public.ride_status_events
  add column is_simulated boolean not null default false;
alter table public.service_status_events
  add column is_simulated boolean not null default false;
alter table public.ride_ratings
  add column is_simulated boolean not null default false;

comment on column public.ride_requests.is_simulated is
  'Seeded demonstration ride. Never a real passenger booking.';
comment on column public.service_transactions.is_simulated is
  'Seeded demonstration settlement. Its platform fee is zero and it is excluded from actual revenue.';
comment on column public.wallet_transactions.is_simulated is
  'Seeded demonstration ledger entry, not money held by SurGo.';

-- The finance list and the real-revenue aggregate both filter on this flag.
create index service_transactions_actual_revenue_idx
  on public.service_transactions (status, service_type)
  where not is_simulated;
create index service_transactions_simulated_idx
  on public.service_transactions (created_at desc)
  where is_simulated;

-- Redefine the admin summary so money figures are actual-only and the demo
-- totals are named rather than silently mixed into them.
create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare r jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select jsonb_build_object(
    'users_total', (select count(*) from public.profiles),
    'users_suspended', (select count(*) from public.profiles where account_status='suspended'),
    'passengers', (select count(distinct profile_id) from public.user_roles where role='passenger' and status='approved'),
    'riders', (select count(distinct profile_id) from public.user_roles where role in ('rider','earner') and status='approved'),
    'vehicle_owners', (select count(distinct profile_id) from public.user_roles where role='vehicle_owner' and status='approved'),
    'rides_total', (select count(*) from public.ride_requests),
    'rides_completed', (select count(*) from public.ride_requests where status='completed'),
    'rides_active', (select count(*) from public.ride_requests where status not in ('completed','cancelled')),
    'rides_cancelled', (select count(*) from public.ride_requests where status='cancelled'),
    'rentals_total', (select count(*) from public.rental_bookings),
    'rentals_active', (select count(*) from public.rental_bookings where status in ('requested','awaiting_owner','accepted','active')),
    'pasuyo_total', (select count(*) from public.service_requests),
    'pasuyo_active', (select count(*) from public.service_requests where status not in ('delivered','cancelled')),
    'verifications_pending', (select count(*) from public.verification_applications where status in ('submitted','under_review')),
    'vehicle_docs_pending', (select count(*) from public.vehicle_documents where status='pending'),
    'revenue_by_service', coalesce((select jsonb_object_agg(service_type, s) from (
        select service_type, sum(platform_revenue_centavos)::bigint s
          from public.service_transactions
         where status='completed' and not is_simulated
         group by 1) x), '{}'::jsonb),
    'revenue_total', coalesce((select sum(platform_revenue_centavos)
      from public.service_transactions
      where status='completed' and not is_simulated),0),
    'simulated_transactions', (select count(*) from public.service_transactions where is_simulated),
    'simulated_cash_total', coalesce((select sum(customer_pays_centavos)
      from public.service_transactions
      where status='completed' and is_simulated),0),
    'simulated_revenue_total', coalesce((select sum(platform_revenue_centavos)
      from public.service_transactions
      where status='completed' and is_simulated),0),
    'remit_outstanding', coalesce((select sum(amount_centavos) from public.cash_fee_remittances where status in ('pending','overdue')),0),
    'remit_overdue', coalesce((select sum(amount_centavos) from public.cash_fee_remittances where status='overdue'),0),
    'remit_remitted', coalesce((select sum(amount_centavos) from public.cash_fee_remittances where status='remitted'),0)
  ) into r;
  return r;
end $$;

-- Activity counts still describe the whole demo dataset; only the money column
-- is actual-only, because a seeded trip is not collected revenue.
create or replace function public.admin_daily_activity(p_days int default 14)
returns table(day date, rides bigint, rentals bigint, pasuyo bigint, signups bigint, revenue_centavos bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  p_days := least(greatest(p_days,1),180);
  return query
  select d::date,
    (select count(*) from public.ride_requests x where (x.requested_at at time zone 'Asia/Manila')::date = d::date),
    (select count(*) from public.rental_bookings x where (x.created_at at time zone 'Asia/Manila')::date = d::date),
    (select count(*) from public.service_requests x where (x.requested_at at time zone 'Asia/Manila')::date = d::date),
    (select count(*) from public.profiles x where (x.created_at at time zone 'Asia/Manila')::date = d::date),
    coalesce((select sum(x.platform_revenue_centavos) from public.service_transactions x
      where x.status='completed' and not x.is_simulated
        and (coalesce(x.settled_at,x.created_at) at time zone 'Asia/Manila')::date = d::date),0)::bigint
  from generate_series(((now() at time zone 'Asia/Manila')::date - (p_days-1)), (now() at time zone 'Asia/Manila')::date, interval '1 day') d
  order by 1;
end $$;

revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;
revoke all on function public.admin_daily_activity(int) from public, anon;
grant execute on function public.admin_daily_activity(int) to authenticated;
