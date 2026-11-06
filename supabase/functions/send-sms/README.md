# send-sms — Supabase Auth Send SMS hook → Semaphore

SurGo's phone sign-in uses Supabase Auth to generate, expire and verify the
OTP. This Edge Function only delivers that code through Semaphore when
Supabase fires the **Send SMS** auth hook.

```
Flutter → supabase.auth.signInWithOtp()
        → Supabase Auth generates + stores the OTP
        → Send SMS hook (signed Standard Webhooks request)
        → this function verifies the signature, normalizes the phone
        → Semaphore POST /api/v4/messages
```

No OTP is generated here, stored in a table, or verified here. Semaphore's own
OTP endpoint is deliberately not used.

## What is in this folder

| File | Purpose |
| --- | --- |
| `index.ts` | Edge Function entry point, reads secrets from the environment |
| `handler.ts` | Request handling and response codes |
| `webhook.ts` | Standard Webhooks HMAC verification |
| `payload.ts` | Extracts `user.phone` and `sms.otp` from the verified payload |
| `phone.ts` | PH mobile normalization (`63XXXXXXXXXX`) and OTP shape check |
| `message.ts` | The exact SMS body |
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

## Timeout budget

Supabase gives the **entire HTTP hook invocation 5 seconds**, including edge
cold start, network transit and the function's own work. The Semaphore request
uses a **2-second timeout**, leaving roughly 3 seconds of headroom. A 4-second
timeout was rejected during review because a cold start plus a slow Semaphore
response could exceed the hook budget, causing Supabase to return a hook
timeout even though the SMS might still be delivered.

If production metrics show Semaphore's p99 above ~1.5 seconds, the timeout can
be raised slightly (never beyond 2.5 seconds). A timed-out request is ambiguous:
the SMS may have been queued, so the user can retry and may receive a second
code. Supabase does not retry `502`, so this function does not amplify that.

## Environment secrets

Set these as **Edge Function secrets**, never in Flutter and never in git:

| Secret | Required | Notes |
| --- | --- | --- |
| `SEMAPHORE_API_KEY` | yes | Semaphore account API key |
| `SEND_SMS_HOOK_SECRET` | yes | Value shown by Supabase when the hook is created, format `v1,whsec_...` |
| `SEMAPHORE_SENDER_NAME` | no | Approved Semaphore sender name; omit to use the default |

```bash
supabase secrets set --project-ref lrhgktxmavnhjatqzbzr \
  SEMAPHORE_API_KEY="..." \
  SEND_SMS_HOOK_SECRET="v1,whsec_..." \
  SEMAPHORE_SENDER_NAME="SurGo"
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
node --test \
  supabase/functions/send-sms/phone_test.ts \
  supabase/functions/send-sms/webhook_test.ts \
  supabase/functions/send-sms/semaphore_test.ts \
  supabase/functions/send-sms/handler_test.ts
```

Covered locally:

- PH phone normalization (`+63`, `63`, `0` forms, spacing/punctuation) and
  rejection of non-PH or malformed numbers.
- OTP shape validation and exact message construction.
- Standard Webhooks verification: valid signatures, `v1,whsec_` and bare
  secrets, tampering, wrong secret, stale/future timestamps, tolerance edge,
  missing/malformed headers, multiple signatures, unusable secret.
- Handler behavior with a mocked Semaphore: success, sendername present and
  absent, bad signature, stale request, invalid payload, Semaphore 4xx, a
  `Failed` message entry, network error, missing secrets, non-POST.
- Semaphore response contract: `Queued`/`Pending`/`Sent` accepted,
  `Failed`/`Refunded`/unknown/malformed rejected, non-2xx, network errors,
  timeout abort, and the exact form fields.
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
   `Your SurGo verification code is: {OTP}. Do not share this code with anyone.`
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

| Status | Meaning |
| --- | --- |
| 200 | Semaphore accepted the message |
| 400 | Not JSON, missing `user.phone`/`sms.otp`, non-PH number, or non-numeric OTP |
| 401 | Missing/invalid Standard Webhooks signature, wrong secret, or stale timestamp |
| 405 | Not a POST request |
| 413 | Body larger than 32 KB |
| 500 | One of the required secrets is not configured |
| 502 | Semaphore HTTP error, rejected/failed message, malformed response, or network/timeout |

Only the failure reason and HTTP status are logged. The payload, phone number,
OTP and API key are never logged or returned to the caller.
