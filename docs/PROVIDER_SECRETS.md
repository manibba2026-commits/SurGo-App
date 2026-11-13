# Provider Secret Setup (Geoapify + UniSMS)

Two integrations run **only on the server**, as Supabase Edge Functions. Their
keys never enter the Flutter bundle, the repository, or a chat log.

| Integration | Function | Secret names |
| --- | --- | --- |
| Road routing / places | `geoapify` | `GEOAPIFY_API_KEY` |
| OTP delivery via UniSMS | `send-sms` | `SMS_PROVIDER=unisms`, `UNISMS_API_KEY`, optional `UNISMS_SENDER_ID` |

`send-sms` also needs `SEND_SMS_HOOK_SECRET`, which already exists on the
project. Semaphore remains the default provider; adding the UniSMS names does
**not** switch delivery until `SMS_PROVIDER=unisms` is set.

The UniSMS adapter posts to `https://unismsapi.com/api/sms` with HTTP Basic
auth (API key as the username, empty password) and the body
`{ "recipient": "+639…", "content": "…", "sender_id": "Unisoft" }`. Delivery is
accepted when the provider answers 2xx with `message.status` of `pending`,
`queued`, `sent`, `accepted` or `success`; a non-empty `fail_reason` or
`message.success == false` is treated as a rejection. `UNISMS_SENDER_ID`
defaults to `Unisoft` when unset.

Coverage caveat: the default `Unisoft` sender only reaches **Globe and DITO**.
Sending to Smart, TNT or Sun answers HTTP 422
(`This Sender ID can't send to Smart, TNT or Sun numbers…`), which the function
surfaces as `sms_delivery_failed`. To cover every network, apply for a custom
Sender ID in the UniSMS console (`/sender_ids/new`, organization adoption).
Until then, test OTP with a Globe/DITO handset; demo PIN login is unaffected.

## Where to paste local values

Create this file and fill it in a local editor (never in chat, never in git):

`C:\Users\NITRO\.surgo-secrets\providers.env`

```dotenv
GEOAPIFY_API_KEY=

# Only for switching OTP delivery to UniSMS:
SMS_PROVIDER=unisms
UNISMS_API_KEY=
UNISMS_SENDER_ID=Unisoft

# A handset you control, used only for the real-SMS acceptance check.
SURGO_TEST_PHONE=
```

The directory has a user-only ACL. The file is ignored by git regardless of
location because it lives outside the repository.

`UNISMS_API_KEY` is the whole credential the adapter needs — there is no
separate access-key secret, template, or HMAC mode. `UNISMS_SENDER_ID` is the
approved sender name shown on the handset, not a template.

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

## OAuth providers (Google + Facebook)

The Flutter client already calls `signInWithOAuth` for both providers; no
provider secret is compiled into the app.

Both providers authenticate through Supabase's callback, so their consoles must
allow exactly:

`https://lrhgktxmavnhjatqzbzr.supabase.co/auth/v1/callback`

- **Google** — in Google Cloud Console → APIs & Services → Credentials → the
  Web OAuth client used by the project, add that URI under **Authorized redirect
  URIs**. The hosted Supabase project already holds the matching client ID and
  secret; `redirect_uri_mismatch` means only this console entry is missing.
- **Facebook** — in Meta for Developers → the app → Facebook Login → Settings →
  **Valid OAuth Redirect URIs**, add the same URI. Then, in Supabase Dashboard
  → Authentication → Providers → Facebook, enable the provider and paste the
  App ID and App Secret. Never paste the App Secret into chat, source, or this
  file.

The project's **Site URL** is the production app
(`https://sur-go-flutter-app-main.vercel.app/`), and the redirect allow-list
already covers the Vercel app, local development on port 5000, and the custom
native scheme. Phone OTP and demo PIN do not use either OAuth provider.

## Rotation guidance

- **Geoapify** — rotate: the key was pasted into chat. Replace it in the
  Geoapify dashboard, update `providers.env`, rerun the apply tool.
- **UniSMS API key** — rotate if it was pasted into chat. Replace it in the
  UniSMS console, update `providers.env`, rerun the apply tool, redeploy
  `send-sms`.
- **MapTiler** — it is a public client key, but it was shared in chat. It cannot
  be kept secret in a browser; restrict it by HTTP referrer and package id (see
  `docs/MAP_TILES.md`). Rotate it if restriction is impossible.
- **Semaphore** — unchanged; its secret is already stored on the project.
