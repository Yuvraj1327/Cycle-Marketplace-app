import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class ServiceRepository {
  ServiceRepository(this._api);
  final ApiClient _api;

  Future<List<ServiceCategory>> categories() async => asMapList(
    await _api.get('/service-categories', auth: false),
  ).map(ServiceCategory.fromJson).toList();

  Future<Paged<ServiceItem>> services(
    int page, {
    String? categoryId,
    String? vendorId,
    String? q,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/services',
      query: {
        'category_id': categoryId,
        'vendor_id': vendorId,
        'q': q,
        'page': page,
        'limit': limit,
      },
      auth: false,
    ),
    ServiceItem.fromJson,
  );

  Future<ServiceItem> service(String id) async =>
      ServiceItem.fromJson(asMap(await _api.get('/services/$id', auth: false)));

  /// Slots for one date from the backend (opening hours, capacity, existing accepted bookings). The app never invents availability.
  Future<Availability> availability(String serviceId, String isoDate) async =>
      Availability.fromJson(
        await _api.get(
          '/services/$serviceId/availability',
          query: {'date': isoDate},
          auth: false,
        ),
      );

  Future<BookingOptions> bookingOptions() async =>
      BookingOptions.fromJson(await _api.get('/service-bookings/options'));
}
