-- Provider earnings and platform revenue reporting.
--
-- Views use security_invoker so the caller's row-level security still applies.
-- Admin dashboards can read the same views through service_role.

create or replace view public.provider_earnings_summary
with (security_invoker = true)
as
with settled as (
  select
    st.provider_id,
    count(*)::bigint as completed_transactions,
    sum(st.fare_centavos)::bigint as gross_fare_centavos,
    sum(st.platform_fee_centavos)::bigint as platform_fee_centavos,
    sum(st.customer_pays_centavos)::bigint as cash_expected_centavos,
    sum(st.provider_payout_centavos)::bigint as net_earnings_centavos,
    sum(st.platform_revenue_centavos)::bigint
      as platform_revenue_centavos
  from public.service_transactions st
  where st.status = 'completed'
  group by st.provider_id
),
receivables as (
  select
    r.provider_id,
    sum(r.amount_centavos)::bigint as fees_receivable_centavos,
    sum(r.amount_remitted_centavos)::bigint as fees_remitted_centavos,
    sum(r.amount_centavos - r.amount_remitted_centavos)::bigint
      as fees_outstanding_centavos
  from public.platform_fee_receivables r
  group by r.provider_id
),
cash as (
  select
    cc.provider_id,
    sum(
      case when cc.status = 'confirmed'
           then cc.amount_collected_centavos else 0 end
    )::bigint as cash_confirmed_centavos,
    count(*) filter (where cc.status = 'pending')::bigint
      as pending_cash_collections,
    count(*) filter (where cc.status = 'failed')::bigint
      as failed_cash_collections
  from public.cash_collections cc
  group by cc.provider_id
)
select
  s.provider_id,
  s.completed_transactions,
  s.gross_fare_centavos,
  s.platform_fee_centavos,
  s.cash_expected_centavos,
  s.net_earnings_centavos,
  s.platform_revenue_centavos,
  coalesce(r.fees_receivable_centavos, 0) as fees_receivable_centavos,
  coalesce(r.fees_remitted_centavos, 0) as fees_remitted_centavos,
  coalesce(r.fees_outstanding_centavos, 0) as fees_outstanding_centavos,
  coalesce(c.cash_confirmed_centavos, 0) as cash_confirmed_centavos,
  coalesce(c.pending_cash_collections, 0) as pending_cash_collections,
  coalesce(c.failed_cash_collections, 0) as failed_cash_collections
from settled s
left join receivables r on r.provider_id = s.provider_id
left join cash c on c.provider_id = s.provider_id;

create or replace view public.platform_revenue_daily
with (security_invoker = true)
as
with settled as (
  select
    st.id,
    date_trunc('day', st.settled_at)::date as revenue_date,
    st.service_type,
    st.fee_mode,
    st.fare_centavos,
    st.platform_fee_centavos,
    st.platform_revenue_centavos,
    st.customer_pays_centavos,
    st.provider_payout_centavos
  from public.service_transactions st
  where st.status = 'completed'
),
receivables as (
  select
    r.service_transaction_id,
    r.amount_remitted_centavos,
    r.amount_centavos - r.amount_remitted_centavos
      as outstanding_centavos
  from public.platform_fee_receivables r
)
select
  s.revenue_date,
  s.service_type,
  s.fee_mode,
  count(*)::bigint as completed_transactions,
  sum(s.fare_centavos)::bigint as fare_centavos,
  sum(s.platform_fee_centavos)::bigint as platform_fee_centavos,
  sum(s.platform_revenue_centavos)::bigint as platform_revenue_centavos,
  sum(s.customer_pays_centavos)::bigint as customer_pays_centavos,
  sum(s.provider_payout_centavos)::bigint as provider_payout_centavos,
  coalesce(sum(r.amount_remitted_centavos), 0)::bigint
    as fees_remitted_centavos,
  coalesce(sum(r.outstanding_centavos), 0)::bigint
    as fees_outstanding_centavos
from settled s
left join receivables r on r.service_transaction_id = s.id
group by s.revenue_date, s.service_type, s.fee_mode;

create or replace view public.platform_revenue_summary
with (security_invoker = true)
as
select
  count(*)::bigint as completed_transactions,
  coalesce(sum(st.fare_centavos), 0)::bigint as fare_centavos,
  coalesce(sum(st.platform_fee_centavos), 0)::bigint
    as platform_fee_centavos,
  coalesce(sum(st.platform_revenue_centavos), 0)::bigint
    as platform_revenue_centavos,
  coalesce(sum(st.customer_pays_centavos), 0)::bigint
    as customer_pays_centavos,
  coalesce(sum(st.provider_payout_centavos), 0)::bigint
    as provider_payout_centavos,
  coalesce(sum(r.amount_remitted_centavos), 0)::bigint
    as fees_remitted_centavos,
  coalesce(
    sum(r.amount_centavos - r.amount_remitted_centavos), 0
  )::bigint as fees_outstanding_centavos
from public.service_transactions st
left join public.platform_fee_receivables r
  on r.service_transaction_id = st.id
where st.status = 'completed';

revoke all on public.provider_earnings_summary
  from public, anon, authenticated, service_role;
revoke all on public.platform_revenue_daily
  from public, anon, authenticated, service_role;
revoke all on public.platform_revenue_summary
  from public, anon, authenticated, service_role;

grant select on public.provider_earnings_summary
  to authenticated, service_role;
grant select on public.platform_revenue_daily
  to authenticated, service_role;
grant select on public.platform_revenue_summary
  to authenticated, service_role;


