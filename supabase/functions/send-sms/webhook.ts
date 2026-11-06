/**
 * Supabase Auth hooks are signed with the Standard Webhooks scheme.
 *
 * The signature is `v1,<base64 HMAC-SHA256>` over
 * `${webhook-id}.${webhook-timestamp}.${rawBody}`. The dashboard secret is
 * shown as `v1,whsec_<base64 key>`.
 */

const DEFAULT_TOLERANCE_SECONDS = 300;

export type WebhookVerification =
  | { ok: true }
  | {
      ok: false;
      reason:
        | 'missing_headers'
        | 'invalid_timestamp'
        | 'expired_timestamp'
        | 'invalid_secret'
        | 'invalid_signature';
    };

export interface VerifyOptions {
  /** Dashboard hook secret, with or without the `v1,whsec_` prefix. */
  secret: string;
  /** Maximum allowed clock skew in seconds. Defaults to 5 minutes. */
  toleranceSeconds?: number;
  /** Overridable clock, in seconds, for tests. */
  nowSeconds?: number;
}

function decodeBase64(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(new ArrayBuffer(binary.length));
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch {
    return null;
  }
}

function encodeBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

export function normalizeHookSecret(secret: string): string {
  let value = secret.trim();
  if (value.startsWith('v1,')) value = value.slice(3);
  if (value.startsWith('whsec_')) value = value.slice(6);
  return value;
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}

function providedV1Signatures(header: string): string[] {
  const signatures: string[] = [];
  for (const candidate of header.split(' ')) {
    const comma = candidate.indexOf(',');
    if (comma === -1) continue;
    if (candidate.slice(0, comma) !== 'v1') continue;
    const signature = candidate.slice(comma + 1).trim();
    if (signature) signatures.push(signature);
  }
  return signatures;
}

export async function verifyStandardWebhook(
  rawBody: string,
  headers: Headers,
  options: VerifyOptions,
): Promise<WebhookVerification> {
  const id = headers.get('webhook-id');
  const timestamp = headers.get('webhook-timestamp');
  const signatureHeader = headers.get('webhook-signature');
  if (!id || !timestamp || !signatureHeader) {
    return { ok: false, reason: 'missing_headers' };
  }

  if (!/^\d+$/.test(timestamp)) {
    return { ok: false, reason: 'invalid_timestamp' };
  }

  const timestampSeconds = Number.parseInt(timestamp, 10);
  const nowSeconds = options.nowSeconds ?? Math.floor(Date.now() / 1000);
  const tolerance = options.toleranceSeconds ?? DEFAULT_TOLERANCE_SECONDS;
  if (Math.abs(nowSeconds - timestampSeconds) > tolerance) {
    return { ok: false, reason: 'expired_timestamp' };
  }

  const keyBytes = decodeBase64(normalizeHookSecret(options.secret));
  if (!keyBytes || keyBytes.length === 0) {
    return { ok: false, reason: 'invalid_secret' };
  }

  const key = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signedContent = `${id}.${timestamp}.${rawBody}`;
  const digest = new Uint8Array(
    await crypto.subtle.sign(
      'HMAC',
      key,
      new TextEncoder().encode(signedContent),
    ),
  );
  const expected = encodeBase64(digest);

  const matches = providedV1Signatures(signatureHeader).some((signature) =>
    constantTimeEqual(signature, expected)
  );
  return matches ? { ok: true } : { ok: false, reason: 'invalid_signature' };
}
