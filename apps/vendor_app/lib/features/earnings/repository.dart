import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class DashboardRepository {
  DashboardRepository(this._api);
  final ApiClient _api;
  Future<Dashboard> summary() async =>
      Dashboard.fromJson(asMap(await _api.get('/vendor/dashboard')));
}

class EarningsRepository {
  EarningsRepository(this._api);
  final ApiClient _api;
  Future<Paged<Settlement>> settlements(
    int page, {
    String? status,
    String? dateFrom,
    String? dateTo,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/vendor/settlements',
      query: {
        'status': status,
        'date_from': dateFrom,
        'date_to': dateTo,
        'page': page,
        'limit': limit,
      },
    ),
    Settlement.fromJson,
  );
}
