import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'auth_service.dart';

class SupabaseAuthService implements AuthService {
  SupabaseAuthService([sb.SupabaseClient? client])
    : _client = client ?? sb.Supabase.instance.client;
  final sb.SupabaseClient _client;

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
    if (m.contains('otp') || m.contains('token')) {
      return 'That code is invalid or has expired.';
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
      // `role` is deliberately NOT sent: the database trigger makes every self-signup a customer.
      final res = await _client.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
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
  Future<void> sendPasswordReset(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email.trim());
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<void> sendPhoneOtp(String phone) async {
    try {
      await _client.auth.signInWithOtp(phone: phone.trim());
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<void> verifyPhoneOtp({
    required String phone,
    required String code,
  }) async {
    try {
      await _client.auth.verifyOTP(
        phone: phone.trim(),
        token: code.trim(),
        type: sb.OtpType.sms,
      );
    } on sb.AuthException catch (e) {
      _fail(e);
    }
  }

  @override
  Future<void> signOut() => _client.auth.signOut();
}

class SupabaseImageStorage implements ImageStorage {
  SupabaseImageStorage([sb.SupabaseClient? client])
    : _client = client ?? sb.Supabase.instance.client;
  final sb.SupabaseClient _client;
  static const bucket = 'service-images';

  @override
  Future<String> uploadBookingImage({
    required String userId,
    required String bookingId,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    final rnd = Random.secure();
    final name = List.generate(
      8,
      (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = '$userId/$bookingId/$name.$extension';
    try {
      await _client.storage
          .from(bucket)
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
}
