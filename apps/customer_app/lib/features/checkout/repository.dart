import '../../core/api/api_client.dart';
import '../../core/utils/json.dart';
import '../orders/models.dart';
import 'models.dart';

class CheckoutRepository {
  CheckoutRepository(this._api);
  final ApiClient _api;

  Future<CheckoutOptions> options() async =>
      CheckoutOptions.fromJson(await _api.get('/checkout/options'));

  static Map<String, dynamic> body({
    required String addressId,
    required String method,
    String? coupon,
    String? note,
    String? vendorId,
    bool acceptPriceChanges = false,
  }) => {
    'delivery_address_id': addressId,
    'payment_method': method,
    if (coupon != null && coupon.isNotEmpty) 'coupon_code': coupon,
    if (note != null && note.isNotEmpty) 'customer_note': note,
    'vendor_id': ?vendorId,
    if (acceptPriceChanges) 'accept_price_changes': true,
  };

  /// Totals computed by the backend for the current cart. Nothing is created.
  Future<CheckoutPreview> preview(Map<String, dynamic> body) async =>
      CheckoutPreview.fromJson(
        await _api.post('/checkout/preview', body: body),
      );

  /// `idempotencyKey` makes retries safe: the same key + same body can never create a second order.
  Future<CheckoutResult> place(
    Map<String, dynamic> body,
    String idempotencyKey,
  ) async => CheckoutResult.fromJson(
    await _api.post(
      '/checkout',
      body: body,
      headers: {'Idempotency-Key': idempotencyKey},
    ),
  );
}

class PaymentRepository {
  PaymentRepository(this._api);
  final ApiClient _api;

  Future<Payment> get(String id) async =>
      Payment.fromJson(asMap(await _api.get('/payments/$id')));

  /// (Re)start an online payment for an unpaid order. Returns the provider's public checkout payload.
  Future<Map<String, dynamic>> start(String orderId) async =>
      asMap(await _api.post('/payments/create', body: {'order_id': orderId}));
}
