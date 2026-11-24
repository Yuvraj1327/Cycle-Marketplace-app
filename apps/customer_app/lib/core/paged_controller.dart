import 'package:flutter/foundation.dart';

import 'api/api_exception.dart';
import 'models/paged.dart';

/// Pagination for list screens: the BACKEND decides what is on each page; this only appends pages and tracks loading/error/empty.
class PagedController<T> extends ChangeNotifier {
  PagedController(this._fetch);
  final Future<Paged<T>> Function(int page) _fetch;

  final List<T> items = [];
  int _page = 0;
  bool _hasMore = true, _loading = false, _disposed = false;
  int total = 0;
  ApiException? error;

  bool get loading => _loading;
  bool get hasMore => _hasMore;
  bool get isInitialLoading => _loading && items.isEmpty && error == null;
  bool get isEmpty => !_loading && error == null && items.isEmpty;

  Future<void> refresh() async {
    items.clear();
    _page = 0;
    _hasMore = true;
    error = null;
    await loadMore();
  }

  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    error = null;
    _notify();
    try {
      final res = await _fetch(_page + 1);
      _page = res.page;
      total = res.total;
      items.addAll(res.items);
      _hasMore = res.hasMore;
    } on ApiException catch (e) {
      error = e;
    } finally {
      _loading = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void removeWhere(bool Function(T) test) {
    items.removeWhere(test);
    _notify();
  }

  void replace(int index, T value) {
    items[index] = value;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
