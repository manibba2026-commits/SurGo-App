/** Shared helpers for local tests. Not imported by the deployed function. */

export function base64Secret(): string {
  return btoa('surgo-send-sms-test-secret');
}

export function signWebhook(
  keyBase64: string,
  id: string,
  timestamp: string,
  body: string,
): Promise<string> {
  return (async () => {
    const keyBytes = Uint8Array.from(atob(keyBase64), (char) =>
      char.charCodeAt(0)
    );
    const key = await crypto.subtle.importKey(
      'raw',
      keyBytes,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const digest = new Uint8Array(
      await crypto.subtle.sign(
        'HMAC',
        key,
        new TextEncoder().encode(`${id}.${timestamp}.${body}`),
      ),
    );
    return `v1,${btoa(String.fromCharCode(...digest))}`;
  })();
}

export function webhookHeaders(
  signature: string,
  id = 'msg_test_1',
  timestamp = '1700000000',
): Headers {
  return new Headers({
    'webhook-id': id,
    'webhook-timestamp': timestamp,
    'webhook-signature': signature,
  });
}
