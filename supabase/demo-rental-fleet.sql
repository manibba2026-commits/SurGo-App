-- Idempotent presentation fleet for hosted vehicle owners.
--
-- The imported demo data gave Alex Tan, Danilo Cruz, Grace Ann Villaflor and
-- Rosalinda Pajo the vehicle_owner role but no listed vehicle, so the rental
-- map and catalogue only ever showed two owners. This seed adds one realistic
-- Tandag listing per missing owner (and a second for the two larger fleets).
--
-- Every id is md5(slug), every owner is resolved by the demo phone number, and
-- the conflict target is the id, so rerunning updates nothing and never creates
-- a duplicate. No account, credential or existing vehicle is changed.

with fleet (
  slug, phone, name, vehicle_type, category, make, model, model_year, color,
  plate_number, price_per_day_centavos, rating, total_rentals
) as (
  values
    ('alex-mio-i125', '639170000001', 'Yamaha Mio i125', 'Motorcycle', '2-Wheel',
     'Yamaha', 'Mio i125', 2023, 'Red', 'NGD 5102', 50000, 4.90, 18),
    ('danilo-fortuner', '639170000004', 'Toyota Fortuner', 'SUV', '4-Wheel',
     'Toyota', 'Fortuner', 2019, 'Silver', 'NGD 8830', 250000, 4.85, 12),
    ('danilo-dmax', '639170000004', 'Isuzu D-Max', 'Truck', '4-Wheel',
     'Isuzu', 'D-Max', 2020, 'White', 'NGD 8841', 180000, 4.75, 7),
    ('grace-ertiga', '639170000007', 'Suzuki Ertiga', 'Van', '4-Wheel',
     'Suzuki', 'Ertiga', 2022, 'Pearl White', 'NGD 9210', 150000, 4.90, 9),
    ('grace-click', '639170000007', 'Honda Click 125i', 'Motorcycle', '2-Wheel',
     'Honda', 'Click 125i', 2024, 'Matte Black', 'NGD 9211', 60000, 4.80, 6),
    ('rosalinda-avanza', '639170000019', 'Toyota Avanza', 'Van', '4-Wheel',
     'Toyota', 'Avanza', 2021, 'Gray', 'NGD 3115', 140000, 4.70, 14),
    ('rosalinda-fazzio', '639170000019', 'Yamaha Fazzio', 'Motorcycle', '2-Wheel',
     'Yamaha', 'Fazzio', 2024, 'Cream', 'NGD 3116', 55000, 4.80, 5)
)
insert into public.vehicles (
  id, owner_profile_id, service_area_id, name, vehicle_type, category,
  make, model, model_year, color, plate_number, price_per_day_centavos,
  status, rating, total_rentals, created_at, updated_at
)
select
  md5('surgo:demo:vehicle:' || f.slug)::uuid,
  p.id,
  (select id from public.service_areas where is_active order by created_at limit 1),
  f.name, f.vehicle_type, f.category, f.make, f.model, f.model_year, f.color,
  f.plate_number, f.price_per_day_centavos, 'active', f.rating, f.total_rentals,
  now(), now()
from fleet f
join public.profiles p
  on regexp_replace(p.phone, '^\+', '') = f.phone
on conflict (id) do nothing;
