import '../../core/utils/json.dart';

class ServiceCategory {
  const ServiceCategory({required this.id, required this.name});
  final String id, name;
  factory ServiceCategory.fromJson(Map<String, dynamic> j) => ServiceCategory(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
  );
}

const dayCodes = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

class VendorService {
  const VendorService({
    required this.id,
    required this.categoryId,
    this.categoryName,
    required this.name,
    this.description,
    required this.price,
    this.durationMinutes,
    required this.isActive,
    required this.isAvailable,
    this.availableDays,
    required this.slotMinutes,
    required this.maxPerSlot,
  });
  final String id, categoryId, name;
  final String? categoryName, description;
  final double price;
  final int? durationMinutes;
  final bool isActive, isAvailable;
  final List<String>? availableDays; // null = every day the business is open
  final int slotMinutes, maxPerSlot;

  factory VendorService.fromJson(Map<String, dynamic> j) => VendorService(
    id: j['id'] as String,
    categoryId: (j['service_category_id'] as String?) ?? '',
    categoryName: asStringOrNull(asMap(j['category'])['name']),
    name: (j['name'] as String?) ?? '',
    description: asStringOrNull(j['description']),
    price: asDouble(j['price']),
    durationMinutes: j['estimated_duration_minutes'] == null
        ? null
        : asInt(j['estimated_duration_minutes']),
    isActive: j['is_active'] != false,
    isAvailable: j['is_available'] != false,
    availableDays: j['available_days'] is List
        ? (j['available_days'] as List).map((e) => '$e').toList()
        : null,
    slotMinutes: asInt(j['slot_minutes'], 60),
    maxPerSlot: asInt(j['max_bookings_per_slot'], 1),
  );
}

class ServiceInput {
  const ServiceInput({
    required this.categoryId,
    required this.name,
    this.description,
    required this.price,
    this.durationMinutes,
    required this.isAvailable,
    this.availableDays,
    required this.slotMinutes,
    required this.maxPerSlot,
  });
  final String categoryId, name;
  final String? description;
  final double price;
  final int? durationMinutes;
  final bool isAvailable;
  final List<String>? availableDays;
  final int slotMinutes, maxPerSlot;

  Map<String, dynamic> toJson() => {
    'service_category_id': categoryId,
    'name': name,
    'description': (description ?? '').isEmpty ? null : description,
    'price': price,
    'estimated_duration_minutes': durationMinutes,
    'is_available': isAvailable,
    'available_days': availableDays,
    'slot_minutes': slotMinutes,
    'max_bookings_per_slot': maxPerSlot,
  };
}
