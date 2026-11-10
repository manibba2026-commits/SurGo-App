# SurGo Demo Accounts

> **This file contains no passwords or secret values, and it must stay that way.**
> The repository has remote copies. Keep real credentials in a password manager or
> in a private file outside the repository, never in Markdown, JSON, `.env`
> examples, issues, or commits.

## Account inventory

| Surface | Account | How it signs in | Usable for the defense? |
| --- | --- | --- | --- |
| Offline demo build | Existing seed identities ACC003 / ACC006 / ACC002 / ACC007 | Account number or phone + OTP `123456`, then a device PIN | **Yes**, with `--dart-define=SURGO_DEMO_AUTH=true` |
| Flutter app (normal build) | Dedicated phone-registered demo account | PH mobile number + SMS OTP | **Yes**, after you register it on the demo device |
| Flutter app (normal build) | Google account | Google OAuth through Supabase | **Yes**, once the OAuth redirect URI and test user are configured |
| Admin dashboard | Operator's account | Email + password in Supabase Auth | **Yes**, password known only to the operator |
| Seeded demo people (19) | None (hosted) | Banned auth rows with no password | **No** as hosted logins — their seed copies power the offline demo |

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
- The default PIN is `123456`. Change it under **Profile → Account Settings →
  App PIN** (each role's profile screen uses the same settings page).
- **Forgot PIN?** on the lock screen signs out and resets the PIN to the default,
  so the next OTP sign-in is not locked behind a forgotten PIN.
- This mode makes no Supabase call and ignores `SURGO_DATA_SOURCE`; it is a
  local seed demo. Without the flag, Supabase Auth and the normal data source
  behave exactly as before.
- `ACC001` (Jr Derigay) also works and keeps all four roles, but the four rows
  above are the prepared presentation identities.

## 1. Flutter phone account

There is no seeded Flutter login. Register in the app with a phone number you
control:

1. **Register** → enter the phone number → receive the SMS OTP → enter it.
2. A new account starts as **passenger only**.
3. For Rider and Vehicle Owner, open **Profile → Verification**, start each
   verification, attach the demo documents, and submit. The prototype
   auto-approves after about five seconds. The unlock lasts for the session;
   restarting the app returns the account to passenger-only.
4. For Pasuyo, switch to Rider and enable **Errands** in the Rider profile.

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

## 4. Seeded demo people

`supabase/demo-data.sql` seeds 19 fictional people to populate the admin
dashboard and the app's shared demo rows. They are **not usable logins**:

- Each `auth.users` row has `banned_until = 'infinity'`.
- None has a password or a working OTP path.
- Their emails use the reserved-looking `@email.com` domain and exist only to
  satisfy foreign keys.
- Their records power profiles, vehicles, rides, rentals, Pasuyo tasks,
  wallets, and transactions.
- The offline demo build reads their copies from `assets/db/`; it never signs
  in through the hosted auth rows.

The full list is in `supabase/demo-data.sql`; the hosted project was verified
to have 19 banned demo auth users plus the operator's account. Making any of
them real hosted logins is separate and has **not** been done.

### Hosted mapping proposal (approval required, not applied)

| Demo role | Flutter account | Flutter profile ids | Hosted profile / auth UUID | Email | Phone | Hosted approved roles | Hosted status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Passenger | `ACC003` | `P003` | `6e8dbe00-d9da-bfe0-71bc-0922bcaf5a79` | nena.villareal@email.com | +63 918 335 2290 | passenger | banned, no password |
| Rider | `ACC006` | `P007` / `R002` | `ed2aa82a-f064-9589-b57d-24f7c1820f3f` | bebot.lim@email.com | +63 926 771 3390 | passenger, earner | banned, no password |
| Vehicle owner | `ACC002` | `P002` / `VOW-77214` | `2db06d3b-a51d-e5a7-f9d7-2b459fc14694` | grace.villaflor@email.com | +63 917 220 4411 | passenger, vehicle_owner | banned, no password |
| Helper | `ACC007` | `P008` / `R003` | `f0be59a4-1186-ebe9-bcbb-8ecab26716bc` | carlo.mendoza@email.com | +63 927 882 4415 | passenger, earner | banned, no password |

Why these records are the safe ones to reuse:

- In the hosted schema the profile id **is** the auth user id, and the seeded
  vehicles, wallets, rides, rentals, Pasuyo tasks, and transactions already
  reference that UUID. Reusing the row preserves every association.
- Inserting new auth users would either duplicate the people or require
  repointing foreign keys, so the existing auth rows should be unbanned and
  given credentials instead of replaced.
- The role rows already match `assets/db/accounts.json`; no role change is
  needed for the four demo identities.
- The Admin dashboard account stays a separate account with no phone or Google
  identity and is never linked to these demo people.

Do not unban, add credentials, or change roles until the exact plan is
approved.

## 5. Private credential template

If you want a single checklist for yourself, keep it **outside the repository**
or in a file you have added to `.gitignore`. Never commit the filled version.

```json
{
  "flutterDemo": {
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
- [ ] The default PIN `123456` unlocks a reopened session.
- [ ] The demo phone receives the OTP (normal build only).
- [ ] The Flutter account can unlock Rider and Vehicle Owner in-session.
- [ ] The admin dashboard login works with the operator account.
- [ ] Google sign-in reaches the consent screen without
      `redirect_uri_mismatch`.
- [ ] No credential file is staged: run `git status` before committing.
