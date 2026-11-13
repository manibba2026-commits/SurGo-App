// Applies local provider secrets to the hosted Edge Functions.
//
// Values are read from a file outside the repository, kept in memory, and sent
// only to the Supabase Management API. Nothing is printed except secret names
// and HTTP status. The Management API token comes from the Windows Credential
// Manager entry the Supabase CLI already stores (see db_admin.mjs).
//
// Usage:
//   node supabase/tools/apply_provider_secrets.mjs [path-to-providers.env]

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { api, REF } from './db_admin.mjs';

const DEFAULT_FILE = path.join(os.homedir(), '.surgo-secrets', 'providers.env');

// Names the functions actually read. Anything else is rejected so a typo is
// caught before it silently becomes an unused secret.
const FUNCTION_SECRETS = new Set([
  'GEOAPIFY_API_KEY',
  'SMS_PROVIDER',
  'UNISMS_API_KEY',
  'UNISMS_SENDER_ID',
]);

// Local-only helpers that must never be uploaded.
const LOCAL_ONLY = new Set(['SURGO_TEST_PHONE']);

function parse(file) {
  if (!fs.existsSync(file)) {
    throw new Error(`secret file not found: ${file}`);
  }
  const values = new Map();
  const unknown = [];
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  lines.forEach((raw, index) => {
    const line = raw.trim();
    if (!line || line.startsWith('#')) return;
    const eq = line.indexOf('=');
    if (eq <= 0) {
      throw new Error(`line ${index + 1} is not KEY=VALUE`);
    }
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      // A trailing "# note" is a comment, not part of the secret. Values that
      // legitimately contain '#' are quoted and keep it.
      const comment = value.search(/\s#/);
      if (comment >= 0) value = value.slice(0, comment).trim();
    }
    if (LOCAL_ONLY.has(key)) return;
    if (!FUNCTION_SECRETS.has(key)) {
      unknown.push(key);
      return;
    }
    if (value) values.set(key, value);
  });
  if (unknown.length) {
    throw new Error(`unknown secret name(s): ${unknown.join(', ')}`);
  }
  return values;
}

function validate(values) {
  const provider = values.get('SMS_PROVIDER');
  if (provider !== undefined && provider !== 'unisms' && provider !== 'semaphore') {
    throw new Error('SMS_PROVIDER must be unisms or semaphore');
  }
  if (provider !== 'unisms') return;
  if (!values.has('UNISMS_API_KEY')) {
    throw new Error('SMS_PROVIDER=unisms requires UNISMS_API_KEY');
  }
}

const file = process.argv[2] ?? DEFAULT_FILE;
const values = parse(file);
validate(values);

if (values.size === 0) {
  console.log('No filled secrets found; nothing to apply.');
  process.exit(0);
}

const payload = [...values].map(([name, value]) => ({ name, value }));
const result = await api(`/v1/projects/${REF}/secrets`, {
  method: 'POST',
  body: JSON.stringify(payload),
});

console.log(`Applied ${payload.length} secret(s): ${[...values.keys()].join(', ')}`);
console.log(
  Array.isArray(result)
    ? `Project ${REF}: ${result.length} secret(s) acknowledged.`
    : `Project ${REF}: accepted.`,
);
