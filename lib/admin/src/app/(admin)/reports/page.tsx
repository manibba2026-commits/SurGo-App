import { createClient } from '@/lib/supabase/server';
import { ok, type Row } from '@/lib/query';
import { peso, num } from '@/lib/format';
import { PageHeader, Panel, Stat, Filters, Field, Select, Empty } from '@/components/ui';
import { StackedBars, LineTrend, HBars } from '@/components/charts';

export default async function Reports({ searchParams }: { searchParams: { days?: string } }) {
  const days = [7, 14, 30, 90].includes(Number(searchParams.days)) ? Number(searchParams.days) : 30;
  const db = createClient();
  const since = new Date(Date.now() - days * 864e5).toISOString();
  const [daily, geo] = await Promise.all([
    db.rpc('admin_daily_activity', { p_days: days }),
    db.from('ride_requests').select('pickup_barangay_id,status,pickup_latitude,barangay:barangays!ride_requests_pickup_barangay_fkey(name)').gte('requested_at', since).limit(5000),
  ]);
  const series = (ok(daily as any, 'Daily activity') as Row[]).map((r) => ({ ...r, day: r.day as string })) as (Row & { day: string })[];
  const rides = ok(geo as any, 'Ride locations') as Row[];
  const sum = (k: string) => series.reduce((a, r) => a + Number((r as Row)[k]), 0);
  const byBrgy = new Map<string, number>();
  rides.forEach((r) => byBrgy.set(r.barangay?.name ?? 'Unknown', (byBrgy.get(r.barangay?.name ?? 'Unknown') ?? 0) + 1));
  const top = [...byBrgy.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10).map(([name, value]) => ({ name, value }));
  const completed = rides.filter((r) => r.status === 'completed').length;
  return (
    <>
      <PageHeader title="Reports & analytics" sub="Operational summaries for the selected window (Asia/Manila days)." />
      <Filters action="/reports"><Field name="days" label="Window"><Select name="days" defaultValue={String(days)} options={[['7', 'Last 7 days'], ['14', 'Last 14 days'], ['30', 'Last 30 days'], ['90', 'Last 90 days']]} /></Field></Filters>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
        <Stat name="New users" value={num(sum('signups'))} /><Stat name="Rides requested" value={num(sum('rides'))} />
        <Stat name="Rentals requested" value={num(sum('rentals'))} /><Stat name="Pasuyo requested" value={num(sum('pasuyo'))} />
        <Stat name="Fees recorded" value={peso(sum('revenue_centavos'))} hint="accrued" />
      </div>
      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Panel title="User growth (new sign-ups per day)"><LineTrend data={series} k="signups" /></Panel>
        <Panel title="Revenue trend (platform fees recorded)"><LineTrend data={series} k="revenue_centavos" color="#B7791F" fmt={(n) => peso(Math.round(n))} /></Panel>
        <Panel title="Service usage per day" className="lg:col-span-2"><StackedBars data={series} series={[{ key: 'rides', name: 'Rides', color: '#0E7C86' }, { key: 'rentals', name: 'Rentals', color: '#B7791F' }, { key: 'pasuyo', name: 'Pasuyo', color: '#10222F' }]} /></Panel>
      </div>
      <Panel title="Ride demand by pickup barangay" className="mt-4">
        {top.length === 0 ? <Empty title="No rides in this window" hint="Barangay is required on every ride request, so this view is reliable once rides exist." /> : (
          <><HBars items={top} /><p className="mt-4 text-xs text-ink-500">{rides.length} rides requested, {completed} completed, in this window. Grouped by barangay rather than raw coordinates, because only {rides.filter((r) => r.pickup_latitude != null).length} of them include GPS coordinates.</p></>
        )}
      </Panel>
    </>
  );
}
