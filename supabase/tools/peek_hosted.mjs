// Ad-hoc read-only query against the hosted project.
//
//   node supabase/tools/peek_hosted.mjs "select 1"

import { sql } from './db_admin.mjs';

const query = process.argv[2];
if (!query) {
  console.error('usage: node peek_hosted.mjs "<select ...>"');
  process.exit(1);
}
const rows = await sql(query);
console.log(JSON.stringify(rows, null, 2));
