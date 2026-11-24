import 'dart:async';

/// What the app needs from the identity provider. Supabase Auth is the real implementation; tests use a fake. No passwords are ever stored by the
/// app or sent to FastAPI: credentials go straight to Supabase and only the resulting access token goes to the backend.
class AuthFailure implements Exception {
  AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
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
