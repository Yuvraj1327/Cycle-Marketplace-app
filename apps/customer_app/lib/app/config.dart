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

  static bool get supabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static String get apiV1 => '$apiBaseUrl/api/v1';
}
