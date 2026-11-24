import '../../core/utils/json.dart';

enum BusinessType {
  bicycleShop('bicycle_shop', 'Bicycle shop'),
  usedCycleSeller('used_cycle_seller', 'Used bicycle seller'),
  sparePartsSeller('spare_parts_seller', 'Spare-parts seller'),
  serviceProvider('service_provider', 'Cycle service provider');

  const BusinessType(this.api, this.label);
  final String api, label;
  static BusinessType? parse(String s) {
    for (final t in values) {
      if (t.api == s) return t;
    }
    return null;
  }
}

const weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const weekdayLabels = {
  'mon': 'Monday',
  'tue': 'Tuesday',
  'wed': 'Wednesday',
  'thu': 'Thursday',
  'fri': 'Friday',
  'sat': 'Saturday',
  'sun': 'Sunday',
};

class DayHours {
  const DayHours({this.closed = false, this.open, this.close});
  final bool closed;
  final String? open, close; // HH:MM
  Map<String, dynamic> toJson() => closed
      ? {'closed': true}
      : {'closed': false, 'open': open, 'close': close};
  factory DayHours.fromJson(Map<String, dynamic> j) => DayHours(
    closed: j['closed'] == true,
    open: asStringOrNull(j['open']),
    close: asStringOrNull(j['close']),
  );
}

/// `verification_status` values are decided by the BACKEND/admin only: pending | approved | rejected | suspended.
class VendorProfile {
  const VendorProfile({
    required this.id,
    required this.businessName,
    required this.businessTypes,
    this.description,
    required this.addressLine1,
    this.addressLine2,
    required this.city,
    required this.state,
    required this.postalCode,
    required this.contactPhone,
    this.contactEmail,
    required this.operatingHours,
    required this.shopImagePaths,
    required this.servicePostalCodes,
    this.serviceRadiusKm,
    required this.pickupAvailable,
    required this.verificationStatus,
    this.rejectionReason,
    this.reviewedAt,
  });
  final String id, businessName, addressLine1, city, state, postalCode;
  final String contactPhone, verificationStatus;
  final String? description, addressLine2, contactEmail, rejectionReason;
  final List<BusinessType> businessTypes;
  final Map<String, DayHours> operatingHours;
  final List<String> shopImagePaths, servicePostalCodes;
  final double? serviceRadiusKm;
  final bool pickupAvailable;
  final DateTime? reviewedAt;

  bool get isApproved => verificationStatus == 'approved';
  bool get isPending => verificationStatus == 'pending';
  bool get isRejected => verificationStatus == 'rejected';
  bool get isSuspended => verificationStatus == 'suspended';
  bool get offersProducts =>
      businessTypes.any((t) => t != BusinessType.serviceProvider);
  bool get offersServices =>
      businessTypes.contains(BusinessType.serviceProvider);

  factory VendorProfile.fromJson(Map<String, dynamic> j) => VendorProfile(
    id: j['id'] as String,
    businessName: (j['business_name'] as String?) ?? '',
    businessTypes: (j['business_types'] as List? ?? [])
        .map((e) => BusinessType.parse('$e'))
        .whereType<BusinessType>()
        .toList(),
    description: asStringOrNull(j['description']),
    addressLine1: (j['address_line1'] as String?) ?? '',
    addressLine2: asStringOrNull(j['address_line2']),
    city: (j['city'] as String?) ?? '',
    state: (j['state'] as String?) ?? '',
    postalCode: (j['postal_code'] as String?) ?? '',
    contactPhone: (j['contact_phone'] as String?) ?? '',
    contactEmail: asStringOrNull(j['contact_email']),
    operatingHours: {
      for (final e in asMap(j['operating_hours']).entries)
        e.key: DayHours.fromJson(asMap(e.value)),
    },
    shopImagePaths: (j['shop_image_paths'] as List? ?? [])
        .map((e) => '$e')
        .toList(),
    servicePostalCodes: (j['service_area_postal_codes'] as List? ?? [])
        .map((e) => '$e')
        .toList(),
    serviceRadiusKm: asDoubleOrNull(j['service_radius_km']),
    pickupAvailable: j['pickup_available'] == true,
    verificationStatus: (j['verification_status'] as String?) ?? 'pending',
    rejectionReason: asStringOrNull(j['rejection_reason']),
    reviewedAt: asDate(j['reviewed_at']),
  );
}

/// The fields the vendor may send when registering / editing the business. Never contains verification or role fields.
class BusinessInput {
  const BusinessInput({
    required this.businessName,
    required this.businessTypes,
    this.description,
    required this.addressLine1,
    this.addressLine2,
    required this.city,
    required this.state,
    required this.postalCode,
    required this.contactPhone,
    this.contactEmail,
    required this.operatingHours,
    required this.shopImagePaths,
    required this.servicePostalCodes,
    this.serviceRadiusKm,
    required this.pickupAvailable,
  });
  final String businessName,
      addressLine1,
      city,
      state,
      postalCode,
      contactPhone;
  final String? description, addressLine2, contactEmail;
  final List<BusinessType> businessTypes;
  final Map<String, DayHours> operatingHours;
  final List<String> shopImagePaths, servicePostalCodes;
  final double? serviceRadiusKm;
  final bool pickupAvailable;

  Map<String, dynamic> toJson({bool forUpdate = false}) => {
    'business_name': businessName,
    'business_types': businessTypes.map((t) => t.api).toList(),
    // on update, an empty value is sent as null so it is CLEARED; on register it is simply omitted
    if (forUpdate || (description ?? '').isNotEmpty)
      'description': (description ?? '').isEmpty ? null : description,
    'address_line1': addressLine1,
    if (forUpdate || (addressLine2 ?? '').isNotEmpty)
      'address_line2': (addressLine2 ?? '').isEmpty ? null : addressLine2,
    'city': city,
    'state': state,
    'postal_code': postalCode,
    'contact_phone': contactPhone,
    if (forUpdate || (contactEmail ?? '').isNotEmpty)
      'contact_email': (contactEmail ?? '').isEmpty ? null : contactEmail,
    'operating_hours': {
      for (final e in operatingHours.entries) e.key: e.value.toJson(),
    },
    'shop_image_paths': shopImagePaths,
    'service_area_postal_codes': servicePostalCodes,
    if (forUpdate || serviceRadiusKm != null)
      'service_radius_km': serviceRadiusKm,
    'pickup_available': pickupAvailable,
  };
}
