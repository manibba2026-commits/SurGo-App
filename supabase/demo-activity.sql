-- Idempotent demo history and simulated-activity attribution.
--
-- Apply after 20261111160000_demo_activity_attribution.sql and after the demo
-- profiles, geography and presence rows exist. Every identifier is derived from
-- a fixed string, so re-running updates or skips the same rows and never adds a
-- second copy. No account, UUID or credential is created here.
--
-- What this seed does:
--   * marks every history row owned by the 19 demo phone accounts as simulated;
--   * closes stale unanswered demo requests that no rider can ever answer;
--   * backfills the ride and Pasuyo status timeline that the imported history
--     was missing;
--   * adds one deterministic completed ride for each online demo rider who had
--     no rider-side history (Carlo, Danny, Isabella, Bebot), with the matching
--     zero-fee settlement and notifications;
--   * adds a demo rating for every completed ride.
--
-- The new settlements carry platform_fee_centavos = 0 and
-- platform_revenue_centavos = 0. They are demonstration cash, not collected
-- platform revenue, and admin Overview excludes them by the is_simulated flag.

drop table if exists _demo_profile_ids;
create temp table _demo_profile_ids as
select p.id
  from public.profiles p
 where p.phone in (
   '+639170000001', '+639170000002', '+639170000003', '+639170000004',
   '+639170000005', '+639170000006', '+639170000007', '+639170000008',
   '+639170000009', '+639170000010', '+639170000011', '+639170000012',
   '+639170000013', '+639170000014', '+639170000015', '+639170000016',
   '+639170000017', '+639170000018', '+639170000019'
 );

drop table if exists _demo_seeded_rides;
create temp table _demo_seeded_rides (id uuid primary key);

insert into _demo_seeded_rides (id) values
  (md5('surgo:demo:ride:carlo-rosalinda')::uuid),
  (md5('surgo:demo:ride:danny-nena')::uuid),
  (md5('surgo:demo:ride:isabella-grace')::uuid),
  (md5('surgo:demo:ride:bebot-danilo')::uuid);

-- 1. Attribute the imported history to the demo dataset ----------------------

update public.ride_requests rr
   set is_simulated = true
  from _demo_profile_ids d
 where not rr.is_simulated
   and (rr.passenger_id = d.id or rr.rider_id = d.id);

update public.rental_bookings rb
   set is_simulated = true
  from _demo_profile_ids d
 where not rb.is_simulated
   and (rb.renter_id = d.id or rb.owner_id = d.id);

update public.service_requests sr
   set is_simulated = true
  from _demo_profile_ids d
 where not sr.is_simulated
   and (sr.customer_id = d.id or sr.provider_id = d.id);

update public.wallet_transactions wt
   set is_simulated = true
  from public.wallet_accounts wa
  join _demo_profile_ids d on d.id = wa.profile_id
 where wt.wallet_account_id = wa.id
   and not wt.is_simulated;

update public.service_transactions st
   set is_simulated = true
  from _demo_profile_ids d
 where not st.is_simulated
   and (st.customer_id = d.id or st.provider_id = d.id);

update public.notifications n
   set is_simulated = true
  from _demo_profile_ids d
 where n.profile_id = d.id
   and not n.is_simulated;

update public.ride_status_events e
   set is_simulated = true
  from public.ride_requests rr
  join _demo_profile_ids d
    on d.id = rr.passenger_id or d.id = rr.rider_id
 where e.ride_id = rr.id
   and not e.is_simulated;

update public.service_status_events e
   set is_simulated = true
  from public.service_requests sr
  join _demo_profile_ids d
    on d.id = sr.customer_id or d.id = sr.provider_id
 where e.service_request_id = sr.id
   and not e.is_simulated;

update public.ride_ratings r
   set is_simulated = true
  from public.ride_requests rr
  join _demo_profile_ids d
    on d.id = rr.passenger_id or d.id = rr.rider_id
 where r.ride_id = rr.id
   and not r.is_simulated;

-- 2. A stale unanswered request is history, not a live booking --------------

update public.ride_requests rr
   set status = 'cancelled',
       cancelled_at = coalesce(
         rr.cancelled_at,
         coalesce(rr.requested_at, rr.created_at) + interval '30 minutes'
       ),
       cancellation_reason = coalesce(
         rr.cancellation_reason, 'Expired before a rider accepted'
       ),
       updated_at = now(),
       is_simulated = true
  from _demo_profile_ids d
 where rr.passenger_id = d.id
   and rr.status = 'awaiting_acceptance'
   and rr.rider_id is null
   and coalesce(rr.requested_at, rr.created_at) < now() - interval '1 hour';

-- 3. Add rider-side history the imported dataset was missing ----------------

with new_rides (
  id, rider_phone, passenger_phone,
  requested_at, accepted_at, started_at, completed_at,
  pickup_address, pickup_barangay, pickup_lat, pickup_lng,
  dropoff_address, dropoff_barangay, dropoff_lat, dropoff_lng,
  distance_km, eta_minutes, fare_centavos
) as (
  values
    (md5('surgo:demo:ride:carlo-rosalinda')::uuid,
     '+639170000003', '+639170000019',
     '2026-10-18T08:15:00+08:00'::timestamptz,
     '2026-10-18T08:18:00+08:00'::timestamptz,
     '2026-10-18T08:26:00+08:00'::timestamptz,
     '2026-10-18T08:41:00+08:00'::timestamptz,
     'Purok 3, San Isidro', 'San Isidro', 9.0705, 126.1945,
     'Bongtod Poblacion', 'Bongtod Poblacion (East West)', 9.0765, 126.2065,
     4.6, 14, 11000),
    (md5('surgo:demo:ride:danny-nena')::uuid,
     '+639170000005', '+639170000016',
     '2026-10-22T17:40:00+08:00'::timestamptz,
     '2026-10-22T17:43:00+08:00'::timestamptz,
     '2026-10-22T17:50:00+08:00'::timestamptz,
     '2026-10-22T18:02:00+08:00'::timestamptz,
     'Telaje', 'Telaje', 9.0865, 126.1905,
     'San Agustin Sur', 'San Agustin Sur', 9.0775, 126.2105,
     3.8, 12, 9500),
    (md5('surgo:demo:ride:isabella-grace')::uuid,
     '+639170000008', '+639170000007',
     '2026-10-28T07:05:00+08:00'::timestamptz,
     '2026-10-28T07:07:00+08:00'::timestamptz,
     '2026-10-28T07:14:00+08:00'::timestamptz,
     '2026-10-28T07:30:00+08:00'::timestamptz,
     'Mabua', 'Mabua', 9.0905, 126.2105,
     'Bagong Lungsod', 'Bagong Lungsod (Poblacion)', 9.0785, 126.2025,
     5.2, 16, 12500),
    (md5('surgo:demo:ride:bebot-danilo')::uuid,
     '+639170000002', '+639170000004',
     '2026-11-02T18:10:00+08:00'::timestamptz,
     '2026-11-02T18:14:00+08:00'::timestamptz,
     '2026-11-02T18:21:00+08:00'::timestamptz,
     '2026-11-02T18:31:00+08:00'::timestamptz,
     'Bioto', 'Bioto', 9.0745, 126.1985,
     'Dagocdoc', 'Dagocdoc (Poblacion)', 9.0805, 126.1945,
     2.9, 10, 8000)
)
insert into public.ride_requests (
  id, passenger_id, rider_id, service_area_id, status,
  pickup_address, pickup_barangay_id, pickup_latitude, pickup_longitude,
  dropoff_address, dropoff_barangay_id, dropoff_latitude, dropoff_longitude,
  distance_km, eta_minutes, fare_centavos, platform_fee_centavos,
  payment_method, requested_at, accepted_at, started_at, completed_at,
  created_at, updated_at, is_simulated
)
select
  n.id, passenger.id, rider.id, sa.id, 'completed',
  n.pickup_address, pb.id, n.pickup_lat, n.pickup_lng,
  n.dropoff_address, db.id, n.dropoff_lat, n.dropoff_lng,
  n.distance_km, n.eta_minutes, n.fare_centavos, 0,
  'cash', n.requested_at, n.accepted_at, n.started_at, n.completed_at,
  n.requested_at, n.completed_at, true
from new_rides n
join public.profiles rider
  on regexp_replace(rider.phone, '^\+', '') = regexp_replace(n.rider_phone, '^\+', '')
join public.profiles passenger
  on regexp_replace(passenger.phone, '^\+', '') =
     regexp_replace(n.passenger_phone, '^\+', '')
join lateral (
  select id from public.service_areas
   where is_active order by created_at limit 1
) sa on true
join public.barangays pb
  on pb.service_area_id = sa.id and pb.name = n.pickup_barangay
join public.barangays db
  on db.service_area_id = sa.id and db.name = n.dropoff_barangay
on conflict (id) do nothing;

-- A completed ride cannot exist without a settlement, and the settlement must
-- conserve cash. The platform fee stays zero under the pricing gate.
insert into public.service_transactions (
  id, service_type, ride_id, customer_id, provider_id, currency,
  fare_centavos, platform_fee_centavos, customer_pays_centavos,
  provider_payout_centavos, platform_revenue_centavos, payment_method,
  status, settled_at, created_at, updated_at, is_simulated
)
select
  md5('surgo:demo:ride-settlement:' || rr.id)::uuid,
  'ride', rr.id, rr.passenger_id, rr.rider_id, 'PHP',
  rr.fare_centavos, 0, rr.fare_centavos, rr.fare_centavos, 0, 'cash',
  'completed', rr.completed_at, rr.completed_at, rr.completed_at, true
from public.ride_requests rr
join _demo_seeded_rides seeded on seeded.id = rr.id
on conflict (id) do nothing;

insert into public.notifications (
  id, profile_id, notification_type, title, body, data,
  read_at, created_at, is_simulated
)
select
  md5('surgo:demo:ride-notification:' || rr.id || ':passenger')::uuid,
  rr.passenger_id, 'ride', 'Trip completed',
  'Your trip from ' || rr.pickup_address || ' to ' || rr.dropoff_address
    || ' is complete.',
  jsonb_build_object(
    'ride_id', rr.id, 'kind', 'ride_completed', 'simulated', true
  ),
  rr.completed_at + interval '5 minutes',
  rr.completed_at + interval '5 minutes', true
from public.ride_requests rr
join _demo_seeded_rides seeded on seeded.id = rr.id
union all
select
  md5('surgo:demo:ride-notification:' || rr.id || ':rider')::uuid,
  rr.rider_id, 'ride', 'Trip completed',
  'The trip from ' || rr.pickup_address || ' to ' || rr.dropoff_address
    || ' is complete. Your cash share is recorded in the demo history.',
  jsonb_build_object(
    'ride_id', rr.id, 'kind', 'ride_completed', 'simulated', true
  ),
  rr.completed_at + interval '5 minutes',
  rr.completed_at + interval '5 minutes', true
from public.ride_requests rr
join _demo_seeded_rides seeded on seeded.id = rr.id
on conflict (id) do nothing;

-- 4. Backfill the activity timeline -----------------------------------------

insert into public.ride_status_events (
  id, ride_id, status, actor_profile_id, note, created_at, is_simulated
)
select md5('surgo:demo:ride-event:' || rr.id || ':searching')::uuid,
       rr.id, 'searching'::public.ride_status, rr.passenger_id,
       'Ride requested in the demo history',
       coalesce(rr.requested_at, rr.created_at), true
  from public.ride_requests rr
  join _demo_profile_ids d on d.id = rr.passenger_id
 where rr.is_simulated
union all
select md5('surgo:demo:ride-event:' || rr.id || ':accepted')::uuid,
       rr.id, 'accepted'::public.ride_status, rr.rider_id,
       'Rider accepted the demo request',
       rr.accepted_at, true
  from public.ride_requests rr
  join _demo_profile_ids d on d.id = rr.passenger_id
 where rr.is_simulated and rr.accepted_at is not null
union all
select md5('surgo:demo:ride-event:' || rr.id || ':in_progress')::uuid,
       rr.id, 'in_progress'::public.ride_status, rr.rider_id,
       'Trip started in the demo history',
       rr.started_at, true
  from public.ride_requests rr
  join _demo_profile_ids d on d.id = rr.passenger_id
 where rr.is_simulated and rr.started_at is not null
union all
select md5('surgo:demo:ride-event:' || rr.id || ':completed')::uuid,
       rr.id, 'completed'::public.ride_status, rr.rider_id,
       'Trip completed in the demo history',
       rr.completed_at, true
  from public.ride_requests rr
  join _demo_profile_ids d on d.id = rr.passenger_id
 where rr.is_simulated and rr.completed_at is not null
union all
select md5('surgo:demo:ride-event:' || rr.id || ':cancelled')::uuid,
       rr.id, 'cancelled'::public.ride_status, rr.passenger_id,
       coalesce(rr.cancellation_reason, 'Cancelled in the demo history'),
       rr.cancelled_at, true
  from public.ride_requests rr
  join _demo_profile_ids d on d.id = rr.passenger_id
 where rr.is_simulated and rr.cancelled_at is not null
on conflict (id) do nothing;

insert into public.service_status_events (
  id, service_request_id, status, actor_profile_id, note, created_at,
  is_simulated
)
select md5('surgo:demo:pasuyo-event:' || sr.id || ':available')::uuid,
       sr.id, 'available'::public.pasuyo_status, sr.customer_id,
       'Errand requested in the demo history',
       coalesce(sr.requested_at, sr.created_at), true
  from public.service_requests sr
  join _demo_profile_ids d on d.id = sr.customer_id
 where sr.is_simulated
union all
select md5('surgo:demo:pasuyo-event:' || sr.id || ':accepted')::uuid,
       sr.id, 'accepted'::public.pasuyo_status, sr.provider_id,
       'Provider accepted the demo errand',
       sr.accepted_at, true
  from public.service_requests sr
  join _demo_profile_ids d on d.id = sr.customer_id
 where sr.is_simulated and sr.accepted_at is not null
union all
select md5('surgo:demo:pasuyo-event:' || sr.id || ':picked_up')::uuid,
       sr.id, 'picked_up'::public.pasuyo_status, sr.provider_id,
       'Items picked up in the demo history',
       sr.picked_up_at, true
  from public.service_requests sr
  join _demo_profile_ids d on d.id = sr.customer_id
 where sr.is_simulated and sr.picked_up_at is not null
union all
select md5('surgo:demo:pasuyo-event:' || sr.id || ':delivered')::uuid,
       sr.id, 'delivered'::public.pasuyo_status, sr.provider_id,
       'Errand delivered in the demo history',
       sr.delivered_at, true
  from public.service_requests sr
  join _demo_profile_ids d on d.id = sr.customer_id
 where sr.is_simulated and sr.delivered_at is not null
union all
select md5('surgo:demo:pasuyo-event:' || sr.id || ':cancelled')::uuid,
       sr.id, 'cancelled'::public.pasuyo_status, sr.customer_id,
       coalesce(sr.cancellation_reason, 'Cancelled in the demo history'),
       sr.cancelled_at, true
  from public.service_requests sr
  join _demo_profile_ids d on d.id = sr.customer_id
 where sr.is_simulated and sr.cancelled_at is not null
on conflict (id) do nothing;

-- One rating per completed ride. The unique index is on ride_id, so a rerun
-- leaves the first rating in place.
insert into public.ride_ratings (
  id, ride_id, rater_id, ratee_id, stars, comment, created_at, is_simulated
)
select md5('surgo:demo:ride-rating:' || rr.id)::uuid,
       rr.id, rr.passenger_id, rr.rider_id,
       case when right(rr.id::text, 1) in ('1', '3', '5', '7', '9')
            then 4 else 5 end,
       case when right(rr.id::text, 1) in ('1', '3', '5', '7', '9')
            then 'Smooth trip, thank you.'
            else 'On time and friendly.' end,
       rr.completed_at + interval '10 minutes', true
  from public.ride_requests rr
  join _demo_profile_ids d on d.id = rr.passenger_id
 where rr.is_simulated
   and rr.status = 'completed'
   and rr.rider_id is not null
   and rr.passenger_id <> rr.rider_id
on conflict (ride_id) do nothing;

drop table if exists _demo_seeded_rides;
drop table if exists _demo_profile_ids;
