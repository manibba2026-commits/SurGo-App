// Read-only check that the admin dashboard's verification reads still match the
// hosted database.
//
//   node supabase/tools/verify_admin_reads.mjs
//
// The dashboard reads verification data through three channels, and each one
// fails differently, so they are checked separately:
//   1. PostgREST embeds (`profile:profiles!..._fkey(...)`) only resolve if the
//      named foreign-key constraint still links those two tables.
//   2. Every column named in a select string has to exist on its table.
//   3. The document panel's file listing depends on the admin SELECT policy on
//      storage.objects — without it an administrator cannot list another
//      person's folder and every file would read as missing.
// Then every table the dashboard reads is checked for the access the signed-in
// `authenticated` role actually has: a table privilege, RLS on, and at least one
// SELECT policy that an administrator satisfies for someone else's rows. A read
// that passes 1 and 2 but fails here returns an error (no privilege) or an empty
// list (no policy), which is how a dashboard page can look correct in code and
// show nothing in the browser.
//
// Nothing here writes, and no rows are read.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sql } from './db_admin.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ADMIN_SRC = path.resolve(HERE, '..', '..', 'lib', 'admin', 'src');

/** Every page/lib file that issues a PostgREST read. */
function sourceFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...sourceFiles(full));
    else if (/\.(ts|tsx)$/.test(entry.name) && !entry.name.endsWith('.test.mts')) out.push(full);
  }
  return out;
}

const SOURCES = sourceFiles(ADMIN_SRC);

const checks = [];
function check(name, pass, detail) {
  checks.push({ name, ok: pass });
  console.log(`${pass ? 'OK  ' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}

/** `.from('table') ... .select('...')` pairs, tolerant of line breaks. */
function queries() {
  const out = [];
  for (const file of SOURCES) {
    const source = fs.readFileSync(file, 'utf8');
    const consts = new Map(
      [...source.matchAll(/(?:const|let)\s+([A-Z_]{3,})\s*=\s*'([^']+)'/g)].map((m) => [m[1], m[2]]),
    );
    for (const match of source.matchAll(
      /\.from\('([a-z_]+)'\)(?:[\s\S]{0,160}?)\s*\.select\(\s*\n?\s*(?:'([^']+)'|([A-Z_]{3,}))/g,
    )) {
      const select = match[2] ?? consts.get(match[3]);
      if (!select) throw new Error(`${path.basename(file)}: unresolved select ${match[3]}`);
      out.push({ file: path.basename(file), table: match[1], select });
    }
  }
  const unique = new Map();
  for (const q of out) unique.set(`${q.file}|${q.table}|${q.select}`, q);
  return [...unique.values()];
}

/** Split a select string on top-level commas only. */
function items(select) {
  const out = [];
  let depth = 0;
  let current = '';
  for (const ch of select) {
    if (ch === '(') depth += 1;
    if (ch === ')') depth -= 1;
    if (ch === ',' && depth === 0) {
      out.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim()) out.push(current.trim());
  return out;
}

/** `table`, `alias:table!fkey`, or `alias:table!inner` — the alias and the
 *  `!inner` / `!left` join modifier are both optional. */
const EMBED = /^(?:([a-z_]+):)?([a-z_]+)(?:!([a-z_]+))?\((.*)\)$/;
const JOIN_MODIFIERS = new Set(['inner', 'left']);

const columns = await sql(`
  select table_name, column_name from information_schema.columns
   where table_schema = 'public';
`);
const byTable = new Map();
for (const row of Array.isArray(columns) ? columns : [columns]) {
  if (!byTable.has(row.table_name)) byTable.set(row.table_name, new Set());
  byTable.get(row.table_name).add(row.column_name);
}
const hasColumn = (table, column) => byTable.has(table) && byTable.get(table).has(column);

const fks = await sql(`
  select tc.conname, ncl.relname as child, npr.relname as parent
    from pg_constraint tc
    join pg_class ncl on ncl.oid = tc.conrelid
    join pg_class npr on npr.oid = tc.confrelid
    join pg_namespace n on n.oid = ncl.relnamespace
   where n.nspname = 'public' and tc.contype = 'f';
`);
const fkRows = Array.isArray(fks) ? fks : [fks];
const fkByName = new Map(fkRows.map((row) => [row.conname, row]));

console.log(`Validating ${queries().length} dashboard select strings against the hosted schema:\n`);

/** Walks a select list, including embeds nested inside embeds. */
function checkFields(table, select, problems) {
  for (const item of items(select)) {
    if (item === '*') continue;
    const embed = item.match(EMBED);
    if (!embed) {
      if (!byTable.has(table)) problems.push(`unknown table ${table}`);
      else if (!hasColumn(table, item)) problems.push(`${table}.${item}`);
      continue;
    }
    const [, alias, parent, rawHint, inner] = embed;
    const name = alias ? `${alias}:${parent}` : parent;
    const hint = rawHint && !JOIN_MODIFIERS.has(rawHint) ? rawHint : null;
    if (!byTable.has(parent)) {
      problems.push(`embed ${name}: unknown table ${parent}`);
      continue;
    }
    checkFields(parent, inner, problems);
    // An embed can point either way: many-to-one (child row -> parent table) or
    // one-to-many (parent row -> child table), so accept a constraint in either
    // direction between the two tables.
    const connects = (row) =>
      (row.child === table && row.parent === parent) ||
      (row.child === parent && row.parent === table);
    if (hint) {
      const found = fkByName.get(hint);
      if (!found) problems.push(`fk hint ${hint} does not exist`);
      else if (!connects(found)) {
        problems.push(`fk hint ${hint} links ${found.child}->${found.parent}, not ${table}<->${parent}`);
      }
    } else {
      const candidates = fkRows.filter(connects);
      if (candidates.length !== 1) {
        problems.push(`embed ${name} needs a hint (${candidates.length} foreign keys)`);
      }
    }
  }
}

for (const { file, table, select } of queries()) {
  const problems = [];
  checkFields(table, select, problems);
  check(
    `${file} from('${table}')`,
    problems.length === 0,
    problems.length ? problems.join(', ') : `${items(select).length} fields resolve`,
  );
}

console.log('');
const tables = [...new Set(queries().map((q) => q.table))].sort();
const access = await sql(`
  select c.relname as table_name,
         c.relrowsecurity as rls,
         has_table_privilege('authenticated', ('public.'||c.relname)::regclass, 'select') as auth_select,
         coalesce(q.select_quals, '{}'::text[]) as select_quals
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
    left join (
      select tablename, array_agg(qual) as select_quals
        from pg_policies
       where schemaname = 'public' and cmd = 'SELECT' and 'authenticated' = any (roles)
       group by tablename
    ) q on q.tablename = c.relname
   where c.relkind = 'r'
     and c.relname = any (array[${tables.map((t) => `'${t}'`).join(',')}])
   order by c.relname;
`);
const accessRows = Array.isArray(access) ? access : [access];
const found = new Map(accessRows.map((r) => [r.table_name, r]));
// The audit trail is the one table the host keeps off the signed-in role on
// purpose: a policy exists, the privilege does not, and the dashboard renders
// that section as unavailable instead of pretending it read something.
const PRIVILEGE_WITHHELD = ['admin_audit_logs'];

for (const table of tables) {
  const row = found.get(table);
  if (!row) {
    check(`access: ${table}`, false, 'not in the hosted catalog');
    continue;
  }
  const quals = (row.select_quals ?? []).filter(Boolean);
  const adminSeesOthers =
    quals.some((q) => /is_admin\(\)|has_approved_role\('admin'/.test(q)) || quals.some((q) => q.trim() === 'true');
  const problems = [];
  if (!row.rls) problems.push('RLS is disabled on this table');
  if (!row.auth_select && !PRIVILEGE_WITHHELD.includes(table)) problems.push('no SELECT privilege');
  if (row.auth_select && quals.length === 0) problems.push('RLS enabled with no SELECT policy');
  if (row.auth_select && quals.length > 0 && !adminSeesOthers)
    problems.push('no policy lets an admin read another person rows');
  check(
    `access: ${table}`,
    problems.length === 0,
    problems.length
      ? problems.join(', ')
      : `${quals.length} SELECT polic${quals.length === 1 ? 'y' : 'ies'}${
          PRIVILEGE_WITHHELD.includes(table) ? ', privilege withheld by design' : ', admin-readable'
        }`,
  );
}

console.log('');
const policy = await sql(`
  select polname from pg_policy
   where polrelid = 'storage.objects'::regclass
     and polname = 'surgo admin read documents';
`);
check(
  'storage policy "surgo admin read documents"',
  (Array.isArray(policy) ? policy : [policy]).length === 1,
);

const buckets = await sql(`
  select id from storage.buckets
   where id in ('verification-documents', 'vehicle-documents');
`);
const bucketRows = Array.isArray(buckets) ? buckets : [buckets];
check('document buckets exist', bucketRows.length === 2, `${bucketRows.length} of 2`);

const failed = checks.filter((c) => !c.ok).length;
console.log(
  failed
    ? `\nADMIN READS FAILED: ${failed} of ${checks.length} checks`
    : `\nADMIN READS OK: ${checks.length} checks against the hosted database`,
);
if (failed) process.exitCode = 1;
