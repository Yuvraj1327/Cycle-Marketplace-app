import '../../core/utils/json.dart';
import '../pickup_dropoff/models.dart';

const bookingStatusLabels = {
  'pending': 'New',
  'accepted': 'Accepted',
  'rejected': 'Rejected',
  'picked_up': 'Picked up',
  'in_service': 'In service',
  'ready_for_delivery': 'Ready for delivery',
  'completed': 'Completed',
  'cancelled': 'Cancelled',
};

class Charge {
  const Charge({
    required this.id,
    required this.amount,
    required this.reason,
    this.role,
    this.at,
  });
  final String id, reason;
  final double amount;
  final String? role;
  final DateTime? at;
  factory Charge.fromJson(Map<String, dynamic> j) => Charge(
    id: j['id'] as String,
    amount: asDouble(j['amount']),
    reason: (j['reason'] as String?) ?? '',
    role: asStringOrNull(j['recorded_role']),
    at: asDate(j['created_at']),
  );
}

class BookingNote {
  const BookingNote({
    required this.id,
    required this.role,
    required this.note,
    this.at,
  });
  final String id, role, note;
  final DateTime? at;
  factory BookingNote.fromJson(Map<String, dynamic> j) => BookingNote(
    id: j['id'] as String,
    role: (j['author_role'] as String?) ?? '',
    note: (j['note'] as String?) ?? '',
    at: asDate(j['created_at']),
  );
}

class BookingImage {
  const BookingImage({required this.id, this.url});
  final String id;
  final String? url;
  factory BookingImage.fromJson(Map<String, dynamic> j) =>
      BookingImage(id: j['id'] as String, url: asStringOrNull(j['url']));
}

class Pricing {
  const Pricing({
    required this.estimated,
    required this.additional,
    required this.current,
    required this.pickup,
    required this.dropoff,
    required this.totalCurrent,
    this.logisticsConfigured,
  });
  final double estimated, additional, current, pickup, dropoff, totalCurrent;
  final bool? logisticsConfigured;
  factory Pricing.fromJson(dynamic j) {
    final m = asMap(j);
    return Pricing(
      estimated: asDouble(m['estimated_price']),
      additional: asDouble(m['additional_charges_total']),
      current: asDouble(m['current_price']),
      pickup: asDouble(m['pickup_charge']),
      dropoff: asDouble(m['dropoff_charge']),
      totalCurrent: asDouble(m['total_current']),
      logisticsConfigured: m['logistics_charges_configured'] as bool?,
    );
  }
}

/// Valid next repair steps (mirrors the backend state machine; the backend still validates every change and answers 409 otherwise).
List<String> nextRepairSteps(String status, {required bool needsPickup}) =>
    switch (status) {
      'accepted' => needsPickup ? ['picked_up'] : ['in_service'],
      'picked_up' => ['in_service'],
      'in_service' => ['ready_for_delivery'],
      'ready_for_delivery' => ['completed'],
      _ => const [],
    };

class VendorBooking {
  const VendorBooking({
    required this.id,
    required this.number,
    required this.status,
    required this.serviceName,
    required this.preferred,
    required this.confirmed,
    required this.needsPickup,
    required this.currentPrice,
    this.createdAt,
    this.customer,
    required this.issue,
    this.pickupStage,
    this.deliveryStage,
    this.detail,
  });
  final String id, number, status, serviceName, issue;
  final Schedule preferred, confirmed;
  final bool needsPickup;
  final double currentPrice;
  final DateTime? createdAt;
  final CustomerBrief? customer;
  final String? pickupStage, deliveryStage;
  final BookingDetail? detail;

  bool get isNew => status == 'pending';
  List<String> get nextSteps =>
      nextRepairSteps(status, needsPickup: needsPickup);
  bool get chargesOpen => const {
    'accepted',
    'picked_up',
    'in_service',
    'ready_for_delivery',
  }.contains(status);
  bool get canCancel => status == 'accepted';

  factory VendorBooking.fromJson(
    Map<String, dynamic> j, {
    bool withDetail = false,
  }) => VendorBooking(
    id: j['id'] as String,
    number: (j['booking_number'] as String?) ?? '',
    status: (j['status'] as String?) ?? 'pending',
    serviceName: (j['service_name'] as String?) ?? '',
    preferred: Schedule.fromJson(j['preferred']),
    confirmed: Schedule.fromJson(j['confirmed']),
    needsPickup: j['needs_pickup_dropoff'] == true,
    currentPrice: asDouble(j['current_price']),
    createdAt: asDate(j['created_at']),
    customer: j['customer'] == null
        ? null
        : CustomerBrief.fromJson(j['customer']),
    issue: (j['issue_description'] as String?) ?? '',
    pickupStage: asStringOrNull(j['pickup_stage']),
    deliveryStage: asStringOrNull(j['delivery_stage']),
    detail: withDetail ? BookingDetail.fromJson(j) : null,
  );
}

class BookingDetail {
  const BookingDetail({
    required this.cycle,
    this.durationMinutes,
    required this.pricing,
    this.logistics,
    required this.charges,
    required this.notes,
    required this.images,
    this.rejectionReason,
    this.cancellationReason,
    this.completionNotes,
    this.acceptedAt,
    this.completedAt,
  });
  final Map<String, dynamic> cycle;
  final int? durationMinutes;
  final Pricing pricing;
  final Logistics? logistics;
  final List<Charge> charges;
  final List<BookingNote> notes;
  final List<BookingImage> images;
  final String? rejectionReason, cancellationReason, completionNotes;
  final DateTime? acceptedAt, completedAt;

  factory BookingDetail.fromJson(Map<String, dynamic> j) => BookingDetail(
    cycle: asMap(j['cycle']),
    durationMinutes: j['estimated_duration_minutes'] == null
        ? null
        : asInt(j['estimated_duration_minutes']),
    pricing: Pricing.fromJson(j['pricing']),
    logistics: j['pickup'] is Map
        ? Logistics.fromJson(asMap(j['pickup']))
        : null,
    charges: asMapList(j['charges']).map(Charge.fromJson).toList(),
    notes: asMapList(j['notes']).map(BookingNote.fromJson).toList(),
    images: asMapList(j['images']).map(BookingImage.fromJson).toList(),
    rejectionReason: asStringOrNull(j['rejection_reason']),
    cancellationReason: asStringOrNull(j['cancellation_reason']),
    completionNotes: asStringOrNull(j['completion_notes']),
    acceptedAt: asDate(j['accepted_at']),
    completedAt: asDate(j['completed_at']),
  );
}
