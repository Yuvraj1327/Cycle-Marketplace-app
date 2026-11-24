import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class PickupDropoffRepository {
  PickupDropoffRepository(this._api);
  final ApiClient _api;

  Future<Paged<PickupRequest>> list(
    int page, {
    String? pickupStatus,
    String? deliveryStatus,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/vendor/pickup-requests',
      query: {
        'pickup_status': pickupStatus,
        'delivery_status': deliveryStatus,
        'page': page,
        'limit': limit,
      },
    ),
    PickupRequest.fromJson,
  );
  Future<PickupRequest> get(String id) async => PickupRequest.fromJson(
    asMap(await _api.get('/vendor/pickup-requests/$id')),
  );

  /// Coordination only (schedule / mark an attempt failed / cancel / note). Completion is recorded through the BOOKING status.
  Future<PickupRequest> coordinate(
    String id, {
    DateTime? pickupAt,
    DateTime? deliveryAt,
    String? pickupStatus,
    String? deliveryStatus,
    String? notes,
  }) async => PickupRequest.fromJson(
    asMap(
      await _api.patch(
        '/vendor/pickup-requests/$id',
        body: {
          if (pickupAt != null)
            'scheduled_pickup_at': pickupAt.toUtc().toIso8601String(),
          if (deliveryAt != null)
            'scheduled_delivery_at': deliveryAt.toUtc().toIso8601String(),
          'pickup_status': ?pickupStatus,
          'delivery_status': ?deliveryStatus,
          if ((notes ?? '').isNotEmpty) 'notes': notes,
        },
      ),
    ),
  );
}
