# SurGo Demo Accounts

> **This file contains no PINs, passwords, or secret values, and it must stay
> that way.** The repository has remote copies. Real credentials live in a
> password manager or a private file outside the repository, never in Markdown,
> JSON, `.env` examples, issues, or commits.

## Account inventory

| Surface | Account | How it signs in | Usable for the defense? |
| --- | --- | --- | --- |
| Offline demo build | Existing seed identities ACC003 / ACC006 / ACC002 / ACC007 | Account number or phone + OTP `123456`, then a device PIN | **Yes**, with `--dart-define=SURGO_DEMO_AUTH=true` |
| Flutter app (normal build) | 19 fictional demo people | Philippine mobile number + their own server-verified 6-digit PIN | **Prepared, not applied** |
| Flutter app (normal build) | Real phone registration | PH mobile number + SMS OTP | **Yes**, after registering on the demo device |
| Flutter app (normal build) | Google account | Google OAuth through Supabase | **Yes**, once the OAuth redirect URI and test user are configured |
| Admin dashboard | Operator's account | Email + password in Supabase Auth | **Yes**, password known only to the operator |

The 19 demo people have email addresses so the hosted rows and dashboard are
complete, but **no email password is created, issued, or required for demo
login**. Their sign-in credential is phone + PIN.

## Offline presentation build

Run the same app against the local seed instead of Supabase:

```bash
flutter run --dart-define=SURGO_DEMO_AUTH=true
```

| Demo role | Account number | Identity | Phone | OTP |
| --- | --- | --- | --- | --- |
| Passenger | `ACC003` | Nena Villareal | `+63 918 335 2290` | `123456` |
| Rider | `ACC006` | Bebot Lim | `+63 926 771 3390` | `123456` |
| Vehicle owner | `ACC002` | Grace Ann Villaflor | `+63 917 220 4411` | `123456` |
| Helper (Pasuyo) | `ACC007` | Carlo Mendoza | `+63 927 882 4415` | `123456` |

- The login box accepts either the account number or the phone number. The OTP
  screen shows the preview code.
- The session is written to `SharedPreferences` under `surgo.demo.session`.
  Closing and reopening the app keeps the same person signed in, but the
  dashboard is replaced by a PIN lock.
- The default device PIN is `123456`. Change it under **Profile → Account
  Settings → App PIN** (each role's profile screen uses the same settings page).
- **Forgot PIN?** on the lock screen signs out and resets the PIN to the default,
  so the next OTP sign-in is not locked behind a forgotten PIN.
- This mode makes no Supabase call and ignores `SURGO_DATA_SOURCE`; it is a
  local seed demo. Without the flag, Supabase Auth and the normal data source
  behave exactly as before.
- `ACC001` (Jr Derigay) also works and keeps all four roles, but the four rows
  above are the prepared presentation identities.

## 1. Flutter phone accounts

Real users register in the app with a phone number they control and sign in with
the SMS OTP. A new account starts as **passenger only**.

1. **Register** → enter the phone number → receive the SMS OTP → enter it.
2. For Rider and Vehicle Owner, open **Profile → Verification**, start each
   verification, attach the demo documents, and submit. The prototype
   auto-approves after about five seconds. The unlock lasts for the session;
   restarting the app returns the account to passenger-only.
3. For Pasuyo, switch to Rider and enable **Errands** in the Rider profile.

The phone number and the OTP are the credentials. Neither belongs in this
repository.

## 2. Google sign-in

Google sign-in goes through Supabase, so there is no local password to record.
The Google account's password is managed by Google.

Before relying on it:

- Add `https://lrhgktxmavnhjatqzbzr.supabase.co/auth/v1/callback` to the Google
  OAuth client's **Authorized redirect URIs** (the current
  `redirect_uri_mismatch` error comes from this missing entry).
- Keep `io.supabase.surgo://login-callback` in Supabase's **Redirect URLs**.
- If the OAuth consent screen is in **Testing**, add the demo Google account as
  a test user.

## 3. Admin dashboard

The admin dashboard uses the operator's real Supabase account:

- It has an **email identity only** — no phone and no Google identity — so it
  cannot sign into the Flutter app.
- Its approved roles are `passenger` and `admin`.
- The password was set in the Supabase dashboard and is known only to the
  operator. It is not recoverable from this repository; if it is lost, reset it
  in Supabase Auth.
- The helper tools read the account identifiers from
  `SURGO_REAL_USER_EMAIL` / `SURGO_REAL_USER_ID` in the environment. Their
  values are intentionally not committed.

Do not write this account's email or password into a tracked file. Supply the
credentials out-of-band at the defense.

## 4. Hosted demo login: phone + PIN (prepared, approval required)

### Architecture

| Piece | Location | Role |
| --- | --- | --- |
| PIN store | `private.demo_access` in `20261111140000_demo_pin_access.sql` | One PBKDF2-SHA256 hash plus lockout state per auth user |
| PIN RPCs | same migration: `set_demo_access`, `demo_login_lookup`, `demo_login_record_failure`, `demo_login_record_success` | `SECURITY DEFINER`, `search_path = ''`, service-role-only `EXECUTE`; no browser or `anon` access |
| Login endpoint | `supabase/functions/demo-login` (`verify_jwt = false`) | Normalizes the phone, verifies the PIN, enforces the lockout, checks account status, and returns a GoTrue session |
| App client | `SupabaseAuthRepository.signInWithDemoPin` | Calls the function and adopts the returned session with `recoverSession` |
| App screen | **Use demo phone + PIN** on the sign-in screen | Only shown when the hosted provider is installed; the offline demo build keeps its account-number + OTP flow |
| Provisioning | `supabase/tools/provision_demo_accounts.mjs` | Dry-run by default; updates the 19 existing auth rows and writes each PIN hash |
| Verifier | `supabase/tools/verify_demo_accounts.mjs` | Signs every demo account in and re-checks role and row isolation |

Design rules baked into the pieces above:

- The PIN is compared **on the server only**. The Flutter bundle contains no
  PIN, no hash, and no demo credential.
- Hashes are PBKDF2-SHA256, 210,000 iterations, a 16-byte random salt, and a
  32-byte derived key (`pbkdf2-sha256$<iterations>$<salt>$<hash>`). The SQL check
  constraint rejects any other shape.
- Five wrong PINs lock that account for 15 minutes. A locked account is refused
  before the hash is checked, and a correct PIN after the lock expires resets
  the counter.
- The endpoint answers unknown numbers with the same generic failure and runs a
  dummy PBKDF2 verification, so response content and timing do not reveal which
  numbers exist.
- A suspended profile (Junel Ramos) receives `403 account_unavailable` even
  with the correct PIN. Provisioning never writes `profiles.account_status`.
- Failed, locked, suspended, and misconfigured responses never include a
  session, token, or backend SQL text.
- Emails are preserved or synthesized only to complete the auth row and
  dashboard. They have **no password** and are not a login path.

### What provisioning changes, per existing profile id

- Confirms the email and phone on the existing `auth.users` row and removes the
  ban (`ban_duration: 'none'`).
- Repairs the missing email identity row that SQL-seeded users need, so the
  account is complete in GoTrue.
- Marks the account `surgo_demo: true` and `surgo_onboarded: true` in user
  metadata. The app reads the first marker to skip the second device PIN (the
  server PIN is the only credential) and the second to skip onboarding.
- Keeps the 11 existing `@email.com` addresses; the 8 people without one get a
  reserved `<name>@surgo-demo.test` address, mirrored onto their profile.
- Normalizes every phone to E.164 and assigns the 8 people without a number a
  unique demo number (see the table below).
- Writes a freshly generated, unique 6-digit PIN hash for each account. The
  plaintext PIN is written only to a file **outside the repository**.
- Changes no `profiles.account_status`, no role, and no wallet, ride, rental,
  Pasuyo, or transaction row.

### Deployment and run order (after approval)

```bash
# 1. Apply the PIN migration to the hosted project.
supabase db push            # or the Management API path used for earlier migrations

# 2. Deploy the login endpoint. No extra secrets: the function reads the
#    platform-provided SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.
supabase functions deploy demo-login --project-ref <project-ref>

# 3. Read-only plan against the hosted project (no writes).
node supabase/tools/provision_demo_accounts.mjs

# 4. Apply only after the plan is approved and the service key is supplied
#    locally. The token is exact; anything else refuses to write.
SURGO_DEMO_PROVISION=confirm-19-demo-pins \
SUPABASE_SERVICE_ROLE_KEY=<server-only key> \
  node supabase/tools/provision_demo_accounts.mjs --apply --verify-login

# 5. Read-only verification of all 19 accounts.
node supabase/tools/verify_demo_accounts.mjs \
  --credentials "$USERPROFILE/surgo-demo-credentials/demo-pins-<stamp>.json"
```

The service-role key is read from the environment only, is never printed, and
never appears in the app. The PIN file is created with owner-only permissions,
is refused inside the repository, and is never overwritten.

In the Flutter app, choose **Use demo phone + PIN** on the sign-in screen and
enter the number in `09XXXXXXXXX` or `+639XXXXXXXXX` form; both normalize to
E.164. A successful sign-in opens the dashboard directly — demo identities do
not show a second device PIN. **Profile → Account Settings** therefore omits the
App PIN tile for them.

### Complete 19-person mapping (audited 2026-11-11, not applied)

`Account` is the offline seed account from `assets/db/accounts.json`; the eight
archived people have none. `Phone` is the number the hosted account will accept;
the eight marked *(assigned)* have no seeded phone and receive a demo number.
Emails marked *(synthetic)* use the reserved `.test` domain.

| Account | Fictional name | Profile / auth UUID | Approved roles | Phone (E.164) | Email after provisioning |
| --- | --- | --- | --- | --- | --- |
| *(archived)* | Alex Tan | `3f6cbb9b-9a43-af30-7d51-03f3a179499f` | passenger, vehicle_owner | `+639170000001` *(assigned)* | alex.tan@surgo-demo.test *(synthetic)* |
| `ACC006` | Bebot Lim | `ed2aa82a-f064-9589-b57d-24f7c1820f3f` | passenger, earner | `+639267713390` | bebot.lim@email.com |
| `ACC007` | Carlo Mendoza | `f0be59a4-1186-ebe9-bcbb-8ecab26716bc` | passenger, earner | `+639278824415` | carlo.mendoza@email.com |
| `ACC004` | Danilo Cruz | `043bb2a5-4aa9-0680-c252-0ec4aa5e5a7c` | passenger, vehicle_owner | `+639194478812` | danilo.cruz@email.com |
| `ACC008` | Danny Reyes | `f4ad1842-a5ff-c9e3-9b43-d141b0f0745e` | passenger, earner | `+639289935521` | danny.reyes@email.com |
| `ACC009` | Edwin Santillan | `e5f153af-2b86-ddcd-3ace-fb16a216a0da` | passenger | `+639291046632` | edwin.santillan@email.com |
| `ACC002` | Grace Ann Villaflor | `2db06d3b-a51d-e5a7-f9d7-2b459fc14694` | passenger, vehicle_owner | `+639172204411` | grace.villaflor@email.com |
| `ACC010` | Isabella Dizon | `d3a8847f-82ba-7ea9-af85-b773c71205fb` | passenger, earner, vehicle_owner | `+639302158888` | isabella.dizon@email.com |
| *(archived)* | Jomar Lim | `41f801ff-8cc1-e8dc-e475-7d174f5ad610` | passenger, earner | `+639170000002` *(assigned)* | jomar.lim@surgo-demo.test *(synthetic)* |
| `ACC001` | Jr Derigay | `19aa7137-bdef-93ed-1610-0139c328cf0e` | passenger, earner, rider, vehicle_owner | `+639175124809` | jr.derigay@email.com |
| *(archived)* | Junel Ramos | `3a47be71-1288-3dd1-428b-43cd444316d6` | passenger, earner | `+639170000003` *(assigned)* | junel.ramos@surgo-demo.test *(synthetic)* |
| *(archived)* | Kd Sotto | `55b85eed-6ef1-a9b9-cf5d-8fec8cbfb508` | passenger, earner | `+639170000004` *(assigned)* | kd.sotto@surgo-demo.test *(synthetic)* |
| `ACC011` | Marco Villanueva | `c8c331f0-856a-8315-92b8-25e6a1340d1b` | passenger | `+639313269977` | marco.villanueva@email.com |
| *(archived)* | Marisol Cruz | `d323a372-5f50-eeb3-8704-934baaca7d82` | passenger | `+639170000005` *(assigned)* | marisol.cruz@surgo-demo.test *(synthetic)* |
| *(archived)* | Marlon Uy | `2bd7c3b2-e16c-3484-79fd-a1dc6483ffa2` | passenger, earner | `+639170000006` *(assigned)* | marlon.uy@surgo-demo.test *(synthetic)* |
| `ACC003` | Nena Villareal | `6e8dbe00-d9da-bfe0-71bc-0922bcaf5a79` | passenger | `+639183352290` | nena.villareal@email.com |
| *(archived)* | Rhea Puno | `d587f6ac-8df2-c405-fa63-451c7b9cde00` | passenger | `+639170000007` *(assigned)* | rhea.puno@surgo-demo.test *(synthetic)* |
| *(archived)* | Rico D. | `47ca4ef2-7325-73b2-2c37-d802e3595b2e` | passenger, vehicle_owner | `+639170000008` *(assigned)* | rico.d@surgo-demo.test *(synthetic)* |
| `ACC005` | Rosalinda Pajo | `ead213ad-285a-a69b-6a89-2f587ad3fcf5` | passenger, vehicle_owner | `+639165587734` | rosalinda.pajo@email.com |

No demo account holds the `admin` role. The operator's real account is not part
of this table and is never touched. **Junel Ramos stays suspended**: his profile
status is not changed, and the login endpoint refuses his PIN.

The four offline presentation identities keep their natural numbers:
Nena `0918 335 2290`, Bebot `0926 771 3390`, Grace `0917 220 4411`, Carlo
`0927 882 4415`. Their hosted PINs come from the private credential file, not
from this document.

### What the verifier checks

For every active account it signs in twice (E.164 and `09…` form), confirms the
session user id equals the profile id, then proves the account cannot read
another demo person's profile, roles, wallet, wallet transactions,
notifications, or device tokens. It also checks the ride/rental/Pasuyo policies
(only own participation, plus the documented shared-open visibility) and that no
demo account is an admin or can read the admin audit log.

For suspended accounts it proves a wrong PIN and the correct PIN both fail, and
that the profile is still suspended. It writes nothing, prints no PIN or token,
and needs no service-role key.

### Approval checklist

- [ ] The mapping above (phones, emails, roles, suspended status) is accepted.
- [ ] Confirming that no email password is created or needed for demo login.
- [ ] Confirming the PIN model: PBKDF2-SHA256 server-side, five attempts, a
      15-minute lock, no PIN in the bundle.
- [ ] Confirming the migration and function deployment are allowed on the hosted
      project.
- [ ] Confirming the eight assigned demo numbers are acceptable.
- [ ] Receiving the private PIN file location (outside the repository) so the
      defense can use it.

## 5. Private credential template

Keep any filled version **outside the repository** or in a file added to
`.gitignore`. Never commit it. The provisioning tool writes the demo PINs to
`%USERPROFILE%\surgo-demo-credentials\demo-pins-<stamp>.json`.

```json
{
  "demoPins": {
    "file": "<absolute path to demo-pins-<stamp>.json, outside the repository>",
    "notes": "One row per demo person: phone, PIN, profile id. Owner-only permissions."
  },
  "realFlutterAccount": {
    "phone": "<phone number you control>",
    "otp": "<received by SMS at sign-in time>",
    "notes": "Starts passenger-only; unlock Rider/Vehicle Owner in-session via Profile > Verification."
  },
  "adminDashboard": {
    "email": "<operator email>",
    "password": "<from your password manager>",
    "notes": "Email identity only; cannot sign into Flutter."
  },
  "google": {
    "account": "<Google account added as an OAuth test user>",
    "notes": "No password stored here."
  }
}
```

## 6. Pre-defense checks

- [ ] The offline build starts with `--dart-define=SURGO_DEMO_AUTH=true`.
- [ ] Each of the four account numbers signs in with OTP `123456` and lands on
      its own dashboard.
- [ ] The default device PIN `123456` unlocks a reopened offline session.
- [ ] The migration and `demo-login` function are deployed (hosted path).
- [ ] The provisioning plan was reviewed, then applied with the exact token.
- [ ] `verify_demo_accounts.mjs` passes for all 19 accounts.
- [ ] A demo phone signs in with **Use demo phone + PIN** and opens the
      dashboard without asking for a second PIN.
- [ ] A suspended demo account is refused even with the correct PIN.
- [ ] The real demo phone receives the SMS OTP (normal build only).
- [ ] The Flutter account can unlock Rider and Vehicle Owner in-session.
- [ ] The admin dashboard login works with the operator account.
- [ ] Google sign-in reaches the consent screen without
      `redirect_uri_mismatch`.
- [ ] No credential file is staged: run `git status` before committing.
