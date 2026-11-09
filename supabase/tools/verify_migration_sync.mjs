// Prove that the locally stored copy of a hosted-only migration still matches
// the SQL recorded in the hosted project's migration ledger, byte for byte.
//
//   node supabase/tools/verify_migration_sync.mjs
//
// Read-only: it selects from supabase_migrations.schema_migrations and never
// applies anything to the hosted database.
//
// The admin dashboard migration is applied on the host as version
// 20261106062246 but stored locally as 20261106091300, because at its original
// timestamp the enums and tables it references do not exist yet, so a fresh
// `supabase db reset` cannot replay it there. See supabase/README.md.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sql } from './db_admin.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SYNCED = [
  {
    remoteVersion: '20261106062246',
    localFile: '20261106091300_admin_dashboard_access_and_actions.sql',
  },
];

let failed = 0;

for (const { remoteVersion, localFile } of SYNCED) {
  const rows = await sql(
    `select statements from supabase_migrations.schema_migrations
      where version = '${remoteVersion}'`,
  );
  const row = Array.isArray(rows) ? rows[0] : rows;
  if (!row) {
    console.error(`FAIL  ${remoteVersion}: not in the hosted ledger`);
    failed += 1;
    continue;
  }
  if (row.statements.length !== 1) {
    console.error(
      `FAIL  ${remoteVersion}: hosted ledger holds ${row.statements.length} statements`,
    );
    failed += 1;
    continue;
  }
  const localPath = path.resolve(HERE, '..', 'migrations', localFile);
  const local = fs.readFileSync(localPath);
  const remote = Buffer.from(row.statements[0], 'utf8');
  if (local.equals(remote)) {
    console.log(`OK    ${localFile} matches hosted ${remoteVersion} (${remote.length} bytes)`);
  } else {
    console.error(
      `FAIL  ${localFile} differs from hosted ${remoteVersion}: ` +
        `local ${local.length} bytes vs remote ${remote.length} bytes`,
    );
    failed += 1;
  }
}

if (failed) {
  console.error(`\nMIGRATION SYNC FAILED: ${failed} mismatch(es)`);
  process.exitCode = 1;
} else {
  console.log('\nMIGRATION SYNC OK: local copies equal the hosted ledger');
}
