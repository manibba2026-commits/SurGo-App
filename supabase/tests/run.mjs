// Docker-free migration verifier for the SurGo Supabase schema.
//
// `supabase start` / `supabase test db` need Docker. This harness runs the
// exact migration and seed files against PGlite (Postgres compiled to WASM)
// with small Supabase stubs for auth.users, auth.uid(), storage and roles.
//
// It boots two independent databases: one "fresh" and one "reset" run, so a
// migration is proven to apply from an empty database more than once.
//
//   cd supabase/tests
//   npm install
//   npm test

import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const supabaseDir = path.resolve(here, '..');
const migrationsDir = path.join(supabaseDir, 'migrations');
const sqlTestsDir = path.join(here, 'sql');

const BOOTSTRAP = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;

  create schema auth;
  create schema storage;

  create table auth.users (
    id uuid primary key default gen_random_uuid(),
    email text,
    phone text,
    raw_user_meta_data jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
  );

  create or replace function auth.uid()
  returns uuid
  language sql
  stable
  as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  $$;

  create publication supabase_realtime;

  create table storage.buckets (
    id text primary key,
    name text not null,
    public boolean not null default false,
    file_size_limit bigint,
    allowed_mime_types text[]
  );

  create table storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text not null references storage.buckets (id),
    name text not null,
    owner uuid
  );
  alter table storage.objects enable row level security;

  create or replace function storage.foldername(name text)
  returns text[]
  language sql
  immutable
  as $$
    select string_to_array(name, '/');
  $$;

  grant usage on schema auth, storage to anon, authenticated, service_role;
`;

const TEST_SUPPORT = `
  create or replace function public.test_assert(p_ok boolean, p_message text)
  returns void
  language plpgsql
  as $$
  begin
    if not p_ok then
      raise exception 'ASSERT FAILED: %', p_message;
    end if;
  end;
  $$;
`;

// Supabase applies default privileges that grant ALL on new public tables and
// EXECUTE on new public functions to anon, authenticated and service_role.
// The security hardening migration is written against that starting state, so
// simulate it immediately before that migration runs. Applying it earlier
// would also cover tables created by the baseline migrations.
const HARDENING_MARKER = 'security_hardening';

async function grantSupabaseDefaults(db) {
  await db.exec(`
    grant usage on schema public, storage to anon, authenticated, service_role;
    grant all on all tables in schema public to anon, authenticated, service_role;
    grant all on all sequences in schema public to anon, authenticated, service_role;
    grant execute on all functions in schema public
      to anon, authenticated, service_role;
    grant all on all tables in schema storage
      to anon, authenticated, service_role;
  `);
}

function readMigrations() {
  return fs
    .readdirSync(migrationsDir)
    .filter((file) => file.endsWith('.sql'))
    .sort()
    .map((file) => ({ file, sql: fs.readFileSync(path.join(migrationsDir, file), 'utf8') }));
}

function readSqlTests() {
  return fs
    .readdirSync(sqlTestsDir)
    .filter((file) => file.endsWith('.sql'))
    .sort()
    .map((file) => ({ file, sql: fs.readFileSync(path.join(sqlTestsDir, file), 'utf8') }));
}

async function boot(label) {
  const db = new PGlite();
  await db.waitReady;

  await db.exec(BOOTSTRAP);

  const migrations = readMigrations();
  let defaultsApplied = false;
  for (const { file, sql } of migrations) {
    if (!defaultsApplied && file.includes(HARDENING_MARKER)) {
      await grantSupabaseDefaults(db);
      defaultsApplied = true;
    }
    try {
      await db.exec(sql);
      console.log(`  OK migration  ${label}  ${file}`);
    } catch (error) {
      throw new Error(`[${label}] migration ${file} failed: ${error.message}`);
    }
  }
  if (!defaultsApplied) {
    await grantSupabaseDefaults(db);
  }

  const seed = fs.readFileSync(path.join(supabaseDir, 'seed.sql'), 'utf8');
  try {
    await db.exec(seed);
    console.log(`  OK seed       ${label}  seed.sql`);
  } catch (error) {
    throw new Error(`[${label}] seed.sql failed: ${error.message}`);
  }

  // Seeding again must not duplicate geography.
  await db.exec(seed);

  await db.exec(TEST_SUPPORT);

  await db.exec(`
    grant execute on function public.test_assert(boolean, text)
      to anon, authenticated, service_role;
  `);

  return { db, migrations };
}

async function runSqlTests(db, label) {
  const tests = readSqlTests();
  for (const { file, sql } of tests) {
    try {
      await db.exec(sql);
      console.log(`  OK test       ${label}  ${file}`);
    } catch (error) {
      throw new Error(`[${label}] SQL test ${file} failed: ${error.message}`);
    }
  }
  return tests.length;
}

async function main() {
  const startedAt = Date.now();
  console.log('Booting fresh database...');
  const fresh = await boot('fresh');

  console.log('\nRunning SQL tests on fresh database...');
  const testCount = await runSqlTests(fresh.db, 'fresh');

  console.log('\nBooting reset database (migrations + seed from empty)...');
  const reset = await boot('reset');
  console.log('\nRunning SQL tests on reset database...');
  await runSqlTests(reset.db, 'reset');

  await fresh.db.close();
  await reset.db.close();

  console.log(
    `\nPASS: ${fresh.migrations.length} migrations, ${testCount} SQL test files, fresh + reset (${Date.now() - startedAt} ms)`
  );
}

main().catch(async (error) => {
  console.error(`\nFAIL: ${error.message}`);
  process.exitCode = 1;
});
