import '../../core/utils/json.dart';

class Schedule {
  const Schedule({this.date, this.slotStart, this.slotEnd});
  final String? date, slotStart, slotEnd;
  bool get isSet => date != null;
  factory Schedule.fromJson(dynamic json) {
    final j = asMap(json);
    return Schedule(
      date: asStringOrNull(j['date']),
      slotStart: asStringOrNull(j['slot_start']),
      slotEnd: asStringOrNull(j['slot_end']),
    );
  }
}

class BookingSummary {
  const BookingSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.serviceName,
    this.vendorName,
    required this.preferred,
    required this.confirmed,
    required this.needsPickup,
    required this.currentPrice,
    this.createdAt,
  });
  final String id, number, status, serviceName;
  final String? vendorName;
  final Schedule preferred, confirmed;
  final bool needsPickup;
  final double currentPrice;
  final DateTime? createdAt;
  factory BookingSummary.fromJson(Map<String, dynamic> j) => BookingSummary(
    id: j['id'] as String,
    number: j['booking_number'] as String,
    status: j['status'] as String,
    serviceName: j['service_name'] as String,
    vendorName: asStringOrNull(j['vendor_name']),
    preferred: Schedule.fromJson(j['preferred']),
    confirmed: Schedule.fromJson(j['confirmed']),
    needsPickup: j['needs_pickup_dropoff'] == true,
    currentPrice: asDouble(j['current_price']),
    createdAt: asDate(j['created_at']),
  );
}

class Pickup {
  const Pickup({
    required this.pickupStage,
    required this.deliveryStage,
    required this.pickupAddress,
    required this.dropoffAddress,
    this.scheduledPickupAt,
    this.scheduledDeliveryAt,
    this.pickedUpAt,
    this.deliveredAt,
    required this.pickupCharge,
    required this.dropoffCharge,
    this.instructions,
    this.notes,
  });
  final String pickupStage, deliveryStage;
  final Map<String, dynamic> pickupAddress, dropoffAddress;
  final DateTime? scheduledPickupAt,
      scheduledDeliveryAt,
      pickedUpAt,
      deliveredAt;
  final double pickupCharge, dropoffCharge;
  final String? instructions, notes;
  factory Pickup.fromJson(Map<String, dynamic> j) => Pickup(
    pickupStage: j['pickup_stage'] as String,
    deliveryStage: j['delivery_stage'] as String,
    pickupAddress: asMap(j['pickup_address']),
    dropoffAddress: asMap(j['dropoff_address']),
    scheduledPickupAt: asDate(j['scheduled_pickup_at']),
    scheduledDeliveryAt: asDate(j['scheduled_delivery_at']),
    pickedUpAt: asDate(j['picked_up_at']),
    deliveredAt: asDate(j['delivered_at']),
    pickupCharge: asDouble(j['pickup_charge']),
    dropoffCharge: asDouble(j['dropoff_charge']),
    instructions: asStringOrNull(j['customer_instructions']),
    notes: asStringOrNull(j['notes']),
  );

  static String addressText(Map<String, dynamic> a) => [
    a['address_line1'],
    a['address_line2'],
    a['city'],
    '${a['state'] ?? ''} ${a['postal_code'] ?? ''}'.trim(),
  ].where((e) => e != null && '$e'.isNotEmpty).join(', ');
}

class Pricing {
  const Pricing({
    required this.estimated,
    required this.additional,
    required this.current,
    required this.pickupCharge,
    required this.dropoffCharge,
    required this.totalCurrent,
    this.logisticsConfigured,
  });
  final double estimated,
      additional,
      current,
      pickupCharge,
      dropoffCharge,
      totalCurrent;
  final bool? logisticsConfigured;
  factory Pricing.fromJson(dynamic json) {
    final j = asMap(json);
    return Pricing(
      estimated: asDouble(j['estimated_price']),
      additional: asDouble(j['additional_charges_total']),
      current: asDouble(j['current_price']),
      pickupCharge: asDouble(j['pickup_charge']),
      dropoffCharge: asDouble(j['dropoff_charge']),
      totalCurrent: asDouble(j['total_current']),
      logisticsConfigured: j['logistics_charges_configured'] as bool?,
    );
  }
}

class ChargeEntry {
  const ChargeEntry({required this.amount, required this.reason, this.at});
  final double amount;
  final String reason;
  final DateTime? at;
  factory ChargeEntry.fromJson(Map<String, dynamic> j) => ChargeEntry(
    amount: asDouble(j['amount']),
    reason: j['reason'] as String,
    at: asDate(j['created_at']),
  );
}

class NoteEntry {
  const NoteEntry({required this.note, this.at});
  final String note;
  final DateTime? at;
  factory NoteEntry.fromJson(Map<String, dynamic> j) =>
      NoteEntry(note: j['note'] as String, at: asDate(j['created_at']));
}

class BookingImage {
  const BookingImage({required this.id, required this.path, this.url});
  final String id, path;
  final String? url;
  factory BookingImage.fromJson(Map<String, dynamic> j) => BookingImage(
    id: j['id'] as String,
    path: j['storage_path'] as String,
    url: asStringOrNull(j['url']),
  );
}

class BookingDetail {
  const BookingDetail({
    required this.summary,
    required this.cycle,
    required this.issue,
    this.durationMinutes,
    required this.pricing,
    this.pickup,
    required this.charges,
    required this.notes,
    required this.images,
    this.vendor,
    this.categoryName,
    this.rejectionReason,
    this.cancellationReason,
    this.completionNotes,
    this.completedAt,
    required this.canCancel,
  });
  final BookingSummary summary;
  final Map<String, dynamic> cycle;
  final String issue;
  final int? durationMinutes;
  final Pricing pricing;
  final Pickup? pickup;
  final List<ChargeEntry> charges;
  final List<NoteEntry> notes;
  final List<BookingImage> images;
  final Map<String, dynamic>? vendor;
  final String? categoryName,
      rejectionReason,
      cancellationReason,
      completionNotes;
  final DateTime? completedAt;
  final bool canCancel;

  factory BookingDetail.fromJson(dynamic json) {
    final j = asMap(json);
    return BookingDetail(
      summary: BookingSummary.fromJson(j),
      cycle: asMap(j['cycle']),
      issue: j['issue_description'] as String,
      durationMinutes: j['estimated_duration_minutes'] == null
          ? null
          : asInt(j['estimated_duration_minutes']),
      pricing: Pricing.fromJson(j['pricing']),
      pickup: j['pickup'] is Map ? Pickup.fromJson(asMap(j['pickup'])) : null,
      charges: asMapList(j['charges']).map(ChargeEntry.fromJson).toList(),
      notes: asMapList(j['notes']).map(NoteEntry.fromJson).toList(),
      images: asMapList(j['images']).map(BookingImage.fromJson).toList(),
      vendor: j['vendor'] is Map ? asMap(j['vendor']) : null,
      categoryName: j['service_category'] is Map
          ? asStringOrNull(asMap(j['service_category'])['name'])
          : null,
      rejectionReason: asStringOrNull(j['rejection_reason']),
      cancellationReason: asStringOrNull(j['cancellation_reason']),
      completionNotes: asStringOrNull(j['completion_notes']),
      completedAt: asDate(j['completed_at']),
      canCancel: j['can_cancel'] == true,
    );
  }
}

class BookingEvent {
  const BookingEvent({
    this.at,
    this.fromStatus,
    required this.toStatus,
    this.note,
  });
  final DateTime? at;
  final String? fromStatus, note;
  final String toStatus;
  factory BookingEvent.fromJson(Map<String, dynamic> j) => BookingEvent(
    at: asDate(j['at']),
    fromStatus: asStringOrNull(j['from_status']),
    toStatus: j['to_status'] as String,
    note: asStringOrNull(j['note']),
  );
}

class BookingTracking {
  const BookingTracking({
    required this.status,
    required this.timeline,
    this.pickup,
    required this.confirmed,
    required this.preferred,
  });
  final String status;
  final List<BookingEvent> timeline;
  final Pickup? pickup;
  final Schedule confirmed, preferred;
  factory BookingTracking.fromJson(dynamic json) {
    final j = asMap(json);
    return BookingTracking(
      status: j['status'] as String,
      timeline: asMapList(j['timeline']).map(BookingEvent.fromJson).toList(),
      pickup: j['pickup'] is Map ? Pickup.fromJson(asMap(j['pickup'])) : null,
      confirmed: Schedule.fromJson(j['confirmed']),
      preferred: Schedule.fromJson(j['preferred']),
    );
  }
}

/// Request body for POST /service-bookings. No customer id, vendor id or price: the backend derives those.
class BookingRequest {
  const BookingRequest({
    required this.serviceId,
    this.cycleBrand,
    this.cycleModel,
    this.cycleDetails,
    required this.issue,
    required this.date,
    required this.slotStart,
    this.needsPickup = false,
    this.pickupAddressId,
    this.dropoffAddressId,
    this.instructions,
  });
  final String serviceId, issue, date, slotStart;
  final String? cycleBrand,
      cycleModel,
      cycleDetails,
      pickupAddressId,
      dropoffAddressId,
      instructions;
  final bool needsPickup;

  Map<String, dynamic> toJson() => {
    'service_id': serviceId,
    if (cycleBrand != null && cycleBrand!.isNotEmpty) 'cycle_brand': cycleBrand,
    if (cycleModel != null && cycleModel!.isNotEmpty) 'cycle_model': cycleModel,
    if (cycleDetails != null && cycleDetails!.isNotEmpty)
      'cycle_details': cycleDetails,
    'issue_description': issue,
    'preferred_date': date,
    'slot_start': slotStart,
    'needs_pickup_dropoff': needsPickup,
    if (needsPickup) 'pickup_address_id': pickupAddressId,
    if (needsPickup && dropoffAddressId != null)
      'dropoff_address_id': dropoffAddressId,
    if (needsPickup && instructions != null && instructions!.isNotEmpty)
      'pickup_instructions': instructions,
  };
}
