import 'dart:async';

/// What the app needs from an identity provider. Supabase Auth is the real implementation; tests use a fake. No passwords are ever stored
/// by the app or sent to FastAPI: credentials go straight to Supabase and only the resulting access token goes to the backend.
class AuthFailure implements Exception {
  AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The user dismissed the Google account chooser. Not an error: screens swallow it silently.
class AuthCancelled implements Exception {
  const AuthCancelled();
  @override
  String toString() => 'Sign-in cancelled';
}

class GoogleSignInResult {
  const GoogleSignInResult({this.displayName});

  /// The name on the Google account, used only to fill an EMPTY profile name after sign-in.
  final String? displayName;
}

class SignUpResult {
  const SignUpResult({required this.signedIn});

  /// false => Supabase requires e-mail confirmation first (project setting); the user must open the link, then sign in.
  final bool signedIn;
}

abstract class AuthService {
  bool get isSignedIn;
  String? get userId;
  Stream<bool> get signedInChanges;

  /// A valid access token, refreshing it first if it is about to expire. null when signed out.
  Future<String?> accessToken();

  /// Force a refresh (used after a 401). null if the session cannot be refreshed.
  Future<String?> refreshAccessToken();

  Future<void> signInWithPassword({
    required String email,
    required String password,
  });
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  });
  Future<void> sendPasswordReset(String email);

  /// Native Google sign-in (Android/iOS): Google issues an ID token, Supabase verifies it and creates or signs in the matching auth user.
  /// This only authenticates: the role and status still come from the backend (`/auth/me`) exactly as for a password sign-in.
  /// Throws [AuthCancelled] when the user dismisses the chooser and [AuthFailure] (user-ready message) for everything else.
  Future<GoogleSignInResult> signInWithGoogle();

  /// Changes the password of the signed-in account. The current password is verified first (a fresh sign-in), so a stolen unlocked phone
  /// cannot silently take the account over. Throws [AuthFailure] with a user-ready message.
  Future<void> changePassword({
    required String email,
    required String currentPassword,
    required String newPassword,
  });
  Future<void> sendPhoneOtp(String phone);
  Future<void> verifyPhoneOtp({required String phone, required String code});
  Future<void> signOut();
}

/// Uploads cycle photos straight to Supabase Storage (private bucket) with the user's own session. Binaries never pass through FastAPI.
abstract class ImageStorage {
  /// Returns the storage path `<userId>/<bookingId>/<file>`.
  Future<String> uploadBookingImage({
    required String userId,
    required String bookingId,
    required List<int> bytes,
    required String extension,
    required String contentType,
  });
}
