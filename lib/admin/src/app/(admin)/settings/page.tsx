import { createClient } from '@/lib/supabase/server';
import { ok, type Row } from '@/lib/query';
import { peso, dt, label, agreedRideFeeCentavos } from '@/lib/format';
import { PageHeader, Panel, Table, Badge, Empty } from '@/components/ui';

export default async function Settings() {
  const db = createClient();
  const [areas, brgy, puroks, pol, audit] = await Promise.all([
    db.from('service_areas').select('*'),
    db.from('barangays').select('name').order('name'),
    db.from('puroks').select('id', { count: 'exact', head: true }),
    db.from('pricing_policies').select('*').order('created_at', { ascending: false }),
    db.from('admin_audit_logs').select('id,action,entity_type,entity_id,created_at,actor:profiles!admin_audit_logs_actor_id_fkey(full_name)').order('created_at', { ascending: false }).limit(20),
  ]);
  const A = ok(areas as any, 'Service areas') as Row[], B = ok(brgy as any, 'Barangays') as Row[];
  const P = ok(pol as any, 'Pricing policies') as Row[], L = ok(audit as any, 'Audit log') as Row[];
  return (
    <>
      <PageHeader title="Platform settings" sub="Read-only. Configuration changes need an approved backend workflow and are intentionally not editable here." />
      <div className="grid gap-4 lg:grid-cols-2">
        <Panel title="Service areas">
          {A.length === 0 ? <Empty title="No service areas" /> : A.map((a) => (
            <div key={a.id} className="text-sm"><div className="flex items-center justify-between"><span className="font-medium">{a.name}</span><Badge status={a.is_active ? 'active' : 'inactive'} /></div>
              <p className="text-ink-500">{a.city}, {a.province} · {a.timezone}</p><p className="text-xs text-ink-500">Centre {a.center_latitude}, {a.center_longitude}</p></div>))}
          <p className="mt-3 border-t border-line pt-3 text-sm text-ink-500">{B.length} barangays · {puroks.count ?? 0} puroks</p>
        </Panel>
        <Panel title="Supported barangays"><p className="text-sm leading-relaxed text-ink-500">{B.map((b) => b.name).join(' · ') || 'None'}</p></Panel>
        <Panel title="Pricing policies in the database">
          {P.length === 0 ? <p className="text-sm text-ink-500">No pricing policy is stored. Fares and fees on records come from whatever the app wrote; nothing here is a configured rule.</p> : (
            <ul className="space-y-2 text-sm">{P.map((p) => <li key={p.id} className="flex items-center justify-between"><span>{p.name} <span className="text-ink-500">({label(p.service_type)}, {p.platform_fee_bps} bps + {peso(p.platform_fee_fixed_centavos)})</span></span><Badge status={p.is_active ? 'active' : 'inactive'} /></li>)}</ul>
          )}
        </Panel>
        <Panel title="Agreed ride platform fee (reference)">
          <p className="text-sm">₱2.00 per km, minimum ₱5.00, maximum ₱30.00. Paid by the customer; the provider keeps 100% of the fare.</p>
          <p className="mt-2 text-xs text-ink-500">Shown for reference. It is not yet stored in <code>pricing_policies</code>, so the dashboard does not enforce or recompute it.</p>
          <p className="mt-3 text-sm tabular-nums text-ink-500">Examples: 1 km → {peso(agreedRideFeeCentavos(1))} · 5 km → {peso(agreedRideFeeCentavos(5))} · 20 km → {peso(agreedRideFeeCentavos(20))}</p>
          <p className="mt-2 text-xs text-ink-500">Rental and Pasuyo fee policies: not yet decided.</p>
        </Panel>
      </div>
      <h2 className="mb-3 mt-8 text-lg font-semibold">Recent administrator actions</h2>
      <Table head={['When', 'Administrator', 'Action', 'Record']} empty={<Empty title="No admin actions yet" hint="Every approval, suspension and remittance change is recorded here." />}>
        {L.map((l) => <tr key={l.id}><td className="text-ink-500">{dt(l.created_at)}</td><td>{l.actor?.full_name ?? 'Unknown'}</td><td>{l.action}</td><td className="text-xs text-ink-500">{label(l.entity_type)} {String(l.entity_id).slice(0, 8)}</td></tr>)}
      </Table>
    </>
  );
}
