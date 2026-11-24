import '../../core/utils/json.dart';
import '../orders/models.dart';

class DeliveryRule {
  const DeliveryRule({required this.amount, this.freeAbove, required this.per});
  final double amount;
  final double? freeAbove;
  final String per;
  factory DeliveryRule.fromJson(Map<String, dynamic> j) => DeliveryRule(
    amount: asDouble(j['amount']),
    freeAbove: asDoubleOrNull(j['free_above']),
    per: (j['per'] as String?) ?? 'order',
  );
}

class CheckoutOptions {
  const CheckoutOptions({
    required this.codEnabled,
    required this.onlineEnabled,
    required this.onlineProviderConfigured,
    required this.multiVendorAllowed,
    this.delivery,
  });
  final bool codEnabled,
      onlineEnabled,
      onlineProviderConfigured,
      multiVendorAllowed;
  final DeliveryRule? delivery;
  bool get anyPaymentMethod => codEnabled || onlineEnabled;
  factory CheckoutOptions.fromJson(dynamic json) {
    final j = asMap(json);
    return CheckoutOptions(
      codEnabled: j['cod_enabled'] == true,
      onlineEnabled: j['online_enabled'] == true,
      onlineProviderConfigured: j['online_provider_configured'] == true,
      multiVendorAllowed: j['multi_vendor_allowed'] == true,
      delivery: j['delivery_charge'] is Map
          ? DeliveryRule.fromJson(asMap(j['delivery_charge']))
          : null,
    );
  }
}

class PreviewVendor {
  const PreviewVendor({
    required this.vendorId,
    this.vendorName,
    required this.subtotal,
    required this.itemCount,
  });
  final String vendorId;
  final String? vendorName;
  final double subtotal;
  final int itemCount;
  factory PreviewVendor.fromJson(Map<String, dynamic> j) => PreviewVendor(
    vendorId: j['vendor_id'] as String,
    vendorName: asStringOrNull(j['vendor_name']),
    subtotal: asDouble(j['subtotal']),
    itemCount: asInt(j['item_count']),
  );
}

class CheckoutPreview {
  const CheckoutPreview({
    required this.subtotal,
    required this.deliveryCharge,
    required this.discount,
    required this.total,
    this.couponCode,
    required this.itemCount,
    required this.vendors,
  });
  final double subtotal, deliveryCharge, discount, total;
  final String? couponCode;
  final int itemCount;
  final List<PreviewVendor> vendors;
  factory CheckoutPreview.fromJson(dynamic json) {
    final j = asMap(json);
    return CheckoutPreview(
      subtotal: asDouble(j['subtotal']),
      deliveryCharge: asDouble(j['delivery_charge']),
      discount: asDouble(j['discount_amount']),
      total: asDouble(j['total_amount']),
      couponCode: asStringOrNull(j['coupon_code']),
      itemCount: asInt(j['item_count']),
      vendors: asMapList(j['vendors']).map(PreviewVendor.fromJson).toList(),
    );
  }
}

class CheckoutResult {
  const CheckoutResult({
    required this.order,
    required this.payment,
    this.clientPayload,
    required this.replay,
  });
  final OrderDetail order;
  final Payment payment;
  final Map<String, dynamic>? clientPayload;
  final bool replay;
  factory CheckoutResult.fromJson(dynamic json) {
    final j = asMap(json);
    return CheckoutResult(
      order: OrderDetail.fromJson(asMap(j['order'])),
      payment: Payment.fromJson(asMap(j['payment'])),
      clientPayload: j['client_payload'] is Map
          ? asMap(j['client_payload'])
          : null,
      replay: j['replay'] == true,
    );
  }
}
