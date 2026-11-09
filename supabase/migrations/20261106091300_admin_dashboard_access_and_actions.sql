
-- 1. Admin helper ------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.has_approved_role('admin'::public.user_role_type); $$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- 2. Additive admin read policies (participant policies untouched) ------
create policy admin_read_ride_requests on public.ride_requests for select to authenticated using (public.is_admin());
create policy admin_read_ride_status_events on public.ride_status_events for select to authenticated using (public.is_admin());
create policy admin_read_ride_locations on public.ride_locations for select to authenticated using (public.is_admin());
create policy admin_read_ride_ratings on public.ride_ratings for select to authenticated using (public.is_admin());
create policy admin_read_rental_bookings on public.rental_bookings for select to authenticated using (public.is_admin());
create policy admin_read_service_requests on public.service_requests for select to authenticated using (public.is_admin());
create policy admin_read_service_request_items on public.service_request_items for select to authenticated using (public.is_admin());
create policy admin_read_service_status_events on public.service_status_events for select to authenticated using (public.is_admin());
create policy admin_read_pricing_policies on public.pricing_policies for select to authenticated using (public.is_admin());
create policy admin_read_audit_logs on public.admin_audit_logs for select to authenticated using (public.is_admin());

-- 3. Admin may read (and sign URLs for) private document buckets --------
create policy "surgo admin read documents" on storage.objects for select to authenticated
  using (bucket_id in ('verification-documents','vehicle-documents') and public.is_admin());

-- 4. Internal audit helper ---------------------------------------------
create or replace function public._admin_audit(p_action text, p_entity text, p_id uuid, p_before jsonb, p_after jsonb)
returns void language sql security definer set search_path = ''
as $$ insert into public.admin_audit_logs(actor_id, action, entity_type, entity_id, before_state, after_state)
      values (auth.uid(), p_action, p_entity, p_id, p_before, p_after); $$;
revoke all on function public._admin_audit(text,text,uuid,jsonb,jsonb) from public, anon, authenticated;

-- 5. Admin actions (security definer, admin-checked, audited) ----------
create or replace function public.admin_review_verification(p_application_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare a public.verification_applications; new_status public.verification_status;
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_decision not in ('approved','rejected','needs_resubmission') then raise exception 'invalid decision'; end if;
  if p_decision <> 'approved' and coalesce(trim(p_reason),'') = '' then raise exception 'reason required'; end if;
  select * into a from public.verification_applications where id = p_application_id for update;
  if not found then raise exception 'application not found'; end if;
  if a.status not in ('submitted','under_review','needs_resubmission') then raise exception 'application not reviewable in status %', a.status; end if;
  new_status := p_decision::public.verification_status;
  update public.verification_applications
     set status = new_status, reviewed_by = auth.uid(), reviewed_at = now(), decided_at = now(),
         rejection_reason = case when p_decision = 'approved' then null else p_reason end
   where id = p_application_id;
  if p_decision = 'approved' then
    insert into public.user_roles(profile_id, role, status, approved_at, approved_by)
      values (a.profile_id, a.capability_type, 'approved', now(), auth.uid())
    on conflict do nothing;
    update public.user_roles set status='approved', approved_at=now(), approved_by=auth.uid()
     where profile_id = a.profile_id and role = a.capability_type and status <> 'approved';
  end if;
  perform public._admin_audit('verification.'||p_decision,'verification_application',p_application_id,
     jsonb_build_object('status',a.status), jsonb_build_object('status',p_decision,'reason',p_reason));
end $$;

create or replace function public.admin_review_document(p_kind text, p_document_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'invalid decision'; end if;
  if p_decision = 'rejected' and coalesce(trim(p_reason),'') = '' then raise exception 'reason required'; end if;
  if p_kind = 'verification' then
    update public.verification_documents set status=p_decision::public.document_review_status, reviewed_by=auth.uid(), reviewed_at=now(),
           rejection_reason = case when p_decision='approved' then null else p_reason end where id = p_document_id;
  elsif p_kind = 'vehicle' then
    update public.vehicle_documents set status=p_decision::public.document_review_status, reviewed_by=auth.uid(), reviewed_at=now(),
           rejection_reason = case when p_decision='approved' then null else p_reason end where id = p_document_id;
  else raise exception 'invalid kind'; end if;
  if not found then raise exception 'document not found'; end if;
  perform public._admin_audit('document.'||p_decision, p_kind||'_document', p_document_id, null, jsonb_build_object('decision',p_decision,'reason',p_reason));
end $$;

create or replace function public.admin_set_account_status(p_profile_id uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare old_status public.account_status;
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('active','suspended') then raise exception 'invalid status'; end if;
  if p_profile_id = auth.uid() then raise exception 'cannot change your own account status'; end if;
  select account_status into old_status from public.profiles where id = p_profile_id for update;
  if not found then raise exception 'profile not found'; end if;
  update public.profiles set account_status = p_status::public.account_status where id = p_profile_id;
  perform public._admin_audit('account.'||p_status,'profile',p_profile_id,
     jsonb_build_object('status',old_status), jsonb_build_object('status',p_status,'reason',p_reason));
end $$;

create or replace function public.admin_set_vehicle_status(p_vehicle_id uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare old_status public.vehicle_status;
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select status into old_status from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'vehicle not found'; end if;
  update public.vehicles set status = p_status::public.vehicle_status where id = p_vehicle_id;
  perform public._admin_audit('vehicle.'||p_status,'vehicle',p_vehicle_id,
     jsonb_build_object('status',old_status), jsonb_build_object('status',p_status,'reason',p_reason));
end $$;

create or replace function public.admin_update_remittance(p_remittance_id uuid, p_status text, p_reference text default null, p_notes text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare old_status public.remittance_status;
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('remitted','waived','overdue','pending') then raise exception 'invalid status'; end if;
  if p_status = 'remitted' and coalesce(trim(p_reference),'') = '' then raise exception 'reference number required to mark remitted'; end if;
  select status into old_status from public.cash_fee_remittances where id = p_remittance_id for update;
  if not found then raise exception 'remittance not found'; end if;
  update public.cash_fee_remittances
     set status = p_status::public.remittance_status,
         remitted_at = case when p_status='remitted' then now() else null end,
         remitted_to_profile_id = case when p_status='remitted' then auth.uid() else null end,
         reference_number = coalesce(p_reference, reference_number),
         notes = coalesce(p_notes, notes)
   where id = p_remittance_id;
  perform public._admin_audit('remittance.'||p_status,'cash_fee_remittance',p_remittance_id,
     jsonb_build_object('status',old_status), jsonb_build_object('status',p_status,'reference',p_reference));
end $$;

-- 6. Read-only aggregates ----------------------------------------------
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
        select service_type, sum(platform_revenue_centavos)::bigint s from public.service_transactions where status='completed' group by 1) x), '{}'::jsonb),
    'revenue_total', coalesce((select sum(platform_revenue_centavos) from public.service_transactions where status='completed'),0),
    'remit_outstanding', coalesce((select sum(amount_centavos) from public.cash_fee_remittances where status in ('pending','overdue')),0),
    'remit_overdue', coalesce((select sum(amount_centavos) from public.cash_fee_remittances where status='overdue'),0),
    'remit_remitted', coalesce((select sum(amount_centavos) from public.cash_fee_remittances where status='remitted'),0)
  ) into r;
  return r;
end $$;

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
    coalesce((select sum(x.platform_revenue_centavos) from public.service_transactions x where x.status='completed' and (coalesce(x.settled_at,x.created_at) at time zone 'Asia/Manila')::date = d::date),0)::bigint
  from generate_series(((now() at time zone 'Asia/Manila')::date - (p_days-1)), (now() at time zone 'Asia/Manila')::date, interval '1 day') d
  order by 1;
end $$;

-- 7. Lock down execution -----------------------------------------------
do $$ declare f text; begin
  foreach f in array array[
    'admin_review_verification(uuid,text,text)','admin_review_document(text,uuid,text,text)',
    'admin_set_account_status(uuid,text,text)','admin_set_vehicle_status(uuid,text,text)',
    'admin_update_remittance(uuid,text,text,text)','admin_overview()','admin_daily_activity(int)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
