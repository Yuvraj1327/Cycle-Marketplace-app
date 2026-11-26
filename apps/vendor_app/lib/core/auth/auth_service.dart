import 'dart:async';

/// What the app needs from the identity provider. Supabase Auth is the real implementation; tests use a fake. No passwords are ever stored by the
/// app or sent to FastAPI: credentials go straight to Supabase and only the resulting access token goes to the backend.
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

  /// false => the Supabase project requires e-mail confirmation first; the vendor must open the link, then sign in.
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

  /// Registers a VENDOR-type account (sign-up metadata `role: vendor`, as documented in docs/backend-auth.md). That alone grants no privileges:
  /// the backend only lets an admin-approved vendor use business features, and verification can never be set by the app.
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
  Future<void> signOut();
}

/// Buckets the vendor app uploads to with the vendor's OWN session (Storage RLS enforces `<userId>/...`; binaries never pass through FastAPI).
enum ImageBucket {
  productImages('product-images'),
  shopImages('shop-images');

  const ImageBucket(this.id);
  final String id;
}

abstract class ImageStorage {
  /// Uploads and returns the storage path `<userId>/<folder>/<random>.<ext>`.
  Future<String> upload({
    required ImageBucket bucket,
    required String userId,
    required String folder,
    required List<int> bytes,
    required String extension,
    required String contentType,
  });

  /// Public URL for an object in a public bucket (pure string building, no network).
  String publicUrl(ImageBucket bucket, String path);
}
