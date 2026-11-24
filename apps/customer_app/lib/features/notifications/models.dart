import '../../core/utils/json.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    this.relatedType,
    this.relatedId,
    required this.isRead,
    this.createdAt,
  });
  final String id, type, title, message;
  final String? relatedType, relatedId;
  final bool isRead;
  final DateTime? createdAt;
  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: j['id'] as String,
    type: j['type'] as String,
    title: j['title'] as String,
    message: j['message'] as String,
    relatedType: asStringOrNull(j['related_type']),
    relatedId: asStringOrNull(j['related_id']),
    isRead: j['is_read'] == true,
    createdAt: asDate(j['created_at']),
  );
  AppNotification asRead() => AppNotification(
    id: id,
    type: type,
    title: title,
    message: message,
    relatedType: relatedType,
    relatedId: relatedId,
    isRead: true,
    createdAt: createdAt,
  );
}
