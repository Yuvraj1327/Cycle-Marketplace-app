import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import '../orders/models.dart' show TimelineEvent;
import 'models.dart';

class ServiceBookingRepository {
  ServiceBookingRepository(this._api);
  final ApiClient _api;

  VendorBooking _d(dynamic r) =>
      VendorBooking.fromJson(asMap(r), withDetail: true);

  Future<Paged<VendorBooking>> list(
    int page, {
    String? status,
    String? q,
    String? dateFrom,
    String? dateTo,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/vendor/service-bookings',
      query: {
        'status': status,
        'q': q,
        'date_from': dateFrom,
        'date_to': dateTo,
        'page': page,
        'limit': limit,
      },
    ),
    VendorBooking.fromJson,
  );
  Future<VendorBooking> detail(String id) async =>
      _d(await _api.get('/vendor/service-bookings/$id'));
  Future<List<TimelineEvent>> timeline(String id) async => asMapList(
    await _api.get('/vendor/service-bookings/$id/timeline'),
  ).map(TimelineEvent.fromJson).toList();
  Future<VendorBooking> accept(
    String id, {
    String? confirmedDate,
    String? slotStart,
    String? note,
  }) async => _d(
    await _api.post(
      '/vendor/service-bookings/$id/accept',
      body: {
        'confirmed_date': ?confirmedDate,
        'slot_start': ?slotStart,
        if ((note ?? '').isNotEmpty) 'note': note,
      },
    ),
  );
  Future<VendorBooking> reject(String id, String reason) async => _d(
    await _api.post(
      '/vendor/service-bookings/$id/reject',
      body: {'reason': reason},
    ),
  );
  Future<VendorBooking> updateStatus(
    String id,
    String status, {
    String? note,
  }) async => _d(
    await _api.patch(
      '/vendor/service-bookings/$id/status',
      body: {'status': status, if ((note ?? '').isNotEmpty) 'note': note},
    ),
  );
  Future<VendorBooking> reschedule(
    String id,
    String date,
    String slotStart, {
    String? note,
  }) async => _d(
    await _api.put(
      '/vendor/service-bookings/$id/schedule',
      body: {
        'confirmed_date': date,
        'slot_start': slotStart,
        if ((note ?? '').isNotEmpty) 'note': note,
      },
    ),
  );
  Future<VendorBooking> addCharge(
    String id,
    double amount,
    String reason,
  ) async => _d(
    await _api.post(
      '/vendor/service-bookings/$id/charges',
      body: {'amount': amount, 'reason': reason},
    ),
  );
  Future<VendorBooking> addNote(String id, String note) async => _d(
    await _api.post('/vendor/service-bookings/$id/notes', body: {'note': note}),
  );
}
