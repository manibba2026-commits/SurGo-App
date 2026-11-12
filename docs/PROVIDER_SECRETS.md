# Provider Secret Setup (Geoapify + UniSMS)

Two integrations run **only on the server**, as Supabase Edge Functions. Their
keys never enter the Flutter bundle, the repository, or a chat log.

| Integration | Function | Secret names |
| --- | --- | --- |
| Road routing / places | `geoapify` | `GEOAPIFY_API_KEY` |
| OTP delivery via UniSMS | `send-sms` | `SMS_PROVIDER=unisms`, `UNISMS_ACCESS_KEY_ID`, `UNISMS_ACCESS_KEY_SECRET`, `UNISMS_SIGNATURE`, `UNISMS_TEMPLATE_ID`, optional `UNISMS_CODE_VARIABLE`, `UNISMS_AUTH_MODE` |

`send-sms` also needs `SEND_SMS_HOOK_SECRET`, which already exists on the
project. Semaphore remains the default provider; adding the UniSMS names does
**not** switch delivery until `SMS_PROVIDER=unisms` is set.

## Where to paste local values

Create this file and fill it in a local editor (never in chat, never in git):

`C:\Users\NITRO\.surgo-secrets\providers.env`

```dotenv
GEOAPIFY_API_KEY=

# Only for switching OTP delivery to UniSMS:
SMS_PROVIDER=unisms
UNISMS_ACCESS_KEY_ID=
UNISMS_ACCESS_KEY_SECRET=
UNISMS_SIGNATURE=
UNISMS_TEMPLATE_ID=
UNISMS_CODE_VARIABLE=code
UNISMS_AUTH_MODE=hmac

# A handset you control, used only for the real-SMS acceptance check.
SURGO_TEST_PHONE=
```

The directory has a user-only ACL. The file is ignored by git regardless of
location because it lives outside the repository.

`UNISMS_AUTH_MODE` accepts `hmac` (default, needs the secret) or `simple`
(explicit opt-in, key id only). `UNISMS_SIGNATURE` is the approved UniSMS
sender signature, **not** the HMAC request signature.

## Apply the secrets

```bash
node supabase/tools/apply_provider_secrets.mjs
```

The tool reads the file above, validates the names, and writes them through the
Supabase Management API. The Management API token is read from the Windows
Credential Manager entry the Supabase CLI already stored — it is not printed,
written to disk, or passed on the command line. Only secret **names** and the
HTTP status are reported.

Optional: pass a different file as the first argument.

## Deploy the functions

Deploys need network access and the same stored CLI login; Docker is **not**
required.

```bash
npx --yes supabase@2 functions deploy geoapify \
  --project-ref lrhgktxmavnhjatqzbzr

npx --yes supabase@2 functions deploy send-sms \
  --no-verify-jwt \
  --project-ref lrhgktxmavnhjatqzbzr
```

`--no-verify-jwt` is mandatory for `send-sms`: Supabase Auth signs hook
requests with Standard Webhooks HMAC, not a user JWT. `geoapify` keeps JWT
verification and checks the caller's session itself.

Redeploy after changing secrets so warm isolates read the new values.

## Verify

### Geoapify

1. With no Authorization header, the function must answer `401` — proof it is
   deployed and refuses anonymous callers.
2. With a signed-in session it returns a route. The Flutter client uses
   `GeoapifyService` only when `usesHostedRideDispatch` is true.
3. In **Edge Functions → geoapify → Logs**, upstream failures appear as
   status-only entries; no key is logged.

### UniSMS

A real handset must receive the OTP before phone auth is reported as working.

1. `SMS_PROVIDER=unisms` and all UniSMS names applied, function redeployed.
2. In **Auth → Hooks → Send SMS**, the HTTP hook points at
   `/functions/v1/send-sms` and is enabled.
3. Request a code for `SURGO_TEST_PHONE`. Exactly one SMS arrives with
   `Your SurGo verification code is: <code>. Do not share this code with
   anyone.`
4. Function logs show `200`; failures show only a reason and upstream status.
5. A demo identity number is refused with `demo_number_blocked` and never
   reaches the provider.

## Rotation guidance

- **Geoapify** — rotate: the key was pasted into chat. Replace it in the
  Geoapify dashboard, update `providers.env`, rerun the apply tool.
- **UniSMS access key secret** — rotate if it was pasted into chat. Update the
  provider console, then `providers.env`, then redeploy.
- **MapTiler** — it is a public client key, but it was shared in chat. It cannot
  be kept secret in a browser; restrict it by HTTP referrer and package id (see
  `docs/MAP_TILES.md`). Rotate it if restriction is impossible.
- **Semaphore** — unchanged; its secret is already stored on the project.
