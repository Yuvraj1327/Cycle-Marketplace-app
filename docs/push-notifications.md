# Push notifications — how to switch them on

Push is **built and tested with test doubles, but has never run against a real Firebase project.** Until the credentials below exist, the platform reports "not configured" (admin → Notifications → *Push delivery*) and in-app notifications work exactly as before.

## 1. Firebase project (client)
1. Create a Firebase project; add two **Android** apps with package names `com.cyclemarketplace.customer_app` and `com.cyclemarketplace.vendor_app` (change them first if the client wants its own ids; they are set in each app's `build.gradle.kts` and `MainActivity.kt`).
2. For each app note the four public values: **API key** (`FIREBASE_API_KEY`), **App ID** (`FIREBASE_APP_ID`), **Sender ID** (`FIREBASE_MESSAGING_SENDER_ID`), **Project ID** (`FIREBASE_PROJECT_ID`).
3. Project settings → Service accounts → *Generate new private key* → this JSON is a **server secret**.

## 2. Backend (secrets stay here)
Set `FCM_SERVICE_ACCOUNT_FILE=/path/key.json` **or** `FCM_SERVICE_ACCOUNT_JSON='{…}'` (and optionally `FCM_PROJECT_ID`). Restart. `GET /admin/push/status` now shows `configured: true`. Run migration 20 on the project database first.

## 3. Flutter apps
Copy `dart_defines.example.json` → `dart_defines.prod.json` (git-ignored), fill the four values, and build with `flutter build apk --dart-define-from-file=dart_defines.prod.json`. Without the values the app builds and runs with push off.

## 4. Check it end to end (needs a real phone)
Sign in on a phone → admin console → Notifications → *Push delivery* shows 1 device → place an order / send an announcement → the phone shows a system notification; tapping it opens the order / booking. Then sign out and confirm the device count drops. **This checklist has not been run** (no Firebase project) — treat Step 11's push as "implemented, awaiting configuration".

## Behaviour to know
* Sent after the database transaction commits, by a background loop (every `PUSH_DISPATCH_INTERVAL_SECONDS`, default 15 s) or the admin's *Send pending now*; retried with back-off 5 times; notifications older than 24 h are never pushed.
* A user with no registered device, or an inactive account, is `skipped` (not an error). Invalid tokens are deactivated automatically.
* Android 13+ asks for the notification permission after sign-in; declining leaves in-app notifications working.
* iOS is not set up (needs an Apple developer account + APNs key in Firebase).
