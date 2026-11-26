import 'dart:async';
import 'dart:convert';

import 'package:customer_app/core/auth/auth_service.dart';
import 'package:customer_app/features/onboarding/onboarding_store.dart';
import 'package:dio/dio.dart';

/// In-memory onboarding flag; existing suites default to "already onboarded" so they land on the auth screens.
class FakeOnboardingStore implements OnboardingStore {
  FakeOnboardingStore({bool completed = true}) : _completed = completed;
  bool _completed;
  @override
  bool get isCompleted => _completed;
  @override
  Future<void> markCompleted() async => _completed = true;
}

/// In-memory identity provider for tests (no Supabase).
class FakeAuthService implements AuthService {
  FakeAuthService({String? token = 'tok-1', this.failSignInWith})
    : _token = token;
  String? _token;
  final String? failSignInWith;
  final _changes = StreamController<bool>.broadcast();
  int refreshCalls = 0;
  String? refreshedTo;
  int signInCalls = 0;
  bool signedOut = false;

  @override
  bool get isSignedIn => _token != null;
  @override
  String? get userId => _token == null ? null : 'user-1';
  @override
  Stream<bool> get signedInChanges => _changes.stream;
  @override
  Future<String?> accessToken() async => _token;
  @override
  Future<String?> refreshAccessToken() async {
    refreshCalls++;
    _token = refreshedTo;
    return refreshedTo;
  }

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    signInCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (failSignInWith != null) throw AuthFailure(failSignInWith!);
    _token = 'tok-1';
    _changes.add(true);
  }

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async => const SignUpResult(signedIn: false);
  @override
  Future<void> sendPasswordReset(String email) async {}

  /// Google sign-in: set [googleOutcome] to `AuthCancelled()` / `AuthFailure(...)` to make it fail; otherwise it signs in.
  Exception? googleOutcome;
  String? googleName = 'Gita Google';
  int googleCalls = 0;
  @override
  Future<GoogleSignInResult> signInWithGoogle() async {
    googleCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (googleOutcome != null) throw googleOutcome!;
    _token = 'tok-1';
    _changes.add(true);
    return GoogleSignInResult(displayName: googleName);
  }

  /// Records password changes; `currentPassword` is what the "account" accepts, anything else fails like Supabase's re-authentication.
  String currentPassword = 'OldPass123';
  String? failChangeWith;
  final passwordChanges = <String>[];
  @override
  Future<void> changePassword({
    required String email,
    required String currentPassword,
    required String newPassword,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (failChangeWith != null) throw AuthFailure(failChangeWith!);
    if (currentPassword != this.currentPassword) {
      throw AuthFailure('Your current password is incorrect.');
    }
    this.currentPassword = newPassword;
    passwordChanges.add(newPassword);
  }

  @override
  Future<void> sendPhoneOtp(String phone) async {}
  @override
  Future<void> verifyPhoneOtp({
    required String phone,
    required String code,
  }) async {}

  /// Mimics gotrue when the server cannot be reached: the device session is removed first, then the revoke request throws.
  bool signOutThrows = false;

  @override
  Future<void> signOut() async {
    signedOut = true;
    _token = null;
    _changes.add(false);
    if (signOutThrows) throw Exception('network unreachable');
  }
}

typedef Responder = ResponseBody Function(RequestOptions o);

/// Dio adapter that answers from a function, recording every request.
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.responder);
  final Responder responder;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object? body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

Map<String, dynamic> meJson({
  String role = 'customer',
  String status = 'active',
}) => {
  'id': 'user-1',
  'email': 'asha@example.com',
  'phone': null,
  'role': role,
  'status': status,
  'profile': {
    'id': 'user-1',
    'full_name': 'Asha Rao',
    'role': role,
    'status': status,
  },
};
