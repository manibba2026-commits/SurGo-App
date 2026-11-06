import { shortDay } from '@/lib/format';

export type DayPoint = { day: string; [k: string]: number | string };
const W = 640, H = 200, PAD = { l: 36, r: 8, t: 8, b: 24 };
const niceMax = (m: number) => (m <= 4 ? 4 : Math.ceil(m / 4) * 4);

/** Stacked daily bars (server-rendered SVG, no client JS). */
export function StackedBars({ data, series }: { data: DayPoint[]; series: { key: string; name: string; color: string }[] }) {
  const totals = data.map((d) => series.reduce((a, s) => a + Number(d[s.key] ?? 0), 0));
  const max = niceMax(Math.max(0, ...totals));
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b, bw = iw / Math.max(data.length, 1);
  return (
    <figure>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Daily activity" className="w-full">
        {[0, 1, 2, 3, 4].map((i) => {
          const y = PAD.t + ih - (ih * i) / 4;
          return <g key={i}><line x1={PAD.l} x2={W - PAD.r} y1={y} y2={y} stroke="#E1E5E0" /><text x={PAD.l - 6} y={y + 3} textAnchor="end" fontSize="10" fill="#8FA1AF">{(max * i) / 4}</text></g>;
        })}
        {data.map((d, i) => {
          let y = PAD.t + ih;
          return (
            <g key={d.day}>
              {series.map((s) => {
                const h = (Number(d[s.key] ?? 0) / max) * ih; y -= h;
                return h > 0 ? <rect key={s.key} x={PAD.l + i * bw + bw * 0.18} y={y} width={bw * 0.64} height={h} fill={s.color} rx="1.5"><title>{`${shortDay(String(d.day))} · ${s.name}: ${d[s.key]}`}</title></rect> : null;
              })}
              {(i % Math.ceil(data.length / 7) === 0) && <text x={PAD.l + i * bw + bw / 2} y={H - 8} textAnchor="middle" fontSize="10" fill="#8FA1AF">{shortDay(String(d.day))}</text>}
            </g>
          );
        })}
      </svg>
      <figcaption className="mt-1 flex flex-wrap gap-4 text-xs text-ink-500">
        {series.map((s) => <span key={s.name} className="inline-flex items-center gap-1.5"><i className="inline-block h-2.5 w-2.5 rounded-sm" style={{ background: s.color }} />{s.name}</span>)}
      </figcaption>
    </figure>
  );
}

/** Single-series line (used for revenue and sign-ups). `fmt` formats the axis/tooltip. */
export function LineTrend({ data, k, color = '#0E7C86', fmt = (n: number) => String(n) }: { data: DayPoint[]; k: string; color?: string; fmt?: (n: number) => string }) {
  const vals = data.map((d) => Number(d[k] ?? 0));
  const max = Math.max(1, ...vals);
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const x = (i: number) => PAD.l + (data.length <= 1 ? iw / 2 : (iw * i) / (data.length - 1));
  const y = (v: number) => PAD.t + ih - (v / max) * ih;
  const path = vals.map((v, i) => `${i ? 'L' : 'M'}${x(i)},${y(v)}`).join(' ');
  return (
    <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${k} trend`} className="w-full">
      {[0, 0.5, 1].map((f) => <g key={f}><line x1={PAD.l} x2={W - PAD.r} y1={y(max * f)} y2={y(max * f)} stroke="#E1E5E0" /><text x={PAD.l - 6} y={y(max * f) + 3} textAnchor="end" fontSize="10" fill="#8FA1AF">{fmt(max * f)}</text></g>)}
      <path d={`${path} L${x(vals.length - 1)},${y(0)} L${x(0)},${y(0)} Z`} fill={color} opacity="0.08" />
      <path d={path} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" />
      {vals.map((v, i) => <circle key={i} cx={x(i)} cy={y(v)} r="2.5" fill={color}><title>{`${shortDay(String(data[i].day))}: ${fmt(v)}`}</title></circle>)}
      {data.map((d, i) => (i % Math.ceil(data.length / 7) === 0) && <text key={d.day} x={x(i)} y={H - 8} textAnchor="middle" fontSize="10" fill="#8FA1AF">{shortDay(String(d.day))}</text>)}
    </svg>
  );
}

export function HBars({ items, color = '#0E7C86' }: { items: { name: string; value: number; display?: string }[]; color?: string }) {
  const max = Math.max(1, ...items.map((i) => i.value));
  return (
    <ul className="space-y-2.5">
      {items.map((i) => (
        <li key={i.name} className="text-sm">
          <div className="mb-1 flex justify-between"><span className="text-ink">{i.name}</span><span className="tabular-nums text-ink-500">{i.display ?? i.value}</span></div>
          <div className="h-2 rounded-full bg-paper"><div className="h-2 rounded-full" style={{ width: `${(i.value / max) * 100}%`, background: color }} /></div>
        </li>
      ))}
    </ul>
  );
}

/** The fee-ledger strip: where platform fees stand, kept visually separate from cash received. */
export function FeeStrip({ remitted, outstanding, overdue }: { remitted: number; outstanding: number; overdue: number }) {
  const pendingOnly = Math.max(0, outstanding - overdue);
  const total = remitted + outstanding;
  const seg = [
    { name: 'Remitted to SurGo', v: remitted, c: '#2F7D4F' },
    { name: 'Owed, not yet due', v: pendingOnly, c: '#B7791F' },
    { name: 'Overdue', v: overdue, c: '#C2402B' },
  ];
  return (
    <div>
      <div className="flex h-3 overflow-hidden rounded-full bg-paper" role="img" aria-label="Platform fee remittance status">
        {total > 0 && seg.map((s) => <div key={s.name} style={{ width: `${(s.v / total) * 100}%`, background: s.c }} />)}
      </div>
      {total === 0 && <p className="mt-2 text-xs text-ink-500">No platform fees have been recorded yet.</p>}
    </div>
  );
}
