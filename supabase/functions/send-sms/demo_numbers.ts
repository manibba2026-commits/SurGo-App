/**
 * Server-side denylist for the fictional demo identities.
 *
 * These numbers belong to the presentation accounts and must never receive a
 * real SMS OTP. Auth still calls the Send SMS hook for them, so the hook
 * refuses before Semaphore is contacted. Real-user numbers are untouched.
 *
 * Keep this list in sync with `DEMO_PHONES` in
 * `supabase/tools/demo_provision_plan.mjs`; `demo_numbers_test.ts` enforces it.
 */
export const DEMO_NUMBERS: readonly string[] = [
  '+639170000001',
  '+639170000002',
  '+639170000003',
  '+639170000004',
  '+639170000005',
  '+639170000006',
  '+639170000007',
  '+639170000008',
  '+639170000009',
  '+639170000010',
  '+639170000011',
  '+639170000012',
  '+639170000013',
  '+639170000014',
  '+639170000015',
  '+639170000016',
  '+639170000017',
  '+639170000018',
  '+639170000019',
];

const DENIED = new Set(DEMO_NUMBERS.map((number) => number.replace(/^\+/, '')));

/**
 * Matches either E.164 (`+639170000001`) or the hook's normalized Semaphore
 * form (`639170000001`). Normalization itself stays with the caller.
 */
export function isDemoNumber(normalized: string): boolean {
  return DENIED.has(normalized.trim().replace(/^\+/, ''));
}
