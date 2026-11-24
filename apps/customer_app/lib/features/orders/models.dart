import '../../core/utils/json.dart';

class OrderItem {
  const OrderItem({
    required this.id,
    required this.name,
    this.brand,
    this.model,
    this.imageUrl,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
  });
  final String id, name;
  final String? brand, model, imageUrl;
  final double unitPrice, lineTotal;
  final int quantity;
  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
    id: j['id'] as String,
    name: j['product_name'] as String,
    brand: asStringOrNull(j['product_brand']),
    model: asStringOrNull(j['product_model']),
    imageUrl: asStringOrNull(j['image_url']),
    unitPrice: asDouble(j['unit_price']),
    quantity: asInt(j['quantity']),
    lineTotal: asDouble(j['line_total']),
  );
}

class VendorOrder {
  const VendorOrder({
    required this.id,
    required this.number,
    this.vendorName,
    required this.status,
    required this.total,
    this.rejectionReason,
    this.cancellationReason,
    required this.items,
  });
  final String id, number, status;
  final String? vendorName, rejectionReason, cancellationReason;
  final double total;
  final List<OrderItem> items;
  factory VendorOrder.fromJson(Map<String, dynamic> j) => VendorOrder(
    id: j['id'] as String,
    number: j['vendor_order_number'] as String,
    vendorName: asStringOrNull(j['vendor_name']),
    status: j['status'] as String,
    total: asDouble(j['total_amount']),
    rejectionReason: asStringOrNull(j['rejection_reason']),
    cancellationReason: asStringOrNull(j['cancellation_reason']),
    items: asMapList(j['items']).map(OrderItem.fromJson).toList(),
  );
}

class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.paymentMethod,
    required this.paymentStatus,
    required this.total,
    required this.itemCount,
    required this.vendorCount,
    required this.createdAt,
    this.cancelledReason,
  });
  final String id, number, status, paymentMethod, paymentStatus;
  final double total;
  final int itemCount, vendorCount;
  final DateTime? createdAt;
  final String? cancelledReason;
  factory OrderSummary.fromJson(Map<String, dynamic> j) => OrderSummary(
    id: j['id'] as String,
    number: j['order_number'] as String,
    status: j['status'] as String,
    paymentMethod: j['payment_method'] as String,
    paymentStatus: j['payment_status'] as String,
    total: asDouble(j['total_amount']),
    itemCount: asInt(j['item_count']),
    vendorCount: asInt(j['vendor_count']),
    createdAt: asDate(j['created_at']),
    cancelledReason: asStringOrNull(j['cancelled_reason']),
  );
}

class OrderDetail {
  const OrderDetail({
    required this.summary,
    required this.subtotal,
    required this.deliveryCharge,
    required this.discount,
    required this.address,
    this.couponCode,
    this.note,
    this.paymentDueAt,
    this.cancelledAt,
    required this.canCancel,
    required this.vendorOrders,
  });
  final OrderSummary summary;
  final double subtotal, deliveryCharge, discount;
  final Map<String, dynamic> address;
  final String? couponCode, note;
  final DateTime? paymentDueAt, cancelledAt;
  final bool canCancel;
  final List<VendorOrder> vendorOrders;

  factory OrderDetail.fromJson(Map<String, dynamic> j) => OrderDetail(
    summary: OrderSummary.fromJson(j),
    subtotal: asDouble(j['subtotal']),
    deliveryCharge: asDouble(j['delivery_charge']),
    discount: asDouble(j['discount_amount']),
    address: asMap(j['delivery_address']),
    couponCode: asStringOrNull(j['coupon_code']),
    note: asStringOrNull(j['customer_note']),
    paymentDueAt: asDate(j['payment_due_at']),
    cancelledAt: asDate(j['cancelled_at']),
    canCancel: j['can_cancel'] == true,
    vendorOrders: asMapList(
      j['vendor_orders'],
    ).map(VendorOrder.fromJson).toList(),
  );

  String get addressText {
    final a = address;
    return [
      a['recipient_name'],
      a['address_line1'],
      a['address_line2'],
      a['city'],
      '${a['state'] ?? ''} ${a['postal_code'] ?? ''}'.trim(),
    ].where((e) => e != null && '$e'.isNotEmpty).join(', ');
  }
}

class TimelineEvent {
  const TimelineEvent({
    required this.at,
    required this.scope,
    this.vendorName,
    this.fromStatus,
    required this.toStatus,
    this.note,
  });
  final DateTime? at;
  final String scope, toStatus;
  final String? vendorName, fromStatus, note;
  factory TimelineEvent.fromJson(Map<String, dynamic> j) => TimelineEvent(
    at: asDate(j['at']),
    scope: (j['scope'] as String?) ?? 'order',
    vendorName: asStringOrNull(j['vendor_name']),
    fromStatus: asStringOrNull(j['from_status']),
    toStatus: j['to_status'] as String,
    note: asStringOrNull(j['note']),
  );
}

class OrderTracking {
  const OrderTracking({
    required this.status,
    required this.paymentStatus,
    required this.vendorOrders,
    required this.timeline,
  });
  final String status, paymentStatus;
  final List<Map<String, dynamic>> vendorOrders;
  final List<TimelineEvent> timeline;
  factory OrderTracking.fromJson(dynamic json) {
    final j = asMap(json);
    return OrderTracking(
      status: j['status'] as String,
      paymentStatus: j['payment_status'] as String,
      vendorOrders: asMapList(j['vendor_orders']),
      timeline: asMapList(j['timeline']).map(TimelineEvent.fromJson).toList(),
    );
  }
}

class Payment {
  const Payment({
    required this.id,
    required this.method,
    required this.status,
    required this.amount,
    required this.amountDue,
    required this.refundedAmount,
    this.paidAt,
    this.failureReason,
    this.provider,
  });
  final String id, method, status;
  final String? provider, failureReason;
  final double amount, amountDue, refundedAmount;
  final DateTime? paidAt;
  factory Payment.fromJsonSafe(Map<String, dynamic> j) => Payment.fromJson(j);
  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
    id: j['id'] as String,
    method: j['method'] as String,
    status: j['status'] as String,
    provider: asStringOrNull(j['provider']),
    amount: asDouble(j['amount']),
    amountDue: asDouble(j['amount_due']),
    refundedAmount: asDouble(j['refunded_amount']),
    paidAt: asDate(j['paid_at']),
    failureReason: asStringOrNull(j['failure_reason']),
  );
}
