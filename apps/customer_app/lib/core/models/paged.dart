import '../utils/json.dart';

/// `{items, total, page, limit, pages}` as returned by every list endpoint.
class Paged<T> {
  const Paged({
    required this.items,
    required this.total,
    required this.page,
    required this.limit,
    required this.pages,
  });
  final List<T> items;
  final int total, page, limit, pages;
  bool get hasMore => page < pages;

  factory Paged.fromJson(dynamic json, T Function(Map<String, dynamic>) parse) {
    final m = asMap(json);
    return Paged(
      items: asMapList(m['items']).map(parse).toList(),
      total: asInt(m['total']),
      page: asInt(m['page'], 1),
      limit: asInt(m['limit'], 20),
      pages: asInt(m['pages']),
    );
  }
}
