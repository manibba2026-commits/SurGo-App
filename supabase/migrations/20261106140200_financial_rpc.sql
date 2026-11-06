-- Server-side pricing, settlement, cash confirmation, disputes and remittances.
--
-- Every amount is integer centavos. Rounding is half-up on non-negative
-- amounts so calculations are deterministic across clients and the database.

create or replace function public.round_centavos(p_value numeric)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null then null
    when p_value < 0 then -(floor(abs(p_value) + 0.5)::bigint)
    else floor(p_value + 0.5)::bigint
  end;
$$;

comment on function public.round_centavos(numeric) is
  'Deterministic half-up rounding to integer centavos.';

create or replace function public.get_active_pricing_policy(
  p_service_type public.service_type,
  p_at timestamptz default now()
)
returns public.pricing_policies
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_policy public.pricing_policies;
begin
  select * into v_policy
    from public.pricing_policies pp
   where pp.service_type = p_service_type
     and pp.is_active
     and pp.approved_at is not null
     and (pp.effective_from is null or pp.effective_from <= p_at)
     and (pp.effective_to is null or pp.effective_to > p_at)
   order by pp.version desc
   limit 1;

  if not found then
    raise exception 'No approved active pricing policy for service type %',
      p_service_type
      using errcode = 'P0002';
  end if;

  return v_policy;
end;
$$;

create or replace function public.calculate_service_price(
  p_service_type public.service_type,
  p_distance_km numeric default 0,
  p_duration_minutes integer default 0,
  p_pricing_policy_id uuid default null,
  p_at timestamptz default now()
)
returns table (
  service_type public.service_type,
  pricing_policy_id uuid,
  pricing_policy_version integer,
  fare_centavos bigint,
  platform_fee_centavos bigint,
  customer_pays_centavos bigint,
  provider_payout_centavos bigint,
  platform_revenue_centavos bigint,
  fee_mode public.platform_fee_mode,
  fee_type public.platform_fee_type,
  distance_km numeric,
  duration_minutes integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_policy public.pricing_policies;
  v_fare bigint;
  v_fee bigint;
  v_raw_fee numeric;
  v_customer_pays bigint;
  v_provider_payout bigint;
begin
  if p_distance_km is null or p_distance_km < 0 then
    raise exception 'Distance must be a non-negative number'
      using errcode = '22023';
  end if;

  if p_duration_minutes is null or p_duration_minutes < 0 then
    raise exception 'Duration must be a non-negative integer'
      using errcode = '22023';
  end if;

  if p_pricing_policy_id is null then
    v_policy := public.get_active_pricing_policy(p_service_type, p_at);
  else
    select * into v_policy
      from public.pricing_policies pp
     where pp.id = p_pricing_policy_id
       and pp.service_type = p_service_type
       and pp.is_active
       and pp.approved_at is not null
       and (pp.effective_from is null or pp.effective_from <= p_at)
       and (pp.effective_to is null or pp.effective_to > p_at);

    if not found then
      raise exception
        'No approved active pricing policy % for service type %',
        p_pricing_policy_id, p_service_type
        using errcode = 'P0002';
    end if;
  end if;

  v_fare := public.round_centavos(
    v_policy.base_fare_centavos::numeric
    + (v_policy.per_km_centavos::numeric * p_distance_km)
    + (v_policy.per_minute_centavos::numeric * p_duration_minutes)
  );

  if v_fare < v_policy.minimum_fare_centavos then
    v_fare := v_policy.minimum_fare_centavos;
  end if;

  if v_policy.platform_fee_type = 'fixed' then
    v_raw_fee := v_policy.platform_fee_fixed_centavos::numeric;
  elsif v_policy.platform_fee_type = 'distance' then
    v_raw_fee := v_policy.platform_fee_per_km_centavos::numeric
      * p_distance_km;
  else
    v_raw_fee := v_fare::numeric * v_policy.platform_fee_bps / 10000.0;
  end if;

  v_fee := public.round_centavos(greatest(coalesce(v_raw_fee, 0), 0));

  if v_fee < v_policy.minimum_platform_fee_centavos then
    v_fee := v_policy.minimum_platform_fee_centavos;
  end if;

  if v_policy.maximum_platform_fee_centavos is not null
     and v_fee > v_policy.maximum_platform_fee_centavos then
    v_fee := v_policy.maximum_platform_fee_centavos;
  end if;

  if v_policy.platform_fee_mode = 'provider_deduction'
     and v_fee > v_fare then
    raise exception
      'Platform fee % exceeds fare % in provider_deduction mode',
      v_fee, v_fare
      using errcode = 'P0001';
  end if;

  if v_policy.platform_fee_mode = 'customer_addon' then
    v_customer_pays := v_fare + v_fee;
    v_provider_payout := v_fare;
  else
    v_customer_pays := v_fare;
    v_provider_payout := v_fare - v_fee;
  end if;

  return query
    select p_service_type,
           v_policy.id,
           v_policy.version,
           v_fare,
           v_fee,
           v_customer_pays,
           v_provider_payout,
           v_fee,
           v_policy.platform_fee_mode,
           v_policy.platform_fee_type,
           p_distance_km,
           p_duration_minutes;
end;
$$;

-- Internal helper: every settled transaction gets exactly one cash collection
-- row and (when the fee is positive) exactly one platform-fee receivable.
create or replace function public.ensure_transaction_accounts(
  p_service_transaction_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.service_transactions;
begin
  select * into v_tx
    from public.service_transactions st
   where st.id = p_service_transaction_id;

  if not found then
    raise exception 'Service transaction % not found',
      p_service_transaction_id
      using errcode = 'P0002';
  end if;

  insert into public.cash_collections (
    service_transaction_id, customer_id, provider_id,
    amount_expected_centavos
  ) values (
    v_tx.id, v_tx.customer_id, v_tx.provider_id,
    v_tx.customer_pays_centavos
  )
  on conflict (service_transaction_id) do nothing;

  if v_tx.platform_fee_centavos > 0 then
    insert into public.platform_fee_receivables (
      service_transaction_id, provider_id, currency,
      amount_centavos, due_at
    ) values (
      v_tx.id, v_tx.provider_id, v_tx.currency,
      v_tx.platform_fee_centavos, now() + interval '7 days'
    )
    on conflict (service_transaction_id) do nothing;
  end if;
end;
$$;

create or replace function public.settle_service_transaction(
  p_service_type public.service_type,
  p_service_id uuid,
  p_distance_km numeric default null,
  p_duration_minutes integer default null,
  p_actor_id uuid default null
)
returns public.service_transactions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer_id uuid;
  v_provider_id uuid;
  v_distance numeric;
  v_duration integer;
  v_existing_id uuid;
  v_quote record;
  v_snapshot jsonb;
  v_tx public.service_transactions;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
begin
  if p_service_id is null then
    raise exception 'Service id is required' using errcode = '22023';
  end if;

  if p_service_type = 'ride' then
    select rr.passenger_id, rr.rider_id,
           coalesce(p_distance_km, rr.distance_km, 0),
           coalesce(p_duration_minutes, rr.eta_minutes, 0)
      into v_customer_id, v_provider_id, v_distance, v_duration
      from public.ride_requests rr
     where rr.id = p_service_id
       and rr.status = 'completed';
  elsif p_service_type = 'rental' then
    select rb.renter_id, rb.owner_id,
           coalesce(p_distance_km, 0),
           coalesce(
             p_duration_minutes,
             greatest(
               0,
               round(extract(epoch from (rb.end_at - rb.start_at)) / 3600)::int
             )
           )
      into v_customer_id, v_provider_id, v_distance, v_duration
      from public.rental_bookings rb
     where rb.id = p_service_id
       and rb.status = 'completed';
  elsif p_service_type = 'pasuyo' then
    select sr.customer_id, sr.provider_id,
           coalesce(p_distance_km, 0),
           coalesce(p_duration_minutes, 0)
      into v_customer_id, v_provider_id, v_distance, v_duration
      from public.service_requests sr
     where sr.id = p_service_id
       and sr.status = 'delivered';
  else
    raise exception 'Unsupported service type %', p_service_type
      using errcode = '22023';
  end if;

  if v_customer_id is null then
    raise exception 'Completed % source % not found',
      p_service_type, p_service_id
      using errcode = 'P0002';
  end if;

  if v_provider_id is null then
    raise exception 'Service % has no provider to settle', p_service_id
      using errcode = 'P0001';
  end if;

  if v_customer_id = v_provider_id then
    raise exception 'Customer and provider must be different people'
      using errcode = 'P0001';
  end if;

  if auth.uid() is not null
     and v_actor not in (v_customer_id, v_provider_id)
     and not public.has_approved_role('admin') then
    raise exception 'Not allowed to settle this service'
      using errcode = '42501';
  end if;

  select st.id into v_existing_id
    from public.service_transactions st
   where st.service_type = p_service_type
     and (
       (p_service_type = 'ride' and st.ride_id = p_service_id)
       or (p_service_type = 'rental' and st.rental_id = p_service_id)
       or (p_service_type = 'pasuyo'
         and st.service_request_id = p_service_id)
     );

  if v_existing_id is not null then
    select * into v_tx
      from public.service_transactions st
     where st.id = v_existing_id;
    perform public.ensure_transaction_accounts(v_tx.id);
    return v_tx;
  end if;

  v_distance := round(coalesce(v_distance, 0), 2);
  v_duration := coalesce(v_duration, 0);

  select * into v_quote
    from public.calculate_service_price(
      p_service_type, v_distance, v_duration
    );

  v_snapshot := jsonb_build_object(
    'policy_id', v_quote.pricing_policy_id,
    'policy_version', v_quote.pricing_policy_version,
    'fee_mode', v_quote.fee_mode,
    'fee_type', v_quote.fee_type,
    'distance_km', v_distance,
    'duration_minutes', v_duration,
    'fare_centavos', v_quote.fare_centavos,
    'platform_fee_centavos', v_quote.platform_fee_centavos,
    'customer_pays_centavos', v_quote.customer_pays_centavos,
    'provider_payout_centavos', v_quote.provider_payout_centavos,
    'platform_revenue_centavos', v_quote.platform_revenue_centavos,
    'currency', 'PHP',
    'captured_at', to_jsonb(now())
  );

  insert into public.service_transactions (
    service_type, ride_id, rental_id, service_request_id,
    customer_id, provider_id, currency,
    fare_centavos, platform_fee_centavos, customer_pays_centavos,
    provider_payout_centavos, platform_revenue_centavos,
    payment_method, status, settled_at,
    pricing_policy_id, pricing_policy_version,
    fee_mode, fee_type, distance_km, duration_minutes, pricing_snapshot
  ) values (
    p_service_type,
    case when p_service_type = 'ride' then p_service_id end,
    case when p_service_type = 'rental' then p_service_id end,
    case when p_service_type = 'pasuyo' then p_service_id end,
    v_customer_id, v_provider_id, 'PHP',
    v_quote.fare_centavos, v_quote.platform_fee_centavos,
    v_quote.customer_pays_centavos, v_quote.provider_payout_centavos,
    v_quote.platform_revenue_centavos,
    'cash', 'completed', now(),
    v_quote.pricing_policy_id, v_quote.pricing_policy_version,
    v_quote.fee_mode, v_quote.fee_type,
    v_distance, v_duration, v_snapshot
  )
  returning * into v_tx;

  perform public.ensure_transaction_accounts(v_tx.id);
  return v_tx;

exception
  when unique_violation then
    select st.id into v_existing_id
      from public.service_transactions st
     where st.service_type = p_service_type
       and (
         (p_service_type = 'ride' and st.ride_id = p_service_id)
         or (p_service_type = 'rental' and st.rental_id = p_service_id)
         or (p_service_type = 'pasuyo'
           and st.service_request_id = p_service_id)
       );

    if v_existing_id is not null then
      select * into v_tx
        from public.service_transactions st
       where st.id = v_existing_id;
      perform public.ensure_transaction_accounts(v_tx.id);
      return v_tx;
    end if;
    raise;
end;
$$;

create or replace function public.confirm_cash_collection(
  p_service_transaction_id uuid,
  p_amount_centavos bigint,
  p_actor_id uuid default null,
  p_reference_number text default null
)
returns public.cash_collections
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.service_transactions;
  v_collection public.cash_collections;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
begin
  if p_amount_centavos is null or p_amount_centavos <= 0 then
    raise exception 'Cash amount must be a positive integer'
      using errcode = '22023';
  end if;

  select * into v_tx
    from public.service_transactions st
   where st.id = p_service_transaction_id;

  if not found then
    raise exception 'Service transaction % not found',
      p_service_transaction_id using errcode = 'P0002';
  end if;

  if v_tx.status <> 'completed' then
    raise exception 'Only completed transactions can be cash-confirmed'
      using errcode = 'P0001';
  end if;

  if auth.uid() is not null
     and v_actor not in (v_tx.customer_id, v_tx.provider_id)
     and not public.has_approved_role('admin') then
    raise exception 'Not allowed to confirm this cash payment'
      using errcode = '42501';
  end if;

  insert into public.cash_collections (
    service_transaction_id, customer_id, provider_id,
    amount_expected_centavos
  ) values (
    v_tx.id, v_tx.customer_id, v_tx.provider_id,
    v_tx.customer_pays_centavos
  )
  on conflict (service_transaction_id) do nothing;

  select * into v_collection
    from public.cash_collections cc
   where cc.service_transaction_id = p_service_transaction_id
   for update;

  if v_collection.status = 'confirmed' then
    if v_collection.amount_collected_centavos = p_amount_centavos then
      return v_collection;
    end if;
    raise exception
      'Cash collection already confirmed for a different amount'
      using errcode = 'P0001';
  end if;

  if p_amount_centavos <> v_collection.amount_expected_centavos then
    raise exception 'Cash amount % does not match expected %',
      p_amount_centavos, v_collection.amount_expected_centavos
      using errcode = 'P0001';
  end if;

  update public.cash_collections
     set status = 'confirmed',
         amount_collected_centavos = p_amount_centavos,
         confirmed_by = v_actor,
         confirmed_at = now(),
         reference_number = coalesce(
           p_reference_number, reference_number
         ),
         failure_reason = null
   where id = v_collection.id
   returning * into v_collection;

  return v_collection;
end;
$$;

create or replace function public.fail_cash_collection(
  p_service_transaction_id uuid,
  p_reason text,
  p_actor_id uuid default null
)
returns public.cash_collections
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.service_transactions;
  v_collection public.cash_collections;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A failure reason is required'
      using errcode = '22023';
  end if;

  select * into v_tx
    from public.service_transactions st
   where st.id = p_service_transaction_id;

  if not found then
    raise exception 'Service transaction % not found',
      p_service_transaction_id using errcode = 'P0002';
  end if;

  if auth.uid() is not null
     and v_actor not in (v_tx.customer_id, v_tx.provider_id)
     and not public.has_approved_role('admin') then
    raise exception 'Not allowed to update this cash payment'
      using errcode = '42501';
  end if;

  insert into public.cash_collections (
    service_transaction_id, customer_id, provider_id,
    amount_expected_centavos
  ) values (
    v_tx.id, v_tx.customer_id, v_tx.provider_id,
    v_tx.customer_pays_centavos
  )
  on conflict (service_transaction_id) do nothing;

  select * into v_collection
    from public.cash_collections cc
   where cc.service_transaction_id = p_service_transaction_id
   for update;

  if v_collection.status = 'confirmed' then
    raise exception 'A confirmed cash collection cannot be failed'
      using errcode = 'P0001';
  end if;

  update public.cash_collections
     set status = 'failed',
         amount_collected_centavos = 0,
         confirmed_by = null,
         confirmed_at = null,
         failure_reason = trim(p_reason)
   where id = v_collection.id
   returning * into v_collection;

  return v_collection;
end;
$$;

create or replace function public.open_cash_payment_dispute(
  p_service_transaction_id uuid,
  p_reason text,
  p_amount_centavos bigint default null,
  p_actor_id uuid default null,
  p_cash_collection_id uuid default null
)
returns public.cash_payment_disputes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.service_transactions;
  v_dispute public.cash_payment_disputes;
  v_amount bigint;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
  v_against uuid;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A dispute reason is required'
      using errcode = '22023';
  end if;

  select * into v_tx
    from public.service_transactions st
   where st.id = p_service_transaction_id;

  if not found then
    raise exception 'Service transaction % not found',
      p_service_transaction_id using errcode = 'P0002';
  end if;

  if v_tx.status <> 'completed' then
    raise exception 'Only completed transactions can be disputed'
      using errcode = 'P0001';
  end if;

  if auth.uid() is not null
     and v_actor not in (v_tx.customer_id, v_tx.provider_id)
     and not public.has_approved_role('admin') then
    raise exception 'Not allowed to dispute this payment'
      using errcode = '42501';
  end if;

  v_amount := coalesce(p_amount_centavos, v_tx.customer_pays_centavos);
  if v_amount <= 0 then
    raise exception 'Dispute amount must be positive'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.cash_payment_disputes d
     where d.service_transaction_id = p_service_transaction_id
       and d.status in ('open', 'under_review')
  ) then
    raise exception 'An open dispute already exists for this transaction'
      using errcode = 'P0001';
  end if;

  v_against := case
    when v_actor = v_tx.customer_id then v_tx.provider_id
    when v_actor = v_tx.provider_id then v_tx.customer_id
    else null
  end;

  insert into public.cash_payment_disputes (
    service_transaction_id, cash_collection_id, raised_by,
    against_profile_id, amount_centavos, reason
  ) values (
    v_tx.id,
    coalesce(
      p_cash_collection_id,
      (select cc.id from public.cash_collections cc
        where cc.service_transaction_id = v_tx.id)
    ),
    v_actor, v_against, v_amount, trim(p_reason)
  )
  returning * into v_dispute;

  update public.platform_fee_receivables
     set status = 'disputed'
   where service_transaction_id = v_tx.id
     and status in ('open', 'partially_remitted');

  return v_dispute;
end;
$$;

create or replace function public.resolve_cash_payment_dispute(
  p_dispute_id uuid,
  p_status public.cash_dispute_status,
  p_resolution text default null,
  p_actor_id uuid default null
)
returns public.cash_payment_disputes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dispute public.cash_payment_disputes;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
  v_next public.platform_fee_receivable_status;
begin
  if p_status not in ('resolved', 'rejected', 'withdrawn') then
    raise exception 'Dispute status must be resolved, rejected or withdrawn'
      using errcode = '22023';
  end if;

  if auth.uid() is not null and not public.has_approved_role('admin') then
    raise exception 'Only an admin can resolve a dispute'
      using errcode = '42501';
  end if;

  select * into v_dispute
    from public.cash_payment_disputes d
   where d.id = p_dispute_id
   for update;

  if not found then
    raise exception 'Dispute % not found', p_dispute_id
      using errcode = 'P0002';
  end if;

  if v_dispute.status in ('resolved', 'rejected', 'withdrawn') then
    if v_dispute.status = p_status then
      return v_dispute;
    end if;
    raise exception 'Dispute is already closed'
      using errcode = 'P0001';
  end if;

  if p_status in ('resolved', 'rejected')
     and (p_resolution is null or length(trim(p_resolution)) = 0) then
    raise exception 'A resolution is required for %', p_status
      using errcode = '22023';
  end if;

  update public.cash_payment_disputes
     set status = p_status,
         resolution = nullif(trim(p_resolution), ''),
         resolved_by = v_actor,
         resolved_at = now()
   where id = v_dispute.id
   returning * into v_dispute;

  if not exists (
    select 1 from public.cash_payment_disputes d
     where d.service_transaction_id = v_dispute.service_transaction_id
       and d.status in ('open', 'under_review')
  ) then
    select case
             when r.amount_remitted_centavos <= 0 then 'open'
             when r.amount_remitted_centavos >= r.amount_centavos
               then 'remitted'
             else 'partially_remitted'
           end
      into v_next
      from public.platform_fee_receivables r
     where r.service_transaction_id = v_dispute.service_transaction_id;

    if v_next is not null then
      update public.platform_fee_receivables
         set status = v_next
       where service_transaction_id = v_dispute.service_transaction_id
         and status = 'disputed';
    end if;
  end if;

  return v_dispute;
end;
$$;

create or replace function public.record_provider_fee_remittance(
  p_receivable_id uuid,
  p_amount_centavos bigint,
  p_reference_number text default null,
  p_submitted_by uuid default null,
  p_notes text default null
)
returns public.provider_fee_remittances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_receivable public.platform_fee_receivables;
  v_remittance public.provider_fee_remittances;
  v_existing public.provider_fee_remittances;
  v_actor uuid := coalesce(auth.uid(), p_submitted_by);
  v_remaining bigint;
begin
  if p_amount_centavos is null or p_amount_centavos <= 0 then
    raise exception 'Remittance amount must be a positive integer'
      using errcode = '22023';
  end if;

  select * into v_receivable
    from public.platform_fee_receivables r
   where r.id = p_receivable_id
   for update;

  if not found then
    raise exception 'Receivable % not found', p_receivable_id
      using errcode = 'P0002';
  end if;

  if v_receivable.status in ('remitted', 'waived') then
    raise exception 'Receivable is already closed'
      using errcode = 'P0001';
  end if;

  if v_receivable.status = 'disputed' then
    raise exception 'Receivable is disputed and cannot accept remittances'
      using errcode = 'P0001';
  end if;

  if auth.uid() is not null
     and v_actor <> v_receivable.provider_id
     and not public.has_approved_role('admin') then
    raise exception 'Not allowed to remit for this provider'
      using errcode = '42501';
  end if;

  if p_reference_number is not null then
    select * into v_existing
      from public.provider_fee_remittances r
     where r.provider_id = v_receivable.provider_id
       and r.reference_number = p_reference_number;

    if found then
      if v_existing.receivable_id = v_receivable.id
         and v_existing.amount_centavos = p_amount_centavos then
        return v_existing;
      end if;
      raise exception 'Reference number % was already used',
        p_reference_number
        using errcode = 'P0001';
    end if;
  end if;

  v_remaining := v_receivable.amount_centavos
    - v_receivable.amount_remitted_centavos;

  if p_amount_centavos > v_remaining then
    raise exception 'Remittance % exceeds outstanding %',
      p_amount_centavos, v_remaining
      using errcode = 'P0001';
  end if;

  insert into public.provider_fee_remittances (
    receivable_id, service_transaction_id, provider_id,
    amount_centavos, reference_number, submitted_by, notes
  ) values (
    v_receivable.id, v_receivable.service_transaction_id,
    v_receivable.provider_id, p_amount_centavos,
    nullif(trim(p_reference_number), ''), v_actor,
    nullif(trim(p_notes), '')
  )
  returning * into v_remittance;

  return v_remittance;
end;
$$;

create or replace function public.verify_provider_fee_remittance(
  p_remittance_id uuid,
  p_approve boolean default true,
  p_verified_by uuid default null,
  p_rejection_reason text default null
)
returns public.provider_fee_remittances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_remittance public.provider_fee_remittances;
  v_receivable public.platform_fee_receivables;
  v_actor uuid := coalesce(auth.uid(), p_verified_by);
  v_remaining bigint;
  v_new_total bigint;
  v_new_status public.platform_fee_receivable_status;
begin
  if auth.uid() is not null and not public.has_approved_role('admin') then
    raise exception 'Only an admin can verify a remittance'
      using errcode = '42501';
  end if;

  select * into v_remittance
    from public.provider_fee_remittances r
   where r.id = p_remittance_id
   for update;

  if not found then
    raise exception 'Remittance % not found', p_remittance_id
      using errcode = 'P0002';
  end if;

  if v_remittance.status <> 'submitted' then
    if (p_approve and v_remittance.status = 'verified')
       or (not p_approve and v_remittance.status = 'rejected') then
      return v_remittance;
    end if;
    raise exception 'Remittance is already %', v_remittance.status
      using errcode = 'P0001';
  end if;

  select * into v_receivable
    from public.platform_fee_receivables r
   where r.id = v_remittance.receivable_id
   for update;

  if v_receivable.status = 'disputed' then
    raise exception 'Receivable is disputed'
      using errcode = 'P0001';
  end if;

  if v_receivable.status = 'waived' then
    raise exception 'Receivable is waived'
      using errcode = 'P0001';
  end if;

  if not p_approve then
    if p_rejection_reason is null
       or length(trim(p_rejection_reason)) = 0 then
      raise exception 'A rejection reason is required'
        using errcode = '22023';
    end if;

    update public.provider_fee_remittances
       set status = 'rejected',
           verified_by = v_actor,
           verified_at = now(),
           rejection_reason = trim(p_rejection_reason)
     where id = v_remittance.id
     returning * into v_remittance;

    return v_remittance;
  end if;

  v_remaining := v_receivable.amount_centavos
    - v_receivable.amount_remitted_centavos;

  if v_remittance.amount_centavos > v_remaining then
    raise exception 'Verified remittance exceeds outstanding receivable'
      using errcode = 'P0001';
  end if;

  v_new_total := v_receivable.amount_remitted_centavos
    + v_remittance.amount_centavos;

  v_new_status := case
    when v_new_total >= v_receivable.amount_centavos then 'remitted'
    else 'partially_remitted'
  end;

  update public.platform_fee_receivables
     set amount_remitted_centavos = v_new_total,
         status = v_new_status,
         last_remittance_at = now()
   where id = v_receivable.id;

  update public.provider_fee_remittances
     set status = 'verified',
         verified_by = v_actor,
         verified_at = now(),
         rejection_reason = null
   where id = v_remittance.id
   returning * into v_remittance;

  return v_remittance;
end;
$$;

revoke all on function public.round_centavos(numeric)
  from public, anon, authenticated, service_role;
revoke all on function public.get_active_pricing_policy(
  public.service_type, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function public.calculate_service_price(
  public.service_type, numeric, integer, uuid, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function public.ensure_transaction_accounts(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.settle_service_transaction(
  public.service_type, uuid, numeric, integer, uuid
) from public, anon, authenticated, service_role;
revoke all on function public.confirm_cash_collection(
  uuid, bigint, uuid, text
) from public, anon, authenticated, service_role;
revoke all on function public.fail_cash_collection(uuid, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.open_cash_payment_dispute(
  uuid, text, bigint, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function public.resolve_cash_payment_dispute(
  uuid, public.cash_dispute_status, text, uuid
) from public, anon, authenticated, service_role;
revoke all on function public.record_provider_fee_remittance(
  uuid, bigint, text, uuid, text
) from public, anon, authenticated, service_role;
revoke all on function public.verify_provider_fee_remittance(
  uuid, boolean, uuid, text
) from public, anon, authenticated, service_role;

grant execute on function public.get_active_pricing_policy(
  public.service_type, timestamptz
) to authenticated, service_role;
grant execute on function public.calculate_service_price(
  public.service_type, numeric, integer, uuid, timestamptz
) to authenticated, service_role;
grant execute on function public.settle_service_transaction(
  public.service_type, uuid, numeric, integer, uuid
) to authenticated, service_role;
grant execute on function public.confirm_cash_collection(
  uuid, bigint, uuid, text
) to authenticated, service_role;
grant execute on function public.fail_cash_collection(uuid, text, uuid)
  to authenticated, service_role;
grant execute on function public.open_cash_payment_dispute(
  uuid, text, bigint, uuid, uuid
) to authenticated, service_role;
grant execute on function public.resolve_cash_payment_dispute(
  uuid, public.cash_dispute_status, text, uuid
) to authenticated, service_role;
grant execute on function public.record_provider_fee_remittance(
  uuid, bigint, text, uuid, text
) to authenticated, service_role;
grant execute on function public.verify_provider_fee_remittance(
  uuid, boolean, uuid, text
) to authenticated, service_role;

















