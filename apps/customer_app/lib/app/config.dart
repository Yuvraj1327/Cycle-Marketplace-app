import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Build-time configuration (`--dart-define=NAME=value`, falling back to the bundled `.env` file when a define is not given). Nothing secret lives here: the Supabase ANON key is public by design;
/// the service-role key and payment secrets must never be put in this app.
class AppConfig {
  const AppConfig._();

  /// `--dart-define` wins; otherwise the value from `.env` (loaded in main). Unreplaced `YOUR_...` placeholders count as unset.
  static String _value(String defined, String key, [String fallback = '']) {
    if (defined.isNotEmpty) return defined;
    final fromEnv = dotenv.isInitialized ? dotenv.maybeGet(key) : null;
    if (fromEnv == null || fromEnv.trim().isEmpty) return fallback;
    final v = fromEnv.trim();
    return v.contains('YOUR_') ? fallback : v;
  }

  /// FastAPI base URL WITHOUT the /api/v1 suffix. 10.0.2.2 is the Android emulator's alias for the host machine.
  static String get apiBaseUrl => _value(
    const String.fromEnvironment('API_BASE_URL'),
    'API_BASE_URL',
    'http://10.0.2.2:8000',
  );
  static String get supabaseUrl =>
      _value(const String.fromEnvironment('SUPABASE_URL'), 'SUPABASE_URL');
  static String get supabaseAnonKey => _value(
    const String.fromEnvironment('SUPABASE_ANON_KEY'),
    'SUPABASE_ANON_KEY',
  );

  /// Only enable if phone (SMS OTP) sign-in is configured in the Supabase project; email/password is the default.
  static bool get phoneAuthEnabled =>
      const bool.fromEnvironment('PHONE_AUTH_ENABLED') ||
      _value('', 'PHONE_AUTH_ENABLED').toLowerCase() == 'true';

  /// Shown on the Support screen; hidden (with an explanation) while unset.
  static String get supportEmail =>
      _value(const String.fromEnvironment('SUPPORT_EMAIL'), 'SUPPORT_EMAIL');
  static String get supportPhone =>
      _value(const String.fromEnvironment('SUPPORT_PHONE'), 'SUPPORT_PHONE');

  /// Optional app version sent with the push device registration.
  static String get appVersion =>
      _value(const String.fromEnvironment('APP_VERSION'), 'APP_VERSION');

  /// Firebase (push notifications). All four come from the client's Firebase project (Project settings -> Your apps -> Android). Public client identifiers,
  /// not secrets (the server-side service-account key lives only on the backend). Leave empty and push stays off.
  static String get firebaseApiKey => _value(
    const String.fromEnvironment('FIREBASE_API_KEY'),
    'FIREBASE_API_KEY',
  );
  static String get firebaseAppId => _value(
    const String.fromEnvironment('FIREBASE_APP_ID'),
    'FIREBASE_APP_ID',
  );
  static String get firebaseMessagingSenderId => _value(
    const String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static String get firebaseProjectId => _value(
    const String.fromEnvironment('FIREBASE_PROJECT_ID'),
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
