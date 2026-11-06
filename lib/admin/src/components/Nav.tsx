'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

const GROUPS: { title: string; items: [string, string][] }[] = [
  { title: 'Operations', items: [['Overview', '/dashboard'], ['Rides', '/rides'], ['Rentals', '/rentals'], ['Pasuyo', '/pasuyo']] },
  { title: 'People', items: [['Users', '/users'], ['Riders & owners', '/providers'], ['Vehicles', '/vehicles'], ['Verification', '/verification']] },
  { title: 'Money & insight', items: [['Finance', '/finance'], ['Reports', '/reports'], ['Settings', '/settings']] },
];

export function Nav() {
  const path = usePathname();
  return (
    <nav aria-label="Primary" className="space-y-5">
      {GROUPS.map((g) => (
        <div key={g.title}>
          <div className="px-3 pb-1 text-xs text-ink-300">{g.title}</div>
          <ul className="flex flex-wrap gap-1 lg:block">
            {g.items.map(([name, href]) => {
              const on = path === href || path.startsWith(href + '/');
              return (
                <li key={href}>
                  <Link href={href} aria-current={on ? 'page' : undefined}
                    className={`block rounded-md px-3 py-1.5 text-sm ${on ? 'bg-sea text-white' : 'text-white/80 hover:bg-white/10'}`}>{name}</Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}
