-- Publish live-updating tables to Supabase Realtime.
--
-- Realtime respects RLS, so the policies in the RLS baseline migration decide
-- which rows each subscriber can receive.

do $$
declare
  v_table text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach v_table in array array[
      'public.ride_requests',
      'public.ride_status_events',
      'public.ride_locations',
      'public.rental_bookings',
      'public.service_requests',
      'public.service_status_events',
      'public.notifications',
      'public.wallet_accounts'
    ]
    loop
      begin
        execute format(
          'alter publication supabase_realtime add table %s', v_table
        );
      exception
        when duplicate_object then null;
        when undefined_table then null;
      end;
    end loop;
  end if;
end;
$$;
