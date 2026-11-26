import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/authentication/models.dart';
import '../../features/business_profile/models.dart';
import '../api/api_exception.dart';
import '../providers.dart';
import 'auth_service.dart';
import 'sign_out_hooks.dart';

enum AuthStatus { unknown, signedOut, signedIn, error }

/// Where a signed-in vendor stands. The BACKEND decides everything here: the app only reads it.
enum VendorStage { notRegistered, pending, approved, rejected, suspended }

class AuthState {
  const AuthState(this.status, {this.me, this.vendor, this.message});
  const AuthState.unknown() : this(AuthStatus.unknown);
  const AuthState.signedOut({String? message})
    : this(AuthStatus.signedOut, message: message);
  final AuthStatus status;
  final Me? me;
  final VendorProfile? vendor; // null => not registered yet
  final String? message;

  bool get isSignedIn => status == AuthStatus.signedIn;
  VendorStage get stage {
    final v = vendor;
    if (v == null) return VendorStage.notRegistered;
    if (v.isApproved) return VendorStage.approved;
    if (v.isRejected) return VendorStage.rejected;
    if (v.isSuspended) return VendorStage.suspended;
    return VendorStage.pending;
  }

  bool get canOperate => isSignedIn && stage == VendorStage.approved;
}

/// Single source of truth for "who is signed in and may they operate". Supabase owns the session; FastAPI decides role + verification.
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
        _load();
      } else if (!signedIn && state.status != AuthStatus.signedOut) {
        state = const AuthState.signedOut();
      }
    });
    ref.onDispose(() => _sub?.cancel());
    if (auth.isSignedIn) {
      Future.microtask(_load);
      return const AuthState.unknown();
    }
    return const AuthState.signedOut();
  }

  Future<void> retry() async {
    state = const AuthState.unknown();
    await _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final done = Completer<void>();
    _inFlight = done.future;
    try {
      final me = await ref.read(authRepositoryProvider).me();
      if (!me.isVendor) {
        await _signOutWith(
          'This app is for businesses. Please use the Customer app for this account.',
        );
        return;
      }
      if (!me.isActive) {
        await _signOutWith(
          'Your account is ${me.status}. Please contact support.',
        );
        return;
      }
      VendorProfile? vendor;
      try {
        vendor = await ref.read(vendorProfileRepositoryProvider).me();
      } on ApiException catch (e) {
        if (e.kind != ApiErrorKind.notFound &&
            e.code != 'vendor_not_registered') {
          rethrow;
        }
      }
      state = AuthState(AuthStatus.signedIn, me: me, vendor: vendor);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _signOutWith('Your session has expired. Please sign in again.');
      } else if (e.kind == ApiErrorKind.forbidden) {
        await _signOutWith(e.message);
      } else {
        state = AuthState(
          AuthStatus.error,
          message: e.message,
        ); // outage: do NOT log the vendor out
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
    if (!state.isSignedIn) await _load();
  }

  /// true => signed in immediately; false => the project requires e-mail confirmation first.
  Future<bool> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async {
    final r = await ref
        .read(authServiceProvider)
        .signUp(
          email: email,
          password: password,
          fullName: fullName,
          phone: phone,
        );
    if (r.signedIn) await _load();
    return r.signedIn;
  }

  /// Google sign-in. Google only proves WHO the person is; the role/status gate is the same `/auth/me` check as a password sign-in,
  /// so a Google account of the wrong role is signed straight back out with a message. Cancelling throws [AuthCancelled].
  Future<void> signInWithGoogle() async {
    final google = await ref.read(authServiceProvider).signInWithGoogle();
    if (!state.isSignedIn) await _load();
    await _inFlight; // the auth-state listener may already be loading the profile: wait for it
    final me = state.me;
    final name = google.displayName?.trim();
    if (state.isSignedIn &&
        me != null &&
        me.fullName.trim().isEmpty &&
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

  /// The API client calls this when a request is still unauthorized after one token refresh.
  void sessionExpired() {
    if (state.status == AuthStatus.signedIn) {
      ref.read(authServiceProvider).signOut().catchError((Object _) {});
      state = const AuthState.signedOut(
        message: 'Your session has expired. Please sign in again.',
      );
    }
  }

  /// Re-read the vendor profile/verification after registering, editing, or "check status".
  Future<void> refreshVendor() async {
    final me = state.me;
    if (me == null) return;
    try {
      final v = await ref.read(vendorProfileRepositoryProvider).me();
      state = AuthState(AuthStatus.signedIn, me: me, vendor: v);
    } on ApiException catch (e) {
      if (e.isUnauthorized) sessionExpired();
    }
  }

  /// Re-read the account (name, phone, picture) after an edit, keeping the business profile as it is.
  Future<void> refreshMe() async {
    final current = state;
    if (current.me == null) return;
    try {
      final me = await ref.read(authRepositoryProvider).me();
      state = AuthState(AuthStatus.signedIn, me: me, vendor: current.vendor);
    } on ApiException catch (e) {
      if (e.isUnauthorized) sessionExpired();
      // otherwise keep the old values; the edit screen shows its own error
    }
  }

  void setVendor(VendorProfile v) {
    final me = state.me;
    if (me != null) state = AuthState(AuthStatus.signedIn, me: me, vendor: v);
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
