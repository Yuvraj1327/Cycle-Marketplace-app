import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class OrderRepository {
  OrderRepository(this._api);
  final ApiClient _api;

  Future<Paged<VendorOrder>> list(
    int page, {
    String? status,
    String? dateFrom,
    String? dateTo,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/vendor/orders',
      query: {
        'status': status,
        'date_from': dateFrom,
        'date_to': dateTo,
        'page': page,
        'limit': limit,
      },
    ),
    VendorOrder.fromJson,
  );
  Future<VendorOrder> detail(String id) async => VendorOrder.fromJson(
    asMap(await _api.get('/vendor/orders/$id')),
    withDetail: true,
  );
  Future<List<TimelineEvent>> timeline(String id) async => asMapList(
    await _api.get('/vendor/orders/$id/timeline'),
  ).map(TimelineEvent.fromJson).toList();

  Future<VendorOrder> accept(String id, {String? note}) async =>
      VendorOrder.fromJson(
        asMap(
          await _api.post(
            '/vendor/orders/$id/accept',
            body: note == null || note.isEmpty ? null : {'note': note},
          ),
        ),
        withDetail: true,
      );
  Future<VendorOrder> reject(String id, String reason) async =>
      VendorOrder.fromJson(
        asMap(
          await _api.post(
            '/vendor/orders/$id/reject',
            body: {'reason': reason},
          ),
        ),
        withDetail: true,
      );
  Future<VendorOrder> updateStatus(
    String id,
    String status, {
    String? note,
  }) async => VendorOrder.fromJson(
    asMap(
      await _api.patch(
        '/vendor/orders/$id/status',
        body: {'status': status, if ((note ?? '').isNotEmpty) 'note': note},
      ),
    ),
    withDetail: true,
  );
}
