import type { SupabaseClient } from '@supabase/supabase-js';
import { ok, type Row } from './query.ts';

export const VERIFICATION_BUCKET = 'verification-documents';
export const VEHICLE_BUCKET = 'vehicle-documents';

/** Document types offered when an administrator uploads on someone's behalf. */
export const VERIFICATION_DOCUMENT_TYPES: [string, string][] = [
  ['government_id', 'Government ID'],
  ['drivers_license', "Driver's license"],
  ['vehicle_registration', 'Vehicle registration'],
  ['nbi_clearance', 'NBI clearance'],
  ['police_clearance', 'Police clearance'],
  ['barangay_clearance', 'Barangay clearance'],
  ['other', 'Other document'],
];

export const VEHICLE_DOCUMENT_TYPES: [string, string][] = [
  ['franchise', 'Franchise'],
  ['official_receipt', 'Official receipt'],
  ['certificate_of_registration', 'Certificate of registration'],
  ['insurance', 'Insurance'],
  ['other', 'Other document'],
];

/** Signed URLs expire with the page, never with the file. */
const SIGN_TTL_SECONDS = 600;

/**
 * What the dashboard knows about one referenced document file.
 * `present` comes from the bucket listing, so a path that was never uploaded is
 * reported as missing instead of showing a preview link that would fail.
 */
export type FileState = { present: boolean; url: string | null };

/**
 * The honest file state for one document row. A link only appears when a signed
 * URL exists; a referenced path with no object behind it is named as missing;
 * and a lookup that failed is reported as unknown rather than as "no file",
 * because the file may be there.
 */
export function documentFileState(doc: Row, file?: FileState): { text: string; hint: string } | null {
  if (!doc.storage_path) return { text: 'No file uploaded', hint: 'This document was submitted without a file.' };
  if (file?.url) return null;
  if (file?.present === false)
    return {
      text: 'No file on record',
      hint: `The application references ${doc.storage_path}, but that file is not in the bucket.`,
    };
  return { text: 'Preview unavailable', hint: 'The file listing did not answer.' };
}

const dirOf = (path: string) => {
  const cut = path.lastIndexOf('/');
  return cut < 0 ? '' : path.slice(0, cut + 1);
};

/**
 * Lists the folders that hold the referenced paths, then signs only the files
 * that actually exist. Reads go through the signed-in admin's own session, so
 * the `surgo admin read documents` policy is what grants the listing.
 */
export async function fileStates(
  db: SupabaseClient,
  bucket: string,
  paths: (string | null | undefined)[],
): Promise<Map<string, FileState>> {
  const wanted = [...new Set(paths.filter((p): p is string => !!p))];
  const states = new Map<string, FileState>();
  if (!wanted.length) return states;

  const folders = [...new Set(wanted.map(dirOf))];
  const listed = await Promise.all(
    folders.map(async (folder) => {
      const { data, error } = await db.storage.from(bucket).list(folder, { limit: 1000 });
      if (error) throw new Error(`${bucket} ${folder || '/'}: ${error.message}`);
      return (data ?? []).map((f) => `${folder}${f.name}`);
    }),
  );
  const present = new Set(listed.flat());
  const presentPaths = wanted.filter((p) => present.has(p));
  wanted.forEach((p) => states.set(p, { present: present.has(p), url: null }));
  if (!presentPaths.length) return states;

  const { data, error } = await db.storage
    .from(bucket)
    .createSignedUrls(presentPaths, SIGN_TTL_SECONDS);
  if (error) throw new Error(`${bucket} signing: ${error.message}`);
  (data ?? []).forEach((row) => {
    if (row.path && row.signedUrl) {
      states.set(row.path, { present: true, url: row.signedUrl });
    }
  });
  return states;
}

const APPLICATION_SELECT =
  'id,profile_id,capability_type,status,submitted_at,reviewed_at,decided_at,rejection_reason,profile:profiles!verification_applications_profile_id_fkey(id,full_name,email,phone),documents:verification_documents(id,document_type,label,document_number,storage_path,expires_at,status,reviewed_at,rejection_reason)';

const REVIEWABLE = ['submitted', 'under_review', 'needs_resubmission'];
export const isReviewable = (status: string) => REVIEWABLE.includes(status);

/** The default queue: everything an admin can still act on. Resubmissions are
 *  waiting just as much as first submissions, so they belong in this view. */
export const OPEN_STATUSES = REVIEWABLE;
export const OPEN_FILTER_LABEL = 'Open (awaiting review or resubmission)';

/**
 * Why approval is unavailable, or null when every document is approved.
 * Mirrors the database gate in admin_review_verification(): a document that is
 * pending, rejected or expired blocks approval until it is approved.
 */
export function approvalBlockReason(documents: Row[]): string | null {
  if (!documents.length) return 'Approval is blocked: the application has no documents.';
  const count = (status: string) => documents.filter((x) => x.status === status).length;
  const pending = count('pending');
  const rejected = count('rejected');
  const expired = count('expired');
  if (!pending && !rejected && !expired) return null;
  const parts = [
    pending ? `${pending} pending` : null,
    rejected ? `${rejected} rejected` : null,
    expired ? `${expired} expired` : null,
  ].filter((x): x is string => x !== null);
  return `Approval is blocked until every document is approved (${parts.join(', ')}).`;
}

export const allDocsApproved = (documents: Row[]) =>
  documents.length > 0 && approvalBlockReason(documents) === null;

export type VerificationBundle = {
  applications: Row[];
  applicationFiles: Map<string, FileState>;
  vehicleDocuments: Row[];
  vehicleFiles: Map<string, FileState>;
};

/** Signs every referenced file in one pass so a page renders a single bundle. */
async function bundle(
  db: SupabaseClient,
  applications: Row[],
  vehicleDocuments: Row[],
): Promise<VerificationBundle> {
  const [applicationFiles, vehicleFiles] = await Promise.all([
    fileStates(
      db,
      VERIFICATION_BUCKET,
      applications.flatMap((a) => a.documents.map((x: Row) => x.storage_path)),
    ),
    fileStates(
      db,
      VEHICLE_BUCKET,
      vehicleDocuments.map((x) => x.storage_path),
    ),
  ]);
  return { applications, applicationFiles, vehicleDocuments, vehicleFiles };
}

/** The review queue: every application in one status view, oldest first. */
export async function verificationQueue(
  db: SupabaseClient,
  filter: string,
  limit = 50,
): Promise<VerificationBundle> {
  let query = db
    .from('verification_applications')
    .select(APPLICATION_SELECT)
    .order('submitted_at', { ascending: true, nullsFirst: false })
    .limit(limit);
  query =
    filter === 'open'
      ? query.in('status', OPEN_STATUSES)
      : filter === 'all'
        ? query
        : query.eq('status', filter);
  const applications = ok((await query) as any, 'Applications') as Row[];
  const vehicleDocuments = ok(
    (await db
      .from('vehicle_documents')
      .select(
        'id,document_type,document_number,storage_path,expires_at,status,rejection_reason,vehicle:vehicles(name,plate_number,owner_profile_id,owner:profiles!vehicles_owner_profile_id_fkey(full_name))',
      )
      .eq('status', 'pending')
      .order('created_at')
      .limit(limit)) as any,
    'Vehicle documents',
  ) as Row[];
  return bundle(db, applications, vehicleDocuments);
}

/** Everything one person has ever submitted, plus the files on their vehicles. */
export async function verificationForProfile(
  db: SupabaseClient,
  profileId: string,
): Promise<VerificationBundle> {
  const applications = ok(
    (await db
      .from('verification_applications')
      .select(APPLICATION_SELECT)
      .eq('profile_id', profileId)
      .order('submitted_at', { ascending: false, nullsFirst: false })) as any,
    'Applications',
  ) as Row[];

  // Documents belong to vehicles, so reach them through the person's own list.
  const vehicleIds = ok(
    (await db.from('vehicles').select('id').eq('owner_profile_id', profileId)) as any,
    'Vehicles',
  ) as Row[];
  const vehicleDocuments = vehicleIds.length
    ? (ok(
        (await db
          .from('vehicle_documents')
          .select(
            'id,document_type,document_number,storage_path,expires_at,status,rejection_reason,vehicle:vehicles!vehicle_documents_vehicle_id_fkey(id,name,plate_number,owner_profile_id)',
          )
          .in('vehicle_id', vehicleIds.map((v: Row) => v.id))
          .order('created_at')) as any,
        'Vehicle documents',
      ) as Row[])
    : [];

  return bundle(db, applications, vehicleDocuments);
}
