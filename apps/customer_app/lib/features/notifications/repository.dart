import '../../core/api/api_client.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class NotificationPage {
  const NotificationPage({
    required this.items,
    required this.unreadCount,
    required this.page,
    required this.pages,
  });
  final List<AppNotification> items;
  final int unreadCount, page, pages;
  bool get hasMore => page < pages;
}

class NotificationRepository {
  NotificationRepository(this._api);
  final ApiClient _api;

  Future<NotificationPage> list(
    int page, {
    bool unreadOnly = false,
    int limit = 20,
  }) async {
    final j = asMap(
      await _api.get(
        '/notifications',
        query: {
          'page': page,
          'limit': limit,
          'unread_only': unreadOnly ? true : null,
        },
      ),
    );
    return NotificationPage(
      items: asMapList(j['items']).map(AppNotification.fromJson).toList(),
      unreadCount: asInt(j['unread_count']),
      page: asInt(j['page'], 1),
      pages: asInt(j['pages']),
    );
  }

  Future<int> unreadCount() async => (await list(1, limit: 1)).unreadCount;
  Future<void> markRead(String id) async =>
      _api.post('/notifications/$id/read');
  Future<void> markAllRead() async => _api.post('/notifications/read-all');
}
