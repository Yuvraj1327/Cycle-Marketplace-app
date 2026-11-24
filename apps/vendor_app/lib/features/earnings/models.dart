import '../../core/utils/json.dart';

class Settlement {
  const Settlement({
    required this.id,
    this.orderNumber,
    required this.gross,
    required this.commission,
    required this.deductions,
    required this.net,
    required this.status,
    this.payoutReference,
    this.settledAt,
    this.createdAt,
  });
  final String id, status;
  final String? orderNumber, payoutReference;
  final double gross, commission, deductions, net;
  final DateTime? settledAt, createdAt;

  /// Only a settlement the platform marked `paid` (with settled_at) may be described as paid out.
  bool get isPaid => status == 'paid';
  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
    id: j['id'] as String,
    orderNumber: asStringOrNull(j['order_number']),
    gross: asDouble(j['gross_amount']),
    commission: asDouble(j['commission_amount']),
    deductions: asDouble(j['deductions_amount']),
    net: asDouble(j['net_amount']),
    status: (j['status'] as String?) ?? 'pending',
    payoutReference: asStringOrNull(j['payout_reference']),
    settledAt: asDate(j['settled_at']),
    createdAt: asDate(j['created_at']),
  );
}

class SettlementTotals {
  const SettlementTotals({
    required this.count,
    required this.gross,
    required this.commission,
    required this.deductions,
    required this.net,
  });
  final int count;
  final double gross, commission, deductions, net;
  factory SettlementTotals.fromJson(dynamic j) {
    final m = asMap(j);
    return SettlementTotals(
      count: asInt(m['count']),
      gross: asDouble(m['gross']),
      commission: asDouble(m['commission']),
      deductions: asDouble(m['deductions']),
      net: asDouble(m['net']),
    );
  }
}

class Dashboard {
  const Dashboard({
    required this.orderTotal,
    required this.ordersByStatus,
    required this.salesTotal,
    required this.commissionTotal,
    required this.productTotal,
    required this.productsActive,
    required this.productsPending,
    required this.productsRejected,
    required this.productsOutOfStock,
    required this.bookingTotal,
    required this.bookingsByStatus,
    required this.serviceValue,
    required this.settlements,
  });
  final int orderTotal,
      productTotal,
      productsActive,
      productsPending,
      productsRejected,
      productsOutOfStock,
      bookingTotal;
  final Map<String, int> ordersByStatus, bookingsByStatus;
  final double salesTotal, commissionTotal, serviceValue;
  final Map<String, SettlementTotals> settlements;

  int orders(String s) => ordersByStatus[s] ?? 0;
  int bookings(String s) => bookingsByStatus[s] ?? 0;
  int get pendingOrders => orders('pending');
  int get completedOrders => orders('delivered');
  int get pendingBookings => bookings('pending');
  int get completedServices => bookings('completed');
  SettlementTotals? settlement(String s) => settlements[s];

  /// Net across settlements that are not cancelled, by what the platform recorded (never inferred).
  double get netPending =>
      (settlement('pending')?.net ?? 0) + (settlement('ready')?.net ?? 0);
  double get netPaid => settlement('paid')?.net ?? 0;

  static Map<String, int> _counts(dynamic j) => {
    for (final e in asMap(j).entries) e.key: asInt(e.value),
  };

  factory Dashboard.fromJson(Map<String, dynamic> j) {
    final o = asMap(j['orders']),
        p = asMap(j['products']),
        b = asMap(j['bookings']);
    return Dashboard(
      orderTotal: asInt(o['total']),
      ordersByStatus: _counts(o['by_status']),
      salesTotal: asDouble(o['sales_total']),
      commissionTotal: asDouble(o['commission_total']),
      productTotal: asInt(p['total']),
      productsActive: asInt(p['active']),
      productsPending: asInt(p['pending_approval']),
      productsRejected: asInt(p['rejected']),
      productsOutOfStock: asInt(p['out_of_stock']),
      bookingTotal: asInt(b['total']),
      bookingsByStatus: _counts(b['by_status']),
      serviceValue: asDouble(b['completed_value']),
      settlements: {
        for (final e in asMap(j['settlements']).entries)
          e.key: SettlementTotals.fromJson(e.value),
      },
    );
  }
}
