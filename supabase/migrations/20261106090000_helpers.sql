-- Shared helpers.
--
-- Kept in their own migration so every later table can reuse them without
-- depending on which domain migration happens to run first.

-- Generic updated_at trigger. Tables that expose updated_at attach this so
-- clients never control the column and clocks stay server-side.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Sets updated_at to now() on every UPDATE.';
