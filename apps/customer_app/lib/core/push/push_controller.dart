import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../features/notifications/providers.dart';
import '../api/api_client.dart';
import '../auth/auth_controller.dart';
import '../auth/sign_out_hooks.dart';
import '../providers.dart';
import 'notification_route.dart';
import 'push_service.dart';

/// Overridden in `main()` with [FirebasePushService] when Firebase is configured, and with a fake in tests.
final pushServiceProvider = Provider<PushService>(
  (ref) => const NoopPushService(),
);

/// Lets the push layer show an in-app banner from outside the widget tree.
final pushMessengerKey = GlobalKey<ScaffoldMessengerState>(
  debugLabel: 'push-messenger',
);

class PushRepository {
  PushRepository(this._api);
  final ApiClient _api;

  Future<void> register(String token) async {
    await _api.put(
      '/devices',
      body: {
        'token': token,
        'platform': _platform(),
        'app': pushAppName,
        if (appVersion.isNotEmpty) 'app_version': appVersion,
      },
    );
  }

  Future<void> unregister(String token) async {
    await _api.post('/devices/unregister', body: {'token': token});
  }

  static String _platform() {
    if (kIsWeb) return 'web';
    return Platform.isIOS ? 'ios' : 'android';
  }
}

final pushRepositoryProvider = Provider(
  (ref) => PushRepository(ref.watch(apiClientProvider)),
);

/// Connects the push service to the signed-in session:
///  * sign-in  -> ask permission, register this device's token with the backend (re-register when the token refreshes);
///  * foreground message -> refresh the unread badge and show an in-app banner;
///  * tap on a notification -> open the order / booking (after sign-in if the user was signed out);
///  * sign-out -> unregister the token (before the session is discarded) and invalidate it on the device.
/// Failures here never break the app: push is an extra channel, the in-app notification list is always the source of truth.
class PushController {
  PushController(this._ref) {
    final s = _ref.read(pushServiceProvider);
    _opened = s.opened.listen(_open);
    unawaited(s.initialMessage().then((m) => m == null ? null : _open(m)));
    _ref.listen<AuthState>(authControllerProvider, _onAuth);
    _ref.read(signOutHooksProvider).add(unregisterForSignOut);
    if (_ref.read(authControllerProvider).isSignedIn) unawaited(_enable());
    _ref.onDispose(_dispose);
  }

  final Ref _ref;
  StreamSubscription<PushPayload>? _opened, _foreground;
  StreamSubscription<String>? _refresh;
  String? _registered;
  String? pendingRoute;
  PushPermission? lastPermission;

  PushService get _service => _ref.read(pushServiceProvider);
  bool get isRegistered => _registered != null;

  void _onAuth(AuthState? prev, AuthState next) {
    final was = prev?.isSignedIn ?? false;
    if (next.isSignedIn && !was) {
      unawaited(_enable());
    } else if (!next.isSignedIn && was) {
      unawaited(_disable());
    }
    if (next.isSignedIn && pendingRoute != null) {
      final route = pendingRoute!;
      pendingRoute = null;
      scheduleMicrotask(() => _go(route));
    }
  }

  Future<void> _enable() async {
    final s = _service;
    if (!s.isAvailable) return;
    lastPermission = await s.requestPermission();
    if (lastPermission != PushPermission.granted) return; // denied: the in-app list still works
    final token = await s.token();
    if (token != null) await _register(token);
    _refresh?.cancel();
    _refresh = s.tokenRefreshes.listen((t) => unawaited(_register(t)));
    _foreground?.cancel();
    _foreground = s.foregroundMessages.listen(_onForeground);
  }

  Future<void> _register(String token) async {
    try {
      await _ref.read(pushRepositoryProvider).register(token);
      _registered = token;
    } catch (e) {
      debugPrint('Device registration failed (will retry on next sign-in or token refresh): $e');
    }
  }

  /// Explicit sign-out: tell the backend to stop pushing to this device BEFORE the session is discarded (the call needs the access token).
  Future<void> unregisterForSignOut() async {
    final token = _registered;
    if (token == null) return;
    try {
      await _ref
          .read(pushRepositoryProvider)
          .unregister(token)
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      /* offline / expired: deleting the token below still stops it */
    }
  }

  Future<void> _disable() async {
    unawaited(_refresh?.cancel());
    unawaited(_foreground?.cancel());
    _refresh = _foreground = null;
    _registered = null;
    await _service.deleteToken(); // the old user must stop receiving pushes on this phone as soon as possible
  }

  void _onForeground(PushPayload p) {
    _ref.invalidate(unreadCountProvider);
    final m = pushMessengerKey.currentState;
    if (m == null || (p.title ?? '').isEmpty) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(
          [p.title, p.body].where((e) => (e ?? '').isNotEmpty).join(': '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        action: SnackBarAction(label: 'View', onPressed: () => _open(p)),
      ),
    );
  }

  /// Tap on a notification. Signed in -> go to the record; otherwise remember where to go and continue after sign-in.
  void _open(PushPayload p) {
    final route =
        routeForNotification(relatedType: p.relatedType, relatedId: p.relatedId) ??
        '/notifications';
    if (_ref.read(authControllerProvider).isSignedIn) {
      _go(route);
    } else {
      pendingRoute = route;
    }
  }

  void _go(String route) {
    try {
      _ref.read(routerProvider).push(route);
    } catch (e) {
      debugPrint('Could not open $route from a notification: $e');
    }
  }

  void _dispose() {
    _opened?.cancel();
    _foreground?.cancel();
    _refresh?.cancel();
  }
}

/// Watched once by the app widget so the controller lives as long as the app.
final pushControllerProvider = Provider<PushController>(
  (ref) => PushController(ref),
);
