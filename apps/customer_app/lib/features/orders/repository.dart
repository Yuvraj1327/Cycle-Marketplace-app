import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class OrderRepository {
  OrderRepository(this._api);
  final ApiClient _api;

  Future<Paged<OrderSummary>> list(
    int page, {
    String? status,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/orders',
      query: {'status': status, 'page': page, 'limit': limit},
    ),
    OrderSummary.fromJson,
  );
  Future<OrderDetail> detail(String id) async =>
      OrderDetail.fromJson(asMap(await _api.get('/orders/$id')));
  Future<OrderTracking> tracking(String id) async =>
      OrderTracking.fromJson(await _api.get('/orders/$id/tracking'));
  Future<OrderDetail> cancel(String id, String reason) async =>
      OrderDetail.fromJson(
        asMap(await _api.post('/orders/$id/cancel', body: {'reason': reason})),
      );
  Future<List<Payment>> payments(String id) async => asMapList(
    await _api.get('/orders/$id/payment'),
  ).map(Payment.fromJson).toList();
}
