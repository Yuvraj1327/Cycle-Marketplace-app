import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class BookingRepository {
  BookingRepository(this._api);
  final ApiClient _api;

  Future<BookingDetail> create(BookingRequest r) async =>
      BookingDetail.fromJson(
        await _api.post('/service-bookings', body: r.toJson()),
      );
  Future<Paged<BookingSummary>> list(
    int page, {
    String? status,
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/service-bookings',
      query: {'status': status, 'page': page, 'limit': limit},
    ),
    BookingSummary.fromJson,
  );
  Future<BookingDetail> detail(String id) async =>
      BookingDetail.fromJson(await _api.get('/service-bookings/$id'));
  Future<BookingTracking> tracking(String id) async => BookingTracking.fromJson(
    await _api.get('/service-bookings/$id/tracking'),
  );
  Future<BookingDetail> cancel(String id, String reason) async =>
      BookingDetail.fromJson(
        await _api.post(
          '/service-bookings/$id/cancel',
          body: {'reason': reason},
        ),
      );

  /// After the photo was uploaded to Storage, register its path with the booking (the backend verifies the file exists).
  Future<BookingImage> registerImage(
    String bookingId,
    String storagePath,
  ) async => BookingImage.fromJson(
    asMap(
      await _api.post(
        '/service-bookings/$bookingId/images',
        body: {'storage_path': storagePath},
      ),
    ),
  );
  Future<void> removeImage(String bookingId, String imageId) async =>
      _api.delete('/service-bookings/$bookingId/images/$imageId');
}
