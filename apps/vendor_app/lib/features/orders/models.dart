import '../../core/utils/json.dart';

/// Backend vendor-order statuses. Labels follow the client's wording: preparing = processing, out_for_delivery = shipped.
const vendorOrderStatusLabels = {
  'pending': 'New',
  'accepted': 'Accepted',
  'preparing': 'Processing',
  'ready_for_dispatch': 'Ready for dispatch',
  'out_for_delivery': 'Shipped',
  'delivered': 'Completed',
  'rejected': 'Rejected',
  'cancelled': 'Cancelled',
};

/// The ONLY forward steps the backend accepts (it refuses anything else with 409). The app offers just the next valid step(s).
const nextOrderSteps = {
  'accepted': ['preparing'],
  'preparing': ['ready_for_dispatch'],
  'ready_for_dispatch': ['out_for_delivery', 'delivered'],
  'out_for_delivery': ['delivered'],
};

class OrderItem {
  const OrderItem({
    required this.id,
    required this.name,
    this.brand,
    this.model,
    this.condition,
    this.imageUrl,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
  });
  final String id, name;
  final String? brand, model, condition, imageUrl;
  final double unitPrice, lineTotal;
  final int quantity;
  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
    id: j['id'] as String,
    name: (j['product_name'] as String?) ?? '',
    brand: asStringOrNull(j['product_brand']),
    model: asStringOrNull(j['product_model']),
    condition: asStringOrNull(j['product_condition']),
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
    required this.orderId,
    required this.orderNumber,
    required this.status,
    required this.paymentMethod,
    required this.paymentStatus,
    required this.subtotal,
    required this.total,
    this.commission,
    required this.itemCount,
    this.placedAt,
    this.detail,
  });
  final String id,
      number,
      orderId,
      orderNumber,
      status,
      paymentMethod,
      paymentStatus;
  final double subtotal, total;
  final double? commission;
  final int itemCount;
  final DateTime? placedAt;
  final VendorOrderDetail? detail; // only on the detail endpoint

  bool get isNew => status == 'pending';
  List<String> get nextSteps => nextOrderSteps[status] ?? const [];
  bool get canCancel =>
      !const {'pending', 'rejected', 'cancelled', 'delivered'}.contains(status);

  factory VendorOrder.fromJson(
    Map<String, dynamic> j, {
    bool withDetail = false,
  }) => VendorOrder(
    id: j['id'] as String,
    number: (j['vendor_order_number'] as String?) ?? '',
    orderId: (j['order_id'] as String?) ?? '',
    orderNumber: (j['order_number'] as String?) ?? '',
    status: (j['status'] as String?) ?? 'pending',
    paymentMethod: (j['payment_method'] as String?) ?? '',
    paymentStatus: (j['payment_status'] as String?) ?? '',
    subtotal: asDouble(j['subtotal']),
    total: asDouble(j['total_amount']),
    commission: asDoubleOrNull(j['commission_amount']),
    itemCount: asInt(j['item_count']),
    placedAt: asDate(j['placed_at']),
    detail: withDetail ? VendorOrderDetail.fromJson(j) : null,
  );
}

class VendorOrderDetail {
  const VendorOrderDetail({
    required this.deliveryCharge,
    required this.discount,
    required this.netPayable,
    required this.address,
    this.customerNote,
    this.vendorNote,
    this.rejectionReason,
    this.cancellationReason,
    this.acceptedAt,
    this.deliveredAt,
    required this.items,
  });
  final double deliveryCharge, discount, netPayable;
  final Map<String, dynamic> address;
  final String? customerNote, vendorNote, rejectionReason, cancellationReason;
  final DateTime? acceptedAt, deliveredAt;
  final List<OrderItem> items;

  String get recipient => (address['recipient_name'] ?? '').toString();
  String get phone => (address['phone'] ?? '').toString();
  String get addressText => [
    address['address_line1'],
    address['address_line2'],
    address['landmark'],
    address['city'],
    '${address['state'] ?? ''} ${address['postal_code'] ?? ''}'.trim(),
  ].where((e) => e != null && '$e'.trim().isNotEmpty).join(', ');

  factory VendorOrderDetail.fromJson(Map<String, dynamic> j) =>
      VendorOrderDetail(
        deliveryCharge: asDouble(j['delivery_charge']),
        discount: asDouble(j['discount_amount']),
        netPayable: asDouble(j['net_payable']),
        address: asMap(j['delivery_address']),
        customerNote: asStringOrNull(j['customer_note']),
        vendorNote: asStringOrNull(j['vendor_note']),
        rejectionReason: asStringOrNull(j['rejection_reason']),
        cancellationReason: asStringOrNull(j['cancellation_reason']),
        acceptedAt: asDate(j['accepted_at']),
        deliveredAt: asDate(j['delivered_at']),
        items: asMapList(j['items']).map(OrderItem.fromJson).toList(),
      );
}

class TimelineEvent {
  const TimelineEvent({
    this.at,
    this.fromStatus,
    required this.toStatus,
    this.note,
  });
  final DateTime? at;
  final String? fromStatus, note;
  final String toStatus;
  factory TimelineEvent.fromJson(Map<String, dynamic> j) => TimelineEvent(
    at: asDate(j['at']),
    fromStatus: asStringOrNull(j['from_status']),
    toStatus: (j['to_status'] as String?) ?? '',
    note: asStringOrNull(j['note']),
  );
}
