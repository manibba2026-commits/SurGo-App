-- Idempotent demo rider presence for the hosted SurGo project.
--
-- Run after the migrations and after the demo profiles/providers exist. Every
-- row is keyed by the existing profile's phone, so rerunning updates the same
-- row and never creates a replacement account or a second presence record.
--
-- Six eligible riders are online and free; two are deliberately offline. Junel
-- Ramos is suspended and gets no presence row, so the suspended account cannot
-- become dispatchable by rerunning the seed.
--
-- All coordinates are simulated positions around Tandag City, one per
-- barangay, and are marked is_simulated = true. They are not device GPS.

with demo_presence (
  phone, is_online, latitude, longitude, heading_degrees,
  barangay_name, vehicle_type, vehicle_label, vehicle_plate
) as (
  values
    -- Online and available.
    ('639170000002', true,  9.0825, 126.1985,  45, 'Awasian',
     'motorcycle', 'Honda Click 125i', 'NGD 4821'),          -- Bebot Lim
    ('639170000003', true,  9.0785, 126.2025,  90, 'Bagong Lungsod (Poblacion)',
     'tricycle',   'Bajaj RE',         'NGD 7350'),          -- Carlo Mendoza
    ('639170000005', true,  9.0745, 126.1985, 180, 'Bioto',
     'motorcycle', 'Yamaha Mio Gear',  'NGD 6613'),          -- Danny Reyes
    ('639170000008', true,  9.0765, 126.2065, 270, 'Bongtod Poblacion (East West)',
     'multicab',   'Suzuki Multicab',  'NGD 4478'),          -- Isabella Dizon
    ('639170000010', true,  9.0705, 126.1945,   0, 'San Isidro',
     'motorcycle', 'Yamaha Mio 2025',  'NGD 6612'),          -- Jr Derigay
    ('639170000012', true,  9.0865, 126.1905, 135, 'Telaje',
     'tricycle',   'Local Tricycle',   'NGD 7744'),          -- Kd Sotto

    -- Deliberately offline. Coordinates are kept so the account can be brought
    -- online later without inventing a location, but discovery and the map only
    -- read online rows.
    ('639170000009', false, 9.0805, 126.1945, 315, 'Dagocdoc (Poblacion)',
     'motorcycle', 'Honda Beat 110',   'NGD 6121'),          -- Jomar Lim
    ('639170000015', false, 9.0905, 126.2105, 225, 'Mabua',
     'motorcycle', 'Yamaha Sniper 150', 'NGD 9046')          -- Marlon Uy
)
insert into public.rider_presence as rp (
  profile_id, is_online, is_available, latitude, longitude, heading_degrees,
  barangay_id, vehicle_type, vehicle_label, vehicle_plate,
  is_simulated, source, updated_at
)
select
  p.id,
  d.is_online,
  d.is_online and not public.rider_has_active_ride(p.id),
  d.latitude,
  d.longitude,
  d.heading_degrees,
  b.id,
  d.vehicle_type,
  d.vehicle_label,
  d.vehicle_plate,
  true,
  'demo',
  now()
from demo_presence d
join public.profiles p
  on regexp_replace(p.phone, '^\+', '') = d.phone
left join public.barangays b
  on b.service_area_id = (
       select id from public.service_areas where is_active
        order by created_at limit 1
     )
 and b.name = d.barangay_name
on conflict (profile_id) do update set
  is_online = excluded.is_online,
  is_available = excluded.is_available,
  latitude = excluded.latitude,
  longitude = excluded.longitude,
  heading_degrees = excluded.heading_degrees,
  barangay_id = excluded.barangay_id,
  vehicle_type = excluded.vehicle_type,
  vehicle_label = excluded.vehicle_label,
  vehicle_plate = excluded.vehicle_plate,
  is_simulated = true,
  source = 'demo',
  updated_at = now();

-- Keep the legacy provider flag in step with the presence row. Screens that
-- still read provider_profiles.is_available must not disagree with discovery.
update public.provider_profiles pp
   set is_available = coalesce(rp.is_available, false)
  from public.profiles p
  left join public.rider_presence rp on rp.profile_id = p.id
 where pp.profile_id = p.id
   and regexp_replace(p.phone, '^\+', '') in (
     '639170000002', '639170000003', '639170000005', '639170000008',
     '639170000010', '639170000012', '639170000009', '639170000015'
   );

-- A suspended account must not keep a dispatchable demo presence. Deleting a
-- demo row is safe because the seed owns these rows; the account and its
-- history are untouched.
delete from public.rider_presence rp
 using public.profiles p
 where rp.profile_id = p.id
   and rp.source = 'demo'
   and p.account_status = 'suspended';

update public.profiles p
   set last_seen_at = now()
  from public.rider_presence rp
 where rp.profile_id = p.id
   and rp.is_online
   and rp.source = 'demo';
