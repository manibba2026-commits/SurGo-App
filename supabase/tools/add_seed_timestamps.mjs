// One-off seed edit: give the collections that only carry a display label a
// real ISO timestamp next to it, using the same 2026-11-06T12:00Z anchor as the
// demo-data import. Re-running is a no-op: a label line that is already
// followed by the ISO key is left alone.
//
//   node supabase/tools/add_seed_timestamps.mjs
//
// Text is edited line by line so the hand-formatted JSON layout stays intact.

import fs from 'node:fs';
import path from 'node:path';

const ANCHOR = Date.parse('2026-11-06T12:00:00.000Z');
const assetsDir = path.resolve(import.meta.dirname, '..', '..', 'assets', 'db');

const MONTHS = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

const iso = (ms) => new Date(ms).toISOString();

function relativeToIso(label) {
  const text = label.trim();
  if (/^just now$/i.test(text)) return iso(ANCHOR);
  if (/^yesterday$/i.test(text)) return iso(ANCHOR - 86_400_000);
  const match = /^(\d+)\s*(min|hr|hour|day|week)s?\s*ago$/i.exec(text);
  if (!match) return null;
  const step = {
    min: 60_000, hr: 3_600_000, hour: 3_600_000,
    day: 86_400_000, week: 7 * 86_400_000,
  }[match[2].toLowerCase()];
  return iso(ANCHOR - Number(match[1]) * step);
}

function dateLabelToIso(label) {
  const match = /^([A-Za-z]{3,})\s+(\d{1,2}),\s*(\d{4})$/.exec(label.trim());
  if (!match) return null;
  const month = MONTHS[match[1].slice(0, 3).toLowerCase()];
  if (!month) return null;
  return iso(Date.UTC(Number(match[3]), month - 1, Number(match[2])));
}

function addKey(file, labelKey, valueKey, convert) {
  const filePath = path.join(assetsDir, file);
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  const out = [];
  let added = 0;
  let kept = 0;
  let unmapped = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const match = new RegExp(`^"${labelKey}": "([^"]+)"(,?)$`).exec(line.trim());
    if (!match) {
      out.push(line);
      continue;
    }
    if ((lines[i + 1] ?? '').trim().startsWith(`"${valueKey}"`)) {
      kept++;
      out.push(line);
      continue;
    }
    const value = convert(match[1]);
    if (!value) {
      unmapped++;
      console.warn(`  ${file}: cannot map "${match[1]}"`);
      out.push(line);
      continue;
    }
    const indent = line.slice(0, line.length - line.trimStart().length);
    if (match[2] === ',') {
      out.push(line, `${indent}"${valueKey}": "${value}",`);
    } else {
      // The label is the last key in its object, so the comma moves onto it.
      out.push(`${line},`, `${indent}"${valueKey}": "${value}"`);
    }
    added++;
  }
  fs.writeFileSync(filePath, out.join('\n'));
  console.log(`  ${file}: +${added} ${valueKey}, ${kept} already present, ${unmapped} unmapped`);
}

console.log('Adding ISO timestamps next to display labels...');
addKey('users.json', 'time', 'createdAt', relativeToIso);
addKey('rides.json', 'requestedAt', 'requestedAtIso', relativeToIso);
addKey('vehicles.json', 'expiry', 'expiresAt', dateLabelToIso);
