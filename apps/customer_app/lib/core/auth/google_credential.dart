import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../app/config.dart';
import 'auth_service.dart';

/// What Google hands back after the user picks an account.
class GoogleCredential {
  const GoogleCredential({required this.idToken, this.displayName});
  final String idToken;
  final String? displayName;
}

/// Wraps the native Google account chooser so [SupabaseAuthService] stays testable and the `google_sign_in` API stays in one place.
abstract class GoogleCredentialSource {
  /// Shows the chooser. Throws [AuthCancelled] if dismissed and [AuthFailure] for configuration/network problems.
  Future<GoogleCredential> authenticate();

  /// Forgets the chosen account so the next sign-in shows the chooser again. Never throws.
  Future<void> signOut();
}

class NativeGoogleCredentialSource implements GoogleCredentialSource {
  static Future<void>? _initialized;

  static Future<void> _ensureInitialized() => _initialized ??= () async {
    try {
      await GoogleSignIn.instance.initialize(
        // iOS needs its own client ID; Android resolves the app by package name + SHA-1 and rejects/ignores a clientId.
        clientId: defaultTargetPlatform == TargetPlatform.iOS
            ? AppConfig.googleIosClientId
            : null,
        // The ID token is minted FOR the web client, which is what Supabase verifies it against.
        serverClientId: AppConfig.googleWebClientId,
      );
    } catch (_) {
      _initialized = null; // allow a retry instead of caching a failed init
      rethrow;
    }
  }();

  @override
  Future<GoogleCredential> authenticate() async {
    if (!AppConfig.googleSignInSupported) {
      throw AuthFailure('Google sign-in is only available on Android and iOS.');
    }
    if (!AppConfig.googleConfigured) {
      throw AuthFailure(
        'Google sign-in is not set up in this build yet. Please use e-mail and password.',
      );
    }
    try {
      await _ensureInitialized();
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw AuthFailure(
          'Google did not return a sign-in token. Please try again.',
        );
      }
      return GoogleCredential(
        idToken: idToken,
        displayName: account.displayName,
      );
    } on GoogleSignInException catch (e) {
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
        case GoogleSignInExceptionCode.interrupted:
          throw const AuthCancelled();
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          throw AuthFailure(
            'Google sign-in is not configured correctly for this build. Please use e-mail and password.',
          );
        case GoogleSignInExceptionCode.uiUnavailable:
          throw AuthFailure(
            'Google sign-in cannot open right now. Please try again.',
          );
        case GoogleSignInExceptionCode.userMismatch:
        case GoogleSignInExceptionCode.unknownError:
          throw AuthFailure('Google sign-in failed. Please try again.');
      }
    }
  }

  @override
  Future<void> signOut() async {
    // Never used in this run: nothing to forget.
    if (_initialized == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
