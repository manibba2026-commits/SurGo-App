import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { ok, type Row } from '@/lib/query';
import { peso, dt, label } from '@/lib/format';
import { PageHeader, Panel, Badge, Who } from '@/components/ui';

export default async function RideDetail({ params }: { params: { id: string } }) {
  const db = createClient();
  const { data: r, error } = await db.from('ride_requests')
    .select('*,passenger:profiles!ride_requests_passenger_id_fkey(id,full_name,phone),rider:profiles!ride_requests_rider_id_fkey(id,full_name,phone),pickup_brgy:barangays!ride_requests_pickup_barangay_fkey(name),drop_brgy:barangays!ride_requests_dropoff_barangay_fkey(name)')
    .eq('id', params.id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!r) notFound();
  const [ev, rate, tx] = await Promise.all([
    db.from('ride_status_events').select('status,note,created_at').eq('ride_id', r.id).order('created_at'),
    db.from('ride_ratings').select('stars,comment').eq('ride_id', r.id).maybeSingle(),
    db.from('service_transactions').select('*,remittances:cash_fee_remittances(id,status,amount_centavos,remitted_at,reference_number)').eq('ride_id', r.id).maybeSingle(),
  ]);
  const events = ok(ev as any, 'Status history') as Row[];
  const t = tx.data as Row | null, rating = rate.data as Row | null;
  return (
    <>
      <PageHeader title="Ride" sub={`${r.pickup_address} → ${r.dropoff_address}`} actions={<Badge status={r.status} />} />
      <div className="grid gap-4 lg:grid-cols-3">
        <Panel title="Trip">
          <dl className="space-y-2 text-sm">
            {[['Passenger', <Who key="p" p={r.passenger} id={r.passenger?.id} href />], ['Rider', <Who key="r" p={r.rider} id={r.rider?.id} href />],
              ['Pickup area', r.pickup_brgy?.name], ['Drop-off area', r.drop_brgy?.name ?? '—'], ['Distance', `${Number(r.distance_km).toFixed(1)} km`], ['ETA', `${r.eta_minutes} min`],
              ['Requested', dt(r.requested_at)], ['Accepted', dt(r.accepted_at)], ['Started', dt(r.started_at)], ['Completed', dt(r.completed_at)], ['Cancelled', dt(r.cancelled_at)]].map(([k, v]) => (
              <div key={String(k)} className="flex justify-between gap-3"><dt className="text-ink-500">{k}</dt><dd className="text-right">{v}</dd></div>))}
          </dl>
          {r.cancellation_reason && <p className="mt-3 text-sm text-coral">Cancelled: {r.cancellation_reason}</p>}
        </Panel>
        <Panel title="Fare breakdown (cash)">
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between"><dt className="text-ink-500">Provider fare</dt><dd className="tabular-nums">{peso(r.fare_centavos)}</dd></div>
            <div className="flex justify-between"><dt className="text-ink-500">Platform fee</dt><dd className="tabular-nums">{peso(r.platform_fee_centavos)}</dd></div>
            <div className="flex justify-between border-t border-line pt-2 font-medium"><dt>Customer total</dt><dd className="tabular-nums">{peso(r.fare_centavos + r.platform_fee_centavos)}</dd></div>
          </dl>
          {t ? (
            <div className="mt-4 border-t border-line pt-3 text-sm">
              <div className="mb-1 flex justify-between"><span className="text-ink-500">Transaction</span><Badge status={t.status} /></div>
              <div className="flex justify-between"><span className="text-ink-500">Provider payout</span><span className="tabular-nums">{peso(t.provider_payout_centavos)}</span></div>
              <div className="flex justify-between"><span className="text-ink-500">Platform fee recorded</span><span className="tabular-nums">{peso(t.platform_revenue_centavos)}</span></div>
              <div className="mt-2 text-xs text-ink-500">Remittance: {(t.remittances as Row[]).length ? (t.remittances as Row[]).map((x) => `${label(x.status)}${x.remitted_at ? ` ${dt(x.remitted_at)}` : ''}`).join(', ') : 'no remittance record — fee not confirmed as collected'}</div>
            </div>
          ) : <p className="mt-4 border-t border-line pt-3 text-xs text-ink-500">No settlement transaction exists for this ride.</p>}
        </Panel>
        <Panel title="Status history & rating">
          {events.length === 0 ? <p className="text-sm text-ink-500">No status events recorded.</p> : (
            <ol className="space-y-2 text-sm">{events.map((e, i) => <li key={i} className="flex justify-between gap-2"><span className="capitalize">{label(e.status)}</span><span className="text-xs text-ink-500">{dt(e.created_at)}</span></li>)}</ol>
          )}
          <p className="mt-4 border-t border-line pt-3 text-sm">{rating ? `Rated ${rating.stars}/5${rating.comment ? ` — “${rating.comment}”` : ''}` : <span className="text-ink-500">Not rated.</span>}</p>
        </Panel>
      </div>
    </>
  );
}
