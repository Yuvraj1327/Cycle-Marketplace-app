import 'dart:async';

/// What the app needs from an identity provider. Supabase Auth is the real implementation; tests use a fake. No passwords are ever stored
/// by the app or sent to FastAPI: credentials go straight to Supabase and only the resulting access token goes to the backend.
class AuthFailure implements Exception {
  AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
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
