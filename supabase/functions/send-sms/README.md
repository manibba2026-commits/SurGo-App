# send-sms — Supabase Auth Send SMS hook → UniSMS or Semaphore

SurGo's phone sign-in uses Supabase Auth to generate, expire and verify the
OTP. This Edge Function only delivers that code through the provider selected
by `SMS_PROVIDER` when Supabase fires the **Send SMS** auth hook.

```
Flutter → supabase.auth.signInWithOtp()
        → Supabase Auth generates + stores the OTP
        → Send SMS hook (signed Standard Webhooks request)
        → this function verifies the signature, normalizes the phone
        → UniSMS POST /api/sms (+ delivery status read)
          or Semaphore POST /api/v4/messages
```

No OTP is generated here, stored in a table, or verified here. Semaphore's own
OTP endpoint is deliberately not used.

## What is in this folder

| File | Purpose |
| --- | --- |
| `index.ts` | Edge Function entry point, reads secrets from the environment |
| `handler.ts` | Request handling and Auth-compatible error responses |
| `webhook.ts` | Standard Webhooks HMAC verification |
| `payload.ts` | Extracts `sms.phone` (falling back to `user.phone`) and `sms.otp` |
| `phone.ts` | PH mobile normalization (`63XXXXXXXXXX`) and OTP shape check |
| `message.ts` | The exact SMS body |
| `unisms.ts` | UniSMS client with async delivery-status verification |
| `semaphore.ts` | Semaphore v4 client with timeout and failure handling |
| `*_test.ts` | Local tests (Node 24 and Deno 2, built-in Web Crypto) |

## Semaphore contract

`POST https://api.semaphore.co/api/v4/messages` is form-encoded and receives
`apikey`, `number`, `message` and optional `sendername`. Semaphore returns a
JSON array with one object per recipient (`message_id`, `recipient`, `status`,
...). The documented synchronous statuses are `Queued`, `Pending`, `Sent`,
`Failed` and `Refunded`; this function accepts the first three and treats
`Failed`, `Refunded`, missing `message_id`, and unknown statuses as delivery
failures. The documented rate limit is 120 requests/minute. Semaphore silently
ignores messages beginning with the word `TEST`; the SurGo message does not.

The function does not use Semaphore's `/api/v4/otp` endpoint, so Semaphore
never generates or validates a code.

## UniSMS contract

`POST https://unismsapi.com/api/sms` is JSON with HTTP Basic auth (API key as
the username, empty password) and the body
`{ "recipient": "+639…", "content": "…", "sender_id": "Unisoft" }`. UniSMS
returns `201` with `message.status: "pending"` and settles the message
asynchronously, so the client then reads `GET /api/sms/:reference_id` and
reports an asynchronous `failed` status or non-empty `fail_reason` as a
rejection.

UniSMS enforces the Philippine OTP content format. The body must include the
brand, the code, the purpose and the expiry, exactly as `message.ts` builds it:

```
Your SurGo OTP code is 123456. Please do not share. Expires in 1 minute.
```

A shorter message is accepted with `201` and then rejected asynchronously with
`Unacceptable content: OTP does not follow valid format`. `UNISMS_SENDER_ID`
defaults to `Unisoft` when unset.

## Timeout budget

Supabase gives the **entire HTTP hook invocation 5 seconds**, including edge
cold start, network transit and the function's own work. The Semaphore request
uses a **2-second timeout**, leaving roughly 3 seconds of headroom. A 4-second
timeout was rejected during review because a cold start plus a slow Semaphore
response could exceed the hook budget, causing Supabase to return a hook
timeout even though the SMS might still be delivered.

UniSMS has the same 2-second send budget. Its delivery-status read starts about
1.5 seconds after the send began and is capped at 800 ms, so the whole call
stays inside the hook budget. Set `UNISMS_VERIFY_DELIVERY=false` only if the
status endpoint is unavailable; doing so gives up detection of asynchronous
content rejections.

If production metrics show Semaphore's p99 above ~1.5 seconds, the timeout can
be raised slightly (never beyond 2.5 seconds). A timed-out request is ambiguous:
the SMS may have been queued, so the user can retry and may receive a second
code. Supabase does not retry `502`, so this function does not amplify that.

## Environment secrets

Set these as **Edge Function secrets**, never in Flutter and never in git:

| Secret | Required | Notes |
| --- | --- | --- |
| `SEND_SMS_HOOK_SECRET` | yes | Value shown by Supabase when the hook is created, format `v1,whsec_...` |
| `SEMAPHORE_API_KEY` | when `SMS_PROVIDER` is unset or `semaphore` | Semaphore account API key |
| `SEMAPHORE_SENDER_NAME` | no | Approved Semaphore sender name; omit to use the default |
| `SMS_PROVIDER` | no | `semaphore` (default) or `unisms`; exactly one provider is called |
| `UNISMS_API_KEY` | when `SMS_PROVIDER=unisms` | UniSMS API key (Basic auth username) |
| `UNISMS_SENDER_ID` | no | Approved UniSMS sender name; defaults to `Unisoft` |
| `UNISMS_VERIFY_DELIVERY` | no | Set to `false` to skip the async status read; defaults to enabled |

Provider selection never falls back: a misconfigured provider reports a
hook-level failure instead of quietly sending through the other one. See
`docs/PROVIDER_SECRETS.md` for the local secret file and the apply tool.

```bash
supabase secrets set --project-ref lrhgktxmavnhjatqzbzr \
  SEMAPHORE_API_KEY="..." \
  SEND_SMS_HOOK_SECRET="v1,whsec_..." \
  SEMAPHORE_SENDER_NAME="SurGo"

# Or switch OTP delivery to UniSMS:
supabase secrets set --project-ref lrhgktxmavnhjatqzbzr \
  SMS_PROVIDER="unisms" \
  UNISMS_API_KEY="..." \
  UNISMS_SENDER_ID="Unisoft"
```

Changing secrets after a deploy: redeploy (or restart) the function so new
isolates read the updated values.

## Deploy (not done yet — requires approval)

```bash
supabase login
supabase link --project-ref lrhgktxmavnhjatqzbzr

# Auth hooks authenticate with Standard Webhooks signatures, not a JWT.
supabase functions deploy send-sms \
  --no-verify-jwt \
  --project-ref lrhgktxmavnhjatqzbzr
```

Function URL:

```
https://lrhgktxmavnhjatqzbzr.supabase.co/functions/v1/send-sms
```

`--no-verify-jwt` is required. Without it Supabase's own hook request is
rejected before this code runs. `supabase/config.toml` also records
`[functions.send-sms] verify_jwt = false` for local deploys.

## Dashboard configuration

Deploying the function does **not** enable the hook. All of these are separate
dashboard steps:

1. **Auth → Providers → Phone**
   - Enable the Phone provider.
   - Keep phone auto-confirm **off** so Supabase requires the OTP.
   - The built-in Twilio provider is not used once the Send SMS hook is
     active; it does not need valid credentials.
2. **Auth → Hooks → Send SMS**
   - Enable the hook.
   - Type: **HTTP**.
   - URL: `https://lrhgktxmavnhjatqzbzr.supabase.co/functions/v1/send-sms`
   - Copy the generated secret (`v1,whsec_...`) into
     `SEND_SMS_HOOK_SECRET`, then redeploy the function.
   - Keep the hook enabled; disabling it falls back to the built-in provider.
3. Do **not** enable "autoconfirm" and do **not** point the hook at a custom
   verification service — Supabase must remain the OTP authority.

If the hook secret is ever lost, regenerate it in the dashboard, update the
Edge Function secret, and redeploy. Requests signed with the old secret will
return 401 until both sides match.

## Local tests

No Docker, Supabase CLI or Deno install is required for these tests; they use
Node 24's TypeScript support and Web Crypto.

```bash
node --test supabase/functions/send-sms/*_test.ts
```

Covered locally:

- PH phone normalization (`+63`, `63`, `0` forms, spacing/punctuation) and
  rejection of non-PH or malformed numbers.
- OTP shape validation and the UniSMS-compliant message construction.
- Standard Webhooks verification: valid signatures, `v1,whsec_` and bare
  secrets, tampering, wrong secret, stale/future timestamps, tolerance edge,
  missing/malformed headers, multiple signatures, unusable secret.
- Handler behavior with a mocked provider: success, sendername present and
  absent, bad signature, stale request, invalid payload, provider 4xx, a
  `Failed` message entry, network error, missing secrets, non-POST, and the
  Auth-compatible `{ error: { http_code, message } }` failure envelope.
- Payload destination: `sms.phone` wins over `user.phone`, including a
  first-time phone link where `user.phone` is null.
- UniSMS response contract: accepted statuses, rejection/failure bodies,
  non-2xx, network errors, timeouts, exact JSON fields, Basic auth, async
  status verification, and the case where the status read itself fails.
- No test makes a real network call and no test contains a real API key.

The same suite runs on the production runtime:

```bash
npx --yes deno check supabase/functions/send-sms/index.ts
npx --yes deno test --allow-env supabase/functions/send-sms/
```

`supabase functions serve` needs Docker (or Podman), which is not installed on
this machine. To smoke-test the HTTP path without it, start the function
directly with throwaway secrets and POST to it:

```bash
SEND_SMS_HOOK_SECRET="v1,whsec_<base64 test key>" \
SEMAPHORE_API_KEY="placeholder" \
npx --yes deno run --allow-net --allow-env supabase/functions/send-sms/index.ts
```

Use an invalid phone or OTP so the request is rejected before any Semaphore
call; a valid request would attempt real delivery.

## Real SMS acceptance checklist

Do not report phone auth as working until a real handset receives a real SMS.
Hosted changes and deployment need explicit approval first.

Prerequisites: hosted function deployed, hook enabled, phone provider enabled,
Semaphore account funded, sender name approved (or omitted), Flutter build
pointed at the hosted project, and a phone number you control.

1. Fresh install; sign up with the test number. Exactly one SMS arrives.
2. The SMS body matches:
   `Your SurGo OTP code is {OTP}. Please do not share. Expires in 1 minute.`
3. Enter the code from the SMS; sign-in completes.
4. Request a new code. The old code is rejected; the newest code works.
5. Enter a wrong code. The app shows the auth error and the user is not signed in.
6. Wait past expiry, then try the expired code; it is rejected.
7. Resend inside Supabase's rate window; confirm the expected rate-limit error,
   not a duplicate delivery.
8. Force-close and reopen the app; the session is restored without a new SMS.
9. Log out, sign in again by OTP.
10. From Account settings, link a phone number; verify with the SMS code.
11. Try a non-PH or malformed number; the app fails cleanly and the function
    log shows no outbound Semaphore request.
12. Check function logs: no OTP, phone number, API key or full payload appears.
13. Confirm Google sign-in still works (it was not touched).

If no SMS arrives, inspect in this order: hook enabled and pointing at the
function URL → `SEND_SMS_HOOK_SECRET` matches → function logs (401/502) →
Semaphore credits/sender name → phone number format.

## Response codes

Expected failures are returned as **HTTP 200** with an Auth-readable envelope,
because Supabase discards a non-2xx body and shows the app a generic 500:

```json
{ "error": { "http_code": 422, "message": "We could not send …" } }
```

| HTTP | Meaning |
| --- | --- |
| 200, body `{ "ok": true }` | The selected provider accepted the message |
| 200, body `{ "error": … }` | A handled failure; `http_code` is 400, 413, 422 or 500 |
| 401 | Missing/invalid Standard Webhooks signature, wrong secret, or stale timestamp |
| 405 | Not a POST request |

Inside the error envelope:

| `http_code` | Meaning |
| --- | --- |
| 400 | Not JSON, missing phone/OTP, non-PH number, or non-numeric OTP |
| 403 | Demo identity number; it must never receive an OTP |
| 413 | Body larger than 32 KB |
| 422 | Provider HTTP error, rejected/failed message, malformed response, or network/timeout |
| 500 | A required secret is not configured |

Only the failure reason and HTTP status are logged. The payload, phone number,
OTP, provider response body and API key are never logged or returned to the
caller.
