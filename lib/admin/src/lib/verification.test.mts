import test from 'node:test';
import assert from 'node:assert/strict';
import type { SupabaseClient } from '@supabase/supabase-js';
import { allDocsApproved, documentFileState, fileStates, isReviewable, verificationForProfile } from './verification.ts';

/**
 * Storage-shaped stub: `files` lists the object paths that actually exist in
 * each bucket. Only the two storage calls the panel really makes are stubbed,
 * so a change in how files are looked out for shows up here.
 */
function stubStorage(files: Record<string, string[]>, calls: string[] = [], listError?: string) {
  return {
    calls,
    client: {
      storage: {
        from(bucket: string) {
          return {
            list: async (folder: string) => {
              calls.push(`list:${bucket}:${folder}`);
              if (listError) return { data: null, error: { message: listError } };
              const existing = (files[bucket] ?? []).filter((p) => p.startsWith(folder));
              return { data: existing.map((p) => ({ name: p.slice(folder.length) })), error: null };
            },
            createSignedUrls: async (paths: string[]) => {
              calls.push(`sign:${bucket}:${paths.join('|')}`);
              return {
                data: paths.map((p) => ({ path: p, signedUrl: `https://stub.invalid/${encodeURIComponent(p)}` })),
                error: null,
              };
            },
          };
        },
      },
    } as unknown as SupabaseClient,
  };
}

test('a referenced file that is not in the bucket is reported missing and never signed', async () => {
  const stub = stubStorage(
    { 'verification-documents': ['u1/dl.pdf'] },
  );
  const states = await fileStates(stub.client, 'verification-documents', [
    'u1/dl.pdf',
    'u1/gone.pdf',
    null,
  ]);

  assert.equal(states.get('u1/dl.pdf')?.present, true);
  assert.match(states.get('u1/dl.pdf')?.url ?? '', /dl\.pdf/);
  assert.equal(states.get('u1/gone.pdf')?.present, false);
  assert.equal(states.get('u1/gone.pdf')?.url, null);
  assert.equal(states.has(''), false);
  assert.deepEqual(
    stub.calls.filter((c) => c.startsWith('sign:')),
    ['sign:verification-documents:u1/dl.pdf'],
    'only files that exist may be signed',
  );
});

test('documents without a referenced path cost no storage request', async () => {
  const stub = stubStorage({ 'vehicle-documents': [] });
  const states = await fileStates(stub.client, 'vehicle-documents', [null, undefined]);
  assert.equal(states.size, 0);
  assert.equal(stub.calls.length, 0);
});

test('each folder is listed once, however many files it holds', async () => {
  const stub = stubStorage({ 'vehicle-documents': ['u1/a.pdf', 'u1/b.pdf', 'u2/c.pdf'] });
  const states = await fileStates(stub.client, 'vehicle-documents', [
    'u1/a.pdf',
    'u1/b.pdf',
    'u2/c.pdf',
  ]);
  assert.deepEqual(
    stub.calls.filter((c) => c.startsWith('list:')),
    ['list:vehicle-documents:u1/', 'list:vehicle-documents:u2/'],
  );
  assert.equal([...states.values()].every((s) => s.present && s.url), true);
});

test('a failed listing is an error, not a silent "no file on record"', async () => {
  const stub = stubStorage({ 'verification-documents': [] }, [], 'bucket unavailable');
  await assert.rejects(
    () => fileStates(stub.client, 'verification-documents', ['u1/dl.pdf']),
    /verification-documents u1\/: bucket unavailable/,
  );
});

/** Row-returning stub of the PostgREST query builder used by the panel. */
function stubTable(rows: Record<string, unknown>[]) {
  return {
    from(_table: string) {
      let out = rows;
      const builder: Record<string, unknown> = {};
      builder.select = () => builder;
      builder.order = () => builder;
      builder.limit = () => builder;
      builder.eq = (column: string, value: unknown) => {
        out = out.filter((r) => r[column] === value);
        return builder;
      };
      builder.in = (column: string, values: unknown[]) => {
        out = out.filter((r) => values.includes(r[column]));
        return builder;
      };
      builder.then = (resolve: (v: unknown) => unknown) =>
        resolve({ data: out, error: null });
      return builder;
    },
  };
}

test('the per-person bundle keeps every application and only their vehicle files', async () => {
  const rows = [
    { profile_id: 'u1', id: 'app-1', documents: [{ storage_path: 'u1/dl.pdf' }] },
    { profile_id: 'u1', id: 'app-2', documents: [{ storage_path: 'u1/gone.pdf' }] },
    { profile_id: 'u2', id: 'app-3', documents: [] },
    { id: 'veh-1', owner_profile_id: 'u1' },
    { id: 'veh-2', owner_profile_id: 'u2' },
    { id: 'doc-1', vehicle_id: 'veh-1', storage_path: 'u1/franchise.pdf' },
    { id: 'doc-2', vehicle_id: 'veh-2', storage_path: 'u2/other.pdf' },
  ];
  const stub = stubStorage({
    'verification-documents': ['u1/dl.pdf'],
    'vehicle-documents': ['u1/franchise.pdf'],
  });
  const db = { ...stubTable(rows), storage: stub.client.storage } as unknown as SupabaseClient;

  const bundle = await verificationForProfile(db, 'u1');

  assert.deepEqual(bundle.applications.map((a) => a.id), ['app-1', 'app-2']);
  assert.deepEqual(bundle.vehicleDocuments.map((d) => d.id), ['doc-1']);
  assert.equal(bundle.applicationFiles.get('u1/dl.pdf')?.present, true);
  assert.equal(bundle.applicationFiles.get('u1/gone.pdf')?.present, false);
  assert.equal(bundle.vehicleFiles.get('u1/franchise.pdf')?.url !== null, true);
  assert.equal(bundle.vehicleFiles.has('u2/other.pdf'), false);
});

test('reviewability follows the RPC rules', () => {
  assert.equal(isReviewable('submitted'), true);
  assert.equal(isReviewable('needs_resubmission'), true);
  assert.equal(isReviewable('approved'), false);
  assert.equal(isReviewable('draft'), false);
  assert.equal(allDocsApproved([{ status: 'approved' }]), true);
  assert.equal(allDocsApproved([{ status: 'approved' }, { status: 'pending' }]), false);
  assert.equal(allDocsApproved([]), false, 'an empty file set is not an approved set');
});

test('the four file states a document row can be in', () => {
  assert.equal(documentFileState({ storage_path: null }, undefined)?.text, 'No file uploaded');
  assert.equal(documentFileState({ storage_path: 'u1/dl.pdf' }, { present: true, url: 'https://x/1' }), null);
  assert.equal(documentFileState({ storage_path: 'u1/gone.pdf' }, { present: false, url: null })?.text, 'No file on record');
  assert.equal(documentFileState({ storage_path: 'u1/gone.pdf' }, undefined)?.text, 'Preview unavailable');
  assert.match(
    documentFileState({ storage_path: 'u1/gone.pdf' }, { present: false, url: null })?.hint ?? '',
    /u1\/gone\.pdf/,
    'the missing path is quoted so the admin can see what the record points at',
  );
});
