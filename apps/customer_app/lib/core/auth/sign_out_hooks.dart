import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Things that must happen while the session is STILL valid, right before an explicit sign-out (e.g. telling the backend to stop pushing to this phone).
/// A tiny registry so the auth controller does not depend on those features (they depend on auth, so a direct reference would be circular).
class SignOutHooks {
  final _hooks = <Future<void> Function()>[];

  void add(Future<void> Function() hook) => _hooks.add(hook);

  /// Runs every hook; a failing hook never prevents signing out.
  Future<void> run() async {
    for (final h in _hooks) {
      try {
        await h();
      } catch (_) {
        /* signing out must always work */
      }
    }
  }
}

final signOutHooksProvider = Provider<SignOutHooks>((ref) => SignOutHooks());
