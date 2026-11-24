import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class ServiceRepository {
  ServiceRepository(this._api);
  final ApiClient _api;

  Future<Paged<VendorService>> list(
    int page, {
    bool? isActive,
    String? q,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/vendor/services',
      query: {'is_active': isActive, 'q': q, 'page': page, 'limit': limit},
    ),
    VendorService.fromJson,
  );
  Future<VendorService> get(String id) async =>
      VendorService.fromJson(asMap(await _api.get('/vendor/services/$id')));
  Future<VendorService> create(ServiceInput s) async => VendorService.fromJson(
    asMap(await _api.post('/vendor/services', body: s.toJson())),
  );
  Future<VendorService> replace(
    String id,
    ServiceInput s, {
    required bool isActive,
  }) async => VendorService.fromJson(
    asMap(
      await _api.put(
        '/vendor/services/$id',
        body: {...s.toJson(), 'is_active': isActive},
      ),
    ),
  );
  Future<VendorService> patch(String id, Map<String, dynamic> changes) async =>
      VendorService.fromJson(
        asMap(await _api.patch('/vendor/services/$id', body: changes)),
      );
  Future<void> delete(String id) async => _api.delete('/vendor/services/$id');
  Future<List<ServiceCategory>> categories() async => asMapList(
    await _api.get('/service-categories', auth: false),
  ).map(ServiceCategory.fromJson).toList();
}
