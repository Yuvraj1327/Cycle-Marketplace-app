# Continue with Google (customer app + vendor app)

Native Google sign-in on **Android and iOS**, verified by **Supabase Auth**. The apps never see a Google secret: Google issues an ID token to the device, the app hands it to Supabase (`signInWithIdToken`), and Supabase verifies it and creates or signs in the matching auth user. E-mail/password (and phone OTP in the customer app) are unchanged.

## How it fits the existing flow

```
[Continue with Google] -> google_sign_in (native chooser) -> ID token
  -> Supabase signInWithIdToken(google)        -> session (same as a password sign-in)
  -> AuthController loads GET /auth/me         -> role + status come from public.profiles
       customer app: role must be `customer` and status `active`
       vendor app:   role must be `vendor`,   status `active`, then the vendor-approval stage
```

* **Authorization is untouched.** Google only proves *who* the person is. A Google account of the wrong role, or a suspended one, is signed straight back out with the usual message. Nothing in the app can set a role.
* **Profiles.** The existing `handle_new_user` trigger creates the `public.profiles` row on first Google sign-in (e-mail + `full_name` from Google, role `customer`). If Google did not supply a name and the profile name is empty, the app fills it once via `PUT /profiles/me` (name only). Returning users are just signed in.
* **Same e-mail = same account.** Supabase links a Google identity to an existing user with the same *verified* e-mail, so someone who registered with a password can later use Google.
* **Cancel / errors.** Dismissing the chooser is silent. Misconfiguration, network and Supabase errors show a short message on the form. The button is disabled while a sign-in is running.
* **Sign-out** also clears the Google account choice, so the next sign-in shows the chooser.

### Vendor app: sign-in only, no "Sign up with Google"

The role of a new account is decided by the database trigger from the **sign-up metadata** (`role: vendor`). A native Google sign-in cannot carry that metadata, so a brand-new Google user would be created as a **customer** and then be refused by the vendor app. To avoid creating stray customer accounts:

* The vendor **Sign in** screen has the Google button (works for existing vendor accounts, including ones that registered with e-mail + password under the same Gmail address).
* The vendor **Register** screen does **not** offer Google. Vendors register with e-mail/password, then may use Google afterwards.

If you want Google-first vendor registration, it needs a deliberate backend change (e.g. an admin-approved role promotion via `scripts.promote_admin`-style tooling or a controlled "claim vendor" function). That is a role-authorization decision, so it was not made here.

## Configuration

Add to each app's `.env` (already added as empty placeholders), or pass with `--dart-define` / `dart_defines.*.json` (these win over `.env`):

```env
GOOGLE_WEB_CLIENT_ID=      # "Web application" OAuth client  (needed on Android AND iOS)
GOOGLE_IOS_CLIENT_ID=      # "iOS" OAuth client               (needed on iOS)
GOOGLE_ANDROID_CLIENT_ID=  # "Android" OAuth client           (not read by the plugin; see below)
```

| Variable | Used by the app for | Also needed in |
|---|---|---|
| `GOOGLE_WEB_CLIENT_ID` | `serverClientId`: the ID token is minted *for* this client, and Supabase verifies it against it | Supabase → Google provider |
| `GOOGLE_IOS_CLIENT_ID` | `clientId` on iOS | Supabase "Authorized Client IDs" |
| `GOOGLE_ANDROID_CLIENT_ID` | nothing at runtime. Android identifies the app by package name + SHA-1 on Google's side | Supabase "Authorized Client IDs" |

Until `GOOGLE_WEB_CLIENT_ID` (and on iOS `GOOGLE_IOS_CLIENT_ID`) is set, the button is still shown and tapping it explains that Google sign-in is not set up in this build; nothing else is affected. Only public client IDs go here: **never a client secret** (the client secret lives only in the Supabase dashboard).

## What you must do manually

### 1. Google Cloud Console (one project for both apps)

1. **APIs & Services → OAuth consent screen**: set app name, support e-mail, authorised domain; scopes `openid`, `email`, `profile` (default). While the app is in *Testing*, add your Google accounts under **Test users**; publish to *Production* before release.
2. **APIs & Services → Credentials → Create credentials → OAuth client ID**, four clients in total:

| Client | Type | Values |
|---|---|---|
| Web (shared) | **Web application** | Name e.g. `cycle-supabase`. Authorized redirect URI: `https://<project-ref>.supabase.co/auth/v1/callback`. Copy the **Client ID** and **Client secret**. |
| Customer Android | **Android** | Package name `com.cyclemarketplace.customer_app` + SHA-1 (below) |
| Vendor Android | **Android** | Package name `com.cyclemarketplace.vendor_app` + SHA-1 (below) |
| Customer iOS | **iOS** | Bundle ID `com.cyclemarketplace.customerApp` |
| Vendor iOS | **iOS** | Bundle ID `com.cyclemarketplace.vendorApp` |

   (That is one Web + two Android + two iOS clients.)

3. **SHA-1 fingerprints** for each Android client. Create one Android client per fingerprint you will use (or per package, adding the fingerprint):
   * Debug: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android` (or `cd apps/customer_app/android && ./gradlew signingReport`).
   * Release: the SHA-1 of your release keystore. With **Play App Signing**, also add the *App signing key* SHA-1 shown in Play Console → Setup → App integrity.
   * The release build is currently signed with the debug key unless `android/key.properties` exists (see `docs/deployment-guide.md`), so register whichever key you actually ship with.

### 2. Supabase dashboard

**Authentication → Providers → Google** (or Sign In / Providers):

* Enable it.
* **Client IDs**: the Web client ID first, then the others, comma-separated, no spaces:
  `<web-id>,<customer-ios-id>,<vendor-ios-id>,<customer-android-id>,<vendor-android-id>`
* **Client Secret**: the Web client's secret.
* Turn **on "Skip nonce checks"**. `google_sign_in` does not send a nonce, and Supabase rejects the token without this (Android and iOS).
* Keep **"Allow users without an email"** off.

**Authentication → URL configuration** needs nothing new (no redirect/deep link is used; this is not the browser OAuth flow).

Do not disable e-mail confirmation or change the `handle_new_user` trigger for this.

### 3. App configuration

Fill in the `.env` of each app (see table above). Per app:

| | customer_app | vendor_app |
|---|---|---|
| `GOOGLE_WEB_CLIENT_ID` | the shared Web client ID | the same |
| `GOOGLE_IOS_CLIENT_ID` | customer iOS client | vendor iOS client |
| `GOOGLE_ANDROID_CLIENT_ID` | customer Android client | vendor Android client |

**iOS only: reversed client ID.** Google redirects back through a URL scheme that must be in the app's Info.plist and cannot come from a runtime `.env`. The plist references the build setting `GOOGLE_IOS_REVERSED_CLIENT_ID`. In each app:

```sh
cp ios/Flutter/Google.xcconfig.example ios/Flutter/Google.xcconfig   # git-ignored
# edit it: for GOOGLE_IOS_CLIENT_ID "123-abc.apps.googleusercontent.com"
# GOOGLE_IOS_REVERSED_CLIENT_ID = com.googleusercontent.apps.123-abc
```

Without it the iOS build still compiles (placeholder scheme), but Google sign-in cannot return to the app.

Android needs no manifest or Gradle change; `google_sign_in` 7 uses Android Credential Manager (needs Google Play services on the device/emulator image: use an image with the Play Store).

### 4. Run

```sh
cd apps/customer_app   # or apps/vendor_app
flutter pub get
flutter run            # .env is bundled; or: --dart-define-from-file=dart_defines.dev.json
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Android: chooser closes instantly / nothing happens (looks like a cancel) | Android OAuth client missing, wrong package name, or SHA-1 of the key actually signing the build isn't registered. Google reports this as "cancelled". |
| "Google sign-in is not set up in this build yet" | `GOOGLE_WEB_CLIENT_ID` (and on iOS `GOOGLE_IOS_CLIENT_ID`) is empty in the build. `.env` is bundled at build time: rebuild after editing it. |
| "not configured correctly for this build" | Web client ID not in Supabase's Client IDs, wrong client ID in the app, or "Skip nonce checks" is off. |
| "Google sign-in is not enabled for this project yet" | Google provider is disabled in Supabase. |
| Access blocked / 403 from Google | OAuth consent screen in *Testing* and your account isn't a test user. |
| Signed in, then "This app is for …" | The account's role belongs to the other app. Use the matching app. |
| iOS: returns to the app but sign-in fails | `Google.xcconfig` missing or reversed client ID wrong. |
