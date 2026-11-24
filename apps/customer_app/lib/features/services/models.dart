import '../../core/utils/json.dart';

class ServiceCategory {
  const ServiceCategory({
    required this.id,
    required this.name,
    this.description,
    this.imageUrl,
    this.serviceCount = 0,
  });
  final String id, name;
  final String? description, imageUrl;
  final int serviceCount;
  factory ServiceCategory.fromJson(Map<String, dynamic> j) => ServiceCategory(
    id: j['id'] as String,
    name: j['name'] as String,
    description: asStringOrNull(j['description']),
    imageUrl: asStringOrNull(j['image_url']),
    serviceCount: asInt(j['service_count']),
  );
}

class Provider {
  const Provider({
    required this.id,
    required this.businessName,
    this.city,
    this.state,
    required this.pickupAvailable,
    required this.serviceAreaPostalCodes,
    required this.operatingHours,
  });
  final String id, businessName;
  final String? city, state;
  final bool pickupAvailable;
  final List<String> serviceAreaPostalCodes;
  final Map<String, dynamic> operatingHours;
  factory Provider.fromJson(Map<String, dynamic> j) => Provider(
    id: j['id'] as String,
    businessName: (j['business_name'] as String?) ?? '',
    city: asStringOrNull(j['city']),
    state: asStringOrNull(j['state']),
    pickupAvailable: j['pickup_available'] == true,
    serviceAreaPostalCodes: (j['service_area_postal_codes'] is List)
        ? (j['service_area_postal_codes'] as List).map((e) => '$e').toList()
        : const [],
    operatingHours: asMap(j['operating_hours']),
  );
  String get location =>
      [city, state].whereType<String>().where((s) => s.isNotEmpty).join(', ');
}

class ServiceItem {
  const ServiceItem({
    required this.id,
    required this.name,
    this.description,
    required this.price,
    this.durationMinutes,
    required this.isAvailable,
    this.categoryName,
    this.provider,
    required this.slotMinutes,
  });
  final String id, name;
  final String? description, categoryName;
  final double price;
  final int? durationMinutes;
  final bool isAvailable;
  final Provider? provider;
  final int slotMinutes;
  factory ServiceItem.fromJson(Map<String, dynamic> j) => ServiceItem(
    id: j['id'] as String,
    name: j['name'] as String,
    description: asStringOrNull(j['description']),
    price: asDouble(j['price']),
    durationMinutes: j['estimated_duration_minutes'] == null
        ? null
        : asInt(j['estimated_duration_minutes']),
    isAvailable: j['is_available'] == true,
    categoryName: j['category'] is Map
        ? asStringOrNull(asMap(j['category'])['name'])
        : null,
    provider: j['provider'] is Map
        ? Provider.fromJson(asMap(j['provider']))
        : null,
    slotMinutes: asInt(j['slot_minutes'], 60),
  );

  String get durationLabel {
    final m = durationMinutes;
    if (m == null) return 'Duration not specified';
    if (m < 60) return '$m min';
    final h = m ~/ 60, r = m % 60;
    return r == 0 ? '$h hr' : '$h hr $r min';
  }
}

class Slot {
  const Slot({
    required this.start,
    required this.end,
    required this.capacity,
    required this.booked,
    required this.available,
  });
  final String start, end;
  final int capacity, booked;
  final bool available;
  factory Slot.fromJson(Map<String, dynamic> j) => Slot(
    start: j['start'] as String,
    end: j['end'] as String,
    capacity: asInt(j['capacity']),
    booked: asInt(j['booked']),
    available: j['available'] == true,
  );
}

class Availability {
  const Availability({
    required this.bookable,
    this.reason,
    required this.slots,
  });
  final bool bookable;
  final String? reason;
  final List<Slot> slots;
  factory Availability.fromJson(dynamic json) {
    final j = asMap(json);
    return Availability(
      bookable: j['bookable'] == true,
      reason: asStringOrNull(j['reason']),
      slots: asMapList(j['slots']).map(Slot.fromJson).toList(),
    );
  }

  /// Plain-language explanation for an empty slot list (backend reason codes).
  String get reasonText => switch (reason) {
    'date_in_past' => 'That date has already passed.',
    'too_far_ahead' => 'Bookings are not open that far ahead yet.',
    'service_not_offered_that_day' =>
      'This service is not offered on that day.',
    'vendor_closed' => 'The provider is closed that day.',
    'vendor_hours_not_configured' =>
      'This provider has not set opening hours yet.',
    'no_slots_left' => 'No slots are left on that date.',
    'service_unavailable' ||
    'vendor_unavailable' => 'This service is not available right now.',
    _ => 'No slots available for that date.',
  };
}

class BookingOptions {
  const BookingOptions({
    this.pickupCharge,
    this.dropoffCharge,
    required this.chargesConfigured,
    required this.maxAdvanceDays,
    required this.minNoticeHours,
  });
  final double? pickupCharge, dropoffCharge;
  final bool chargesConfigured;
  final int maxAdvanceDays, minNoticeHours;
  factory BookingOptions.fromJson(dynamic json) {
    final j = asMap(json);
    return BookingOptions(
      pickupCharge: asDoubleOrNull(j['pickup_charge']),
      dropoffCharge: asDoubleOrNull(j['dropoff_charge']),
      chargesConfigured: j['charges_configured'] == true,
      maxAdvanceDays: asInt(j['max_advance_days'], 60),
      minNoticeHours: asInt(j['min_notice_hours']),
    );
  }
}
