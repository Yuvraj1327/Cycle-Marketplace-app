import 'dart:async';

/// What a push message carries: the user's own notification text plus IDS only. Anything detailed is fetched from the backend after the user is signed in,
/// where the backend decides whether this user may see that order / booking.
class PushPayload {
  const PushPayload({
    this.notificationId,
    this.type,
    this.relatedType,
    this.relatedId,
    this.title,
    this.body,
  });
  final String? notificationId, type, relatedType, relatedId, title, body;

  factory PushPayload.fromData(
    Map<String, dynamic> data, {
    String? title,
    String? body,
  }) => PushPayload(
    notificationId: data['notification_id']?.toString(),
    type: data['type']?.toString(),
    relatedType: data['related_type']?.toString(),
    relatedId: data['related_id']?.toString(),
    title: title,
    body: body,
  );
}

enum PushPermission { granted, denied, unavailable }

/// The only thing the rest of the app knows about push. The real implementation uses Firebase Cloud Messaging; tests use a fake; while no Firebase project is
/// configured [NoopPushService] is used and the app works exactly as before (in-app notifications only).
abstract class PushService {
  /// False while Firebase is not configured for this build.
  bool get isAvailable;
  Future<PushPermission> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefreshes;

  /// A message that arrived while the app is in the foreground.
  Stream<PushPayload> get foregroundMessages;

  /// The user tapped a notification while the app was in the background.
  Stream<PushPayload> get opened;

  /// The user tapped a notification that launched the app from a terminated state.
  Future<PushPayload?> initialMessage();

  /// Invalidates this device's token, so a signed-out phone stops receiving the previous user's notifications.
  Future<void> deleteToken();
}

class NoopPushService implements PushService {
  const NoopPushService();
  @override
  bool get isAvailable => false;
  @override
  Future<PushPermission> requestPermission() async =>
      PushPermission.unavailable;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefreshes => const Stream.empty();
  @override
  Stream<PushPayload> get foregroundMessages => const Stream.empty();
  @override
  Stream<PushPayload> get opened => const Stream.empty();
  @override
  Future<PushPayload?> initialMessage() async => null;
  @override
  Future<void> deleteToken() async {}
}
