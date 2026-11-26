import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/authentication/models.dart';
import '../api/api_exception.dart';
import '../providers.dart';
import 'auth_service.dart';
import 'sign_out_hooks.dart';

enum AuthStatus { unknown, signedOut, signedIn, error }

class AuthState {
  const AuthState(this.status, {this.me, this.message});
  const AuthState.unknown() : this(AuthStatus.unknown);
  const AuthState.signedOut({String? message})
    : this(AuthStatus.signedOut, message: message);
  final AuthStatus status;
  final Me? me;

  /// Why the user was sent back to the login screen (wrong account type, expired session, ...).
  final String? message;
  bool get isSignedIn => status == AuthStatus.signedIn;
}

/// Single source of truth for "who is signed in". Supabase owns the session; the BACKEND decides the role/status via /auth/me.
class AuthController extends Notifier<AuthState> {
  StreamSubscription<bool>? _sub;
  bool _loading = false;
  Future<void>?
  _inFlight; // the running profile load, so Google sign-in can wait for it

  @override
  AuthState build() {
    final auth = ref.watch(authServiceProvider);
    _sub?.cancel();
    _sub = auth.signedInChanges.listen((signedIn) {
      if (signedIn && !state.isSignedIn) {
        _loadMe();
      } else if (!signedIn && state.status != AuthStatus.signedOut) {
        state = const AuthState.signedOut();
      }
    });
    ref.onDispose(() => _sub?.cancel());
    if (auth.isSignedIn) {
      Future.microtask(_loadMe);
      return const AuthState.unknown();
    }
    return const AuthState.signedOut();
  }

  Future<void> retry() async {
    state = const AuthState.unknown();
    await _loadMe();
  }

  Future<void> _loadMe() async {
    if (_loading) return;
    _loading = true;
    final done = Completer<void>();
    _inFlight = done.future;
    try {
      final me = await ref.read(authRepositoryProvider).me();
      if (!me.isCustomer) {
        await _signOutWith(
          'This app is for customers. Please use the ${me.role == 'vendor' ? 'Vendor' : 'Admin'} app for this account.',
        );
      } else if (!me.isActive) {
        await _signOutWith(
          'Your account is ${me.status}. Please contact support.',
        );
      } else {
        state = AuthState(AuthStatus.signedIn, me: me);
      }
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _signOutWith('Your session has expired. Please sign in again.');
      } else if (e.kind == ApiErrorKind.forbidden) {
        await _signOutWith(e.message);
      } else {
        state = AuthState(
          AuthStatus.error,
          message: e.message,
        ); // network/server problem: do NOT log the user out
      }
    } finally {
      _loading = false;
      done.complete();
    }
  }

  Future<void> _signOutWith(String message) async {
    await ref.read(authServiceProvider).signOut();
    state = AuthState.signedOut(message: message);
  }

  Future<void> signIn(String email, String password) async {
    await ref
        .read(authServiceProvider)
        .signInWithPassword(email: email, password: password);
    if (!state.isSignedIn) await _loadMe();
  }

  Future<void> signInWithPhoneCode(String phone, String code) async {
    await ref
        .read(authServiceProvider)
        .verifyPhoneOtp(phone: phone, code: code);
    if (!state.isSignedIn) await _loadMe();
  }

  /// Returns true if the user is signed in right away, false if the project requires e-mail confirmation first.
  Future<bool> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async {
    final result = await ref
        .read(authServiceProvider)
        .signUp(
          email: email,
          password: password,
          fullName: fullName,
          phone: phone,
        );
    if (result.signedIn) await _loadMe();
    return result.signedIn;
  }

  /// Google sign-in. Google only proves WHO the person is; the role/status gate is the same `/auth/me` check as a password sign-in,
  /// so a Google account of the wrong role is signed straight back out with a message. Cancelling throws [AuthCancelled].
  Future<void> signInWithGoogle() async {
    final google = await ref.read(authServiceProvider).signInWithGoogle();
    if (!state.isSignedIn) await _loadMe();
    await _inFlight; // the auth-state listener may already be loading the profile: wait for it
    final me = state.me;
    final name = google.displayName?.trim();
    if (state.isSignedIn &&
        me != null &&
        me.profile.fullName.trim().isEmpty &&
        name != null &&
        name.isNotEmpty) {
      // New Google accounts normally arrive with a name; if the provider did not supply one, fill the EMPTY profile name (best effort).
      try {
        await ref.read(profileRepositoryProvider).update(fullName: name);
        await refreshMe();
      } on ApiException {
        // the name can be added later from the profile screen
      }
    }
  }

  Future<void> signOut() async {
    await ref
        .read(signOutHooksProvider)
        .run(); // e.g. push unregistration: needs the session, so it runs first
    await ref.read(authRepositoryProvider).logout();
    try {
      await ref.read(authServiceProvider).signOut();
    } catch (_) {
      // gotrue removes the device session first and only then asks the server to revoke it; offline that request throws.
      // The user is signed out on this device either way.
    }
    state = const AuthState.signedOut();
  }

  /// Called by the API client when a request is still unauthorized after a token refresh.
  void sessionExpired() {
    if (state.status == AuthStatus.signedIn) {
      ref.read(authServiceProvider).signOut().catchError((Object _) {});
      state = const AuthState.signedOut(
        message: 'Your session has expired. Please sign in again.',
      );
    }
  }

  /// Re-read the profile after an edit.
  Future<void> refreshMe() async {
    try {
      final me = await ref.read(authRepositoryProvider).me();
      state = AuthState(AuthStatus.signedIn, me: me);
    } on ApiException {
      // keep the old profile; the edit screen shows its own error
    }
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.me?.id)),
);
