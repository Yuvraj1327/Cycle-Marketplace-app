import '../../core/utils/json.dart';

class Schedule {
  const Schedule({this.date, this.slotStart, this.slotEnd});
  final String? date, slotStart, slotEnd;
  bool get isSet => date != null;
  factory Schedule.fromJson(dynamic j) {
    final m = asMap(j);
    return Schedule(
      date: asStringOrNull(m['date']),
      slotStart: asStringOrNull(m['slot_start']),
      slotEnd: asStringOrNull(m['slot_end']),
    );
  }
}

class CustomerBrief {
  const CustomerBrief({this.name, this.phone});
  final String? name, phone;
  factory CustomerBrief.fromJson(dynamic j) {
    final m = asMap(j);
    return CustomerBrief(
      name: asStringOrNull(m['full_name']),
      phone: asStringOrNull(m['phone']),
    );
  }
}

/// Pickup/drop-off coordination. KEPT SEPARATE from the repair status: `pickupStage` / `deliveryStage` are
/// requested | scheduled | picked_up / delivered | failed | cancelled.
class Logistics {
  const Logistics({
    required this.id,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.pickupStage,
    required this.deliveryStage,
    this.scheduledPickupAt,
    this.scheduledDeliveryAt,
    this.pickedUpAt,
    this.deliveredAt,
    required this.pickupCharge,
    required this.dropoffCharge,
    this.instructions,
    this.notes,
  });
  final String id, pickupStage, deliveryStage;
  final Map<String, dynamic> pickupAddress, dropoffAddress;
  final DateTime? scheduledPickupAt,
      scheduledDeliveryAt,
      pickedUpAt,
      deliveredAt;
  final double pickupCharge, dropoffCharge;
  final String? instructions, notes;

  static String addressText(Map<String, dynamic> a) => [
    a['recipient_name'],
    a['address_line1'],
    a['address_line2'],
    a['landmark'],
    a['city'],
    '${a['state'] ?? ''} ${a['postal_code'] ?? ''}'.trim(),
  ].where((e) => e != null && '$e'.trim().isNotEmpty).join(', ');

  factory Logistics.fromJson(Map<String, dynamic> j) => Logistics(
    id: j['id'] as String,
    pickupAddress: asMap(j['pickup_address']),
    dropoffAddress: asMap(j['dropoff_address']),
    pickupStage: (j['pickup_stage'] as String?) ?? 'requested',
    deliveryStage: (j['delivery_stage'] as String?) ?? 'requested',
    scheduledPickupAt: asDate(j['scheduled_pickup_at']),
    scheduledDeliveryAt: asDate(j['scheduled_delivery_at']),
    pickedUpAt: asDate(j['picked_up_at']),
    deliveredAt: asDate(j['delivered_at']),
    pickupCharge: asDouble(j['pickup_charge']),
    dropoffCharge: asDouble(j['dropoff_charge']),
    instructions: asStringOrNull(j['customer_instructions']),
    notes: asStringOrNull(j['notes']),
  );
}

class PickupRequest {
  const PickupRequest({
    required this.id,
    required this.bookingId,
    this.bookingNumber,
    this.bookingStatus,
    this.serviceName,
    this.customer,
    required this.logistics,
    required this.preferred,
  });
  final String id, bookingId;
  final String? bookingNumber, bookingStatus, serviceName;
  final CustomerBrief? customer;
  final Logistics logistics;
  final Schedule preferred;
  factory PickupRequest.fromJson(Map<String, dynamic> j) => PickupRequest(
    id: j['id'] as String,
    bookingId: j['booking_id'] as String,
    bookingNumber: asStringOrNull(j['booking_number']),
    bookingStatus: asStringOrNull(j['booking_status']),
    serviceName: asStringOrNull(j['service_name']),
    customer: j['customer'] == null
        ? null
        : CustomerBrief.fromJson(j['customer']),
    logistics: Logistics.fromJson(asMap(j['pickup'])),
    preferred: Schedule.fromJson(j['preferred']),
  );
}
