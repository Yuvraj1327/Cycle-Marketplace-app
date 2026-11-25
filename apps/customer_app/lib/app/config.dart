/// Build-time configuration (`--dart-define=NAME=value`). Nothing secret lives here: the Supabase ANON key is public by design;
/// the service-role key and payment secrets must never be put in this app.
class AppConfig {
  const AppConfig._();

  /// FastAPI base URL WITHOUT the /api/v1 suffix. 10.0.2.2 is the Android emulator's alias for the host machine.
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Only enable if phone (SMS OTP) sign-in is configured in the Supabase project; email/password is the default.
  static const phoneAuthEnabled = bool.fromEnvironment('PHONE_AUTH_ENABLED');

  /// Shown on the Support screen; hidden (with an explanation) while unset.
  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL');
  static const supportPhone = String.fromEnvironment('SUPPORT_PHONE');

  /// Firebase (push notifications). All four come from the client's Firebase project (Project settings -> Your apps -> Android). Public client identifiers,
  /// not secrets (the server-side service-account key lives only on the backend). Leave empty and push stays off.
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseMessagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );
  static bool get firebaseConfigured =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseMessagingSenderId.isNotEmpty &&
      firebaseProjectId.isNotEmpty;

  static bool get supabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static String get apiV1 => '$apiBaseUrl/api/v1';
}
