import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { ok, type Row } from '@/lib/query';
import { peso, num, dt, label } from '@/lib/format';
import { PageHeader, Panel, Stat, Badge, Empty, Who } from '@/components/ui';
import { StackedBars, LineTrend, HBars, FeeStrip } from '@/components/charts';

export default async function Overview() {
  const db = createClient();
  const [ov, daily, rides, regs] = await Promise.all([
    db.rpc('admin_overview'),
    db.rpc('admin_daily_activity', { p_days: 14 }),
    db.from('ride_requests').select('id,status,pickup_address,dropoff_address,fare_centavos,platform_fee_centavos,requested_at,passenger:profiles!ride_requests_passenger_id_fkey(full_name)').order('requested_at', { ascending: false }).limit(6),
    db.from('profiles').select('id,full_name,email,phone,created_at,user_roles!user_roles_profile_id_fkey(role,status)').order('created_at', { ascending: false }).limit(6),
  ]);
  const o = ok(ov as any, 'Overview metrics') as Row;
  const days = (ok(daily as any, 'Daily activity') as Row[]).map((r) => ({ ...r, day: r.day as string }));
  const recentRides = ok(rides as any, 'Recent rides') as Row[];
  const recentUsers = ok(regs as any, 'Recent registrations') as Row[];
  const rev = (o.revenue_by_service ?? {}) as Record<string, number>;
  const pending = [
    { name: 'Verification applications awaiting review', n: o.verifications_pending, href: '/verification' },
    { name: 'Vehicle documents awaiting review', n: o.vehicle_docs_pending, href: '/verification' },
    { name: 'Overdue platform fee remittances', n: o.remit_overdue > 0 ? 1 : 0, href: '/finance?status=overdue', money: o.remit_overdue as number },
    { name: 'Suspended accounts', n: o.users_suspended, href: '/users?status=suspended' },
  ];
  return (
    <>
      <PageHeader title="Overview" sub="Live figures from the SurGo database. Nothing on this page is estimated or sample data." />
      {o.users_total === 0 && (
        <div className="mb-6 rounded-lg border border-sea/30 bg-sea-50 px-4 py-3 text-sm text-ink">
          No users exist in the database yet. Counts show zero until the SurGo app starts writing to Supabase.
        </div>
      )}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat name="Registered users" value={num(o.users_total)} />
        <Stat name="Passengers" value={num(o.passengers)} hint="approved role" />
        <Stat name="Riders / helpers" value={num(o.riders)} hint="approved role" />
        <Stat name="Vehicle owners" value={num(o.vehicle_owners)} hint="approved role" />
        <Stat name="Ride requests" value={num(o.rides_total)} />
        <Stat name="Completed rides" value={num(o.rides_completed)} />
        <Stat name="Active rides" value={num(o.rides_active)} />
        <Stat name="Cancelled rides" value={num(o.rides_cancelled)} />
        <Stat name="Active rentals" value={num(o.rentals_active)} hint="requested through active" />
        <Stat name="Active Pasuyo" value={num(o.pasuyo_active)} />
        <Stat name="Platform fees recorded" value={peso(o.revenue_total)} hint="accrued; not cash received" />
        <Stat name="Fees outstanding" value={peso(o.remit_outstanding)} tone={o.remit_overdue > 0 ? 'bad' : o.remit_outstanding > 0 ? 'warn' : undefined} hint={`${peso(o.remit_overdue)} overdue`} />
      </div>

      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        <Panel title="Daily activity, last 14 days" className="lg:col-span-2">
          <StackedBars data={days} series={[
            { key: 'rides', name: 'Rides', color: '#0E7C86' },
            { key: 'rentals', name: 'Rentals', color: '#B7791F' },
            { key: 'pasuyo', name: 'Pasuyo', color: '#10222F' },
          ]} />
        </Panel>
        <Panel title="Service distribution">
          <HBars items={[{ name: 'Rides', value: o.rides_total }, { name: 'Rentals', value: o.rentals_total }, { name: 'Pasuyo', value: o.pasuyo_total }]} />
          <p className="mt-4 text-xs text-ink-500">Requests created, all time.</p>
        </Panel>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Panel title="Platform fee revenue trend" className="lg:col-span-2">
          <LineTrend data={days} k="revenue_centavos" fmt={(n) => peso(Math.round(n))} />
          <p className="mt-2 text-xs text-ink-500">Fees recorded on completed transactions. Rides {peso(rev.ride ?? 0)} · Rentals {peso(rev.rental ?? 0)} · Pasuyo {peso(rev.pasuyo ?? 0)}</p>
        </Panel>
        <Panel title="Fee remittance">
          <FeeStrip remitted={o.remit_remitted} outstanding={o.remit_outstanding} overdue={o.remit_overdue} />
          <dl className="mt-4 space-y-1.5 text-sm">
            <div className="flex justify-between"><dt className="text-ink-500">Remitted</dt><dd className="tabular-nums">{peso(o.remit_remitted)}</dd></div>
            <div className="flex justify-between"><dt className="text-ink-500">Outstanding</dt><dd className="tabular-nums">{peso(o.remit_outstanding)}</dd></div>
            <div className="flex justify-between"><dt className="text-ink-500">of which overdue</dt><dd className="tabular-nums text-coral">{peso(o.remit_overdue)}</dd></div>
          </dl>
        </Panel>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Panel title="Needs attention">
          <ul className="space-y-2 text-sm">
            {pending.map((p) => (
              <li key={p.name} className="flex items-center justify-between gap-3">
                <Link href={p.href} className="text-ink hover:underline">{p.name}</Link>
                <span className={`tabular-nums ${p.n > 0 ? 'font-semibold text-amber' : 'text-ink-300'}`}>{p.money ? peso(p.money) : p.n}</span>
              </li>
            ))}
          </ul>
        </Panel>
        <Panel title="Recent ride activity" className="lg:col-span-2" aside={<Link href="/rides" className="text-sm text-sea-600 hover:underline">All rides</Link>}>
          {recentRides.length === 0 ? <Empty title="No rides yet" hint="Ride requests will appear here as soon as passengers book." /> : (
            <ul className="divide-y divide-line text-sm">
              {recentRides.map((r) => (
                <li key={r.id} className="flex items-center justify-between gap-3 py-2">
                  <div className="min-w-0"><Link href={`/rides/${r.id}`} className="block truncate hover:underline">{r.pickup_address} → {r.dropoff_address}</Link>
                    <div className="text-xs text-ink-500"><Who p={r.passenger} /> · {dt(r.requested_at)}</div></div>
                  <div className="flex shrink-0 items-center gap-3"><span className="tabular-nums">{peso(r.fare_centavos + r.platform_fee_centavos)}</span><Badge status={r.status} /></div>
                </li>
              ))}
            </ul>
          )}
        </Panel>
      </div>

      <Panel title="Recent registrations" className="mt-4" aside={<Link href="/users" className="text-sm text-sea-600 hover:underline">All users</Link>}>
        {recentUsers.length === 0 ? <Empty title="No registrations yet" /> : (
          <ul className="divide-y divide-line text-sm">
            {recentUsers.map((u) => (
              <li key={u.id} className="flex items-center justify-between gap-3 py-2">
                <Link href={`/users/${u.id}`} className="hover:underline">{u.full_name}</Link>
                <span className="text-ink-500">{(u.user_roles as Row[]).map((r) => label(r.role)).join(', ') || 'no role yet'}</span>
                <span className="text-xs text-ink-500">{dt(u.created_at)}</span>
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  );
}
