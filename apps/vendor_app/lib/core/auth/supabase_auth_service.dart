import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'auth_service.dart';
import 'google_credential.dart';

class SupabaseAuthService implements AuthService {
  SupabaseAuthService([
    sb.SupabaseClient? client,
    GoogleCredentialSource? google,
  ]) : _client = client ?? sb.Supabase.instance.client,
       _google = google ?? NativeGoogleCredentialSource();
  final sb.SupabaseClient _client;
  final GoogleCredentialSource _google;

  @override
  bool get isSignedIn => _client.auth.currentSession != null;
  @override
  String? get userId => _client.auth.currentUser?.id;

  @override
  Stream<bool> get signedInChanges =>
      _client.auth.onAuthStateChange.map((e) => e.session != null).distinct();

  @override
  Future<String?> accessToken() async {
    var session = _client.auth.currentSession;
    if (session == null) return null;
    final expiresAt = session.expiresAt;
    final nearExpiry =
        expiresAt != null &&
        DateTime.fromMillisecondsSinceEpoch(
          expiresAt * 1000,
        ).isBefore(DateTime.now().add(const Duration(seconds: 30)));
    if (nearExpiry) {
      try {
        session = (await _client.auth.refreshSession()).session ?? session;
      } on sb.AuthException {
        return null;
      }
    }
    return session.accessToken;
  }

  @override
  Future<String?> refreshAccessToken() async {
    try {
      return (await _client.auth.refreshSession()).session?.accessToken;
    } on sb.AuthException {
      return null;
    }
  }

  Never _fail(sb.AuthException e) => throw AuthFailure(_friendly(e));

  static String _friendly(sb.AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('invalid login')) return 'Incorrect e-mail or password.';
    if (m.contains('already registered') ||
        m.contains('already been registered')) {
      return 'An account with this e-mail already exists. Try signing in.';
    }
    if (m.contains('email not confirmed')) {
      return 'Please confirm your e-mail first (check your inbox), then sign in.';
    }
    if (m.contains('password') && m.contains('characters')) return e.message;
    if (m.contains('rate limit') || m.contains('too many')) {
      return 'Too many attempts. Please wait a minute and try again.';
    }
    return e.message;
  }

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async {
    try {
      // `role: vendor` only creates a vendor-TYPE account (database trigger). Business access still needs admin approval.
      final res = await _client.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'role': 'vendor',
          'full_name': fullName.trim(),
          if (phone != null && phone.isNotEmpty) 'phone': phone,
        },
      );
      return SignUpResult(signedIn: res.session != null);
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<GoogleSignInResult> signInWithGoogle() async {
    final credential = await _google
        .authenticate(); // AuthCancelled / AuthFailure propagate as-is
    try {
      await _client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.google,
        idToken: credential.idToken,
      );
    } on sb.AuthException catch (e) {
      await _google.signOut();
      throw AuthFailure(_googleFriendly(e));
    } catch (_) {
      await _google.signOut();
      throw AuthFailure(
        'Could not reach the server. Check your connection and try again.',
      );
    }
    return GoogleSignInResult(displayName: credential.displayName);
  }

  static String _googleFriendly(sb.AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('provider') && m.contains('not enabled') ||
        m.contains('unsupported provider')) {
      return 'Google sign-in is not enabled for this project yet.';
    }
    if (m.contains('nonce') ||
        m.contains('audience') ||
        m.contains('client id') ||
        m.contains('invalid') && m.contains('token')) {
      return 'Google sign-in is not configured correctly for this build. Please use e-mail and password.';
    }
    if (m.contains('rate limit') || m.contains('too many')) {
      return 'Too many attempts. Please wait a minute and try again.';
    }
    if (m.contains('banned') || m.contains('disabled')) {
      return 'This account cannot sign in. Please contact support.';
    }
    return 'Google sign-in failed. Please try again.';
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email.trim());
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<void> changePassword({
    required String email,
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      await _client.auth.signInWithPassword(
        email: email.trim(),
        password: currentPassword,
      );
    } on sb.AuthException catch (e) {
      if (e.message.toLowerCase().contains('invalid login')) {
        throw AuthFailure('Your current password is incorrect.');
      }
      _fail(e);
    }
    try {
      await _client.auth.updateUser(sb.UserAttributes(password: newPassword));
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<void> signOut() async {
    await _google
        .signOut(); // so the next Google sign-in offers the account chooser again
    await _client.auth.signOut();
  }
}

class SupabaseImageStorage implements ImageStorage {
  SupabaseImageStorage([sb.SupabaseClient? client])
    : _client = client ?? sb.Supabase.instance.client;
  final sb.SupabaseClient _client;

  @override
  Future<String> upload({
    required ImageBucket bucket,
    required String userId,
    required String folder,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    final rnd = Random.secure();
    final name = List.generate(
      8,
      (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = '$userId/$folder/$name.$extension';
    try {
      await _client.storage
          .from(bucket.id)
          .uploadBinary(
            path,
            Uint8List.fromList(bytes),
            fileOptions: sb.FileOptions(contentType: contentType),
          );
    } on sb.StorageException catch (e) {
      throw AuthFailure(e.message);
    }
    return path;
  }

  @override
  String publicUrl(ImageBucket bucket, String path) =>
      _client.storage.from(bucket.id).getPublicUrl(path);
}
