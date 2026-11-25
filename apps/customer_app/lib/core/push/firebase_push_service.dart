import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../app/config.dart';
import 'push_service.dart';

/// Required by Firebase: runs in its own isolate when a message arrives while the app is not running. The system shows the notification itself (the backend sends
/// a `notification` payload), so there is nothing to do here.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {}

/// Firebase Cloud Messaging implementation. Initialised from `--dart-define` values (no `google-services.json` is committed or required), so the same code
/// ships in every build and simply stays off until the client's Firebase project values are supplied.
///
/// Token API note: firebase_messaging 17 deprecates getToken / onTokenRefresh / deleteToken in favour of register() / onRegistered, which yield a Firebase
/// INSTALLATION ID for "direct-send". The backend sends through the documented FCM v1 `token` field, whose behaviour with an installation id cannot be confirmed
/// without a real Firebase project, so this class deliberately keeps the documented registration-token calls (still fully supported in 17.x). Revisit when
/// credentials are available and the new flow can be verified end to end.
///
/// NOT VERIFIED AGAINST A LIVE FIREBASE PROJECT: none exists yet. Everything that uses [PushService] is tested with a fake; this class is only compiled and analysed.
class FirebasePushService implements PushService {
  FirebasePushService._(this._fm);

  final FirebaseMessaging _fm;

  /// Returns null (push disabled) when the Firebase values are missing or initialisation fails: push must never stop the app from starting.
  static Future<FirebasePushService?> create() async {
    if (!AppConfig.firebaseConfigured) return null;
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: AppConfig.firebaseApiKey,
          appId: AppConfig.firebaseAppId,
          messagingSenderId: AppConfig.firebaseMessagingSenderId,
          projectId: AppConfig.firebaseProjectId,
        ),
      );
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
      return FirebasePushService._(FirebaseMessaging.instance);
    } catch (e, st) {
      debugPrint('Firebase initialisation failed; push is disabled: $e\n$st');
      return null;
    }
  }

  PushPayload _payload(RemoteMessage m) => PushPayload.fromData(
    m.data,
    title: m.notification?.title,
    body: m.notification?.body,
  );

  @override
  bool get isAvailable => true;

  @override
  Future<PushPermission> requestPermission() async {
    try {
      final s = await _fm.requestPermission();
      return switch (s.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => PushPermission.granted,
        _ => PushPermission.denied,
      };
    } catch (_) {
      return PushPermission.unavailable;
    }
  }

  @override
  Future<String?> token() async {
    try {
      // ignore: deprecated_member_use
      return await _fm.getToken();
    } catch (_) {
      return null; // e.g. no Google Play services: the in-app list still works
    }
  }

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefreshes => _fm.onTokenRefresh;
  @override
  Stream<PushPayload> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(_payload);
  @override
  Stream<PushPayload> get opened =>
      FirebaseMessaging.onMessageOpenedApp.map(_payload);
  @override
  Future<PushPayload?> initialMessage() async {
    final m = await _fm.getInitialMessage();
    return m == null ? null : _payload(m);
  }

  @override
  Future<void> deleteToken() async {
    try {
      // ignore: deprecated_member_use
      await _fm.deleteToken();
    } catch (_) {
      /* best effort: the backend also unregisters the token explicitly */
    }
  }
}
