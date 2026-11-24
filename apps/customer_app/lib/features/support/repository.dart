import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class SupportRepository {
  SupportRepository(this._api);
  final ApiClient _api;

  Future<Paged<Ticket>> list(int page) async => Paged.fromJson(
    await _api.get('/support-tickets', query: {'page': page, 'limit': 20}),
    Ticket.fromJson,
  );
  Future<Ticket> get(String id) async =>
      Ticket.fromJson(asMap(await _api.get('/support-tickets/$id')));
  Future<Ticket> create({
    required String type,
    required String subject,
    required String description,
    String? bookingId,
    String? orderId,
  }) async => Ticket.fromJson(
    asMap(
      await _api.post(
        '/support-tickets',
        body: {
          'type': type,
          'subject': subject,
          'description': description,
          'service_booking_id': ?bookingId,
          'order_id': ?orderId,
        },
      ),
    ),
  );
}
