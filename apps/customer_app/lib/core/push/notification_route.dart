import '../../app/config.dart';

/// Which app this build is; the backend checks it against the account's role when a device is registered.
const pushAppName = 'customer';

/// App version sent with the device registration (optional, for support).
String get appVersion => AppConfig.appVersion;

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Maps a notification's record reference to a screen of THIS app, or null (= open the notification list). Only well-formed ids are accepted, so a crafted
/// push can never build an arbitrary path. The screen itself loads the record through the backend, which refuses records that are not the user's own.
String? routeForNotification({String? relatedType, String? relatedId}) {
  if (relatedType == null || relatedId == null || !_uuid.hasMatch(relatedId)) {
    return null;
  }
  return switch (relatedType) {
    'order' => '/orders/$relatedId',
    'service_booking' => '/bookings/$relatedId',
    _ => null,
  };
}
