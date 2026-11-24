import '../../core/utils/json.dart';

class Address {
  const Address({
    required this.id,
    this.label,
    required this.addressType,
    required this.recipientName,
    required this.phone,
    required this.line1,
    this.line2,
    this.landmark,
    required this.city,
    required this.state,
    required this.postalCode,
    required this.country,
    required this.isDefault,
  });
  final String id,
      addressType,
      recipientName,
      phone,
      line1,
      city,
      state,
      postalCode,
      country;
  final String? label, line2, landmark;
  final bool isDefault;

  factory Address.fromJson(Map<String, dynamic> j) => Address(
    id: j['id'] as String,
    label: asStringOrNull(j['label']),
    addressType: j['address_type'] as String,
    recipientName: j['recipient_name'] as String,
    phone: j['phone'] as String,
    line1: j['address_line1'] as String,
    line2: asStringOrNull(j['address_line2']),
    landmark: asStringOrNull(j['landmark']),
    city: j['city'] as String,
    state: j['state'] as String,
    postalCode: j['postal_code'] as String,
    country: (j['country'] as String?) ?? 'India',
    isDefault: j['is_default'] == true,
  );

  String get oneLine => [
    line1,
    if (line2 != null && line2!.isNotEmpty) line2,
    city,
    '$state $postalCode',
  ].join(', ');
  bool get usableForDelivery =>
      addressType == 'delivery' || addressType == 'both';
  bool get usableForPickup => addressType == 'pickup' || addressType == 'both';
}

/// Body for POST/PUT /addresses (only the fields the backend accepts).
class AddressInput {
  const AddressInput({
    this.label,
    this.addressType = 'both',
    required this.recipientName,
    required this.phone,
    required this.line1,
    this.line2,
    this.landmark,
    required this.city,
    required this.state,
    required this.postalCode,
    this.country = 'India',
    this.makeDefault = false,
  });
  final String? label, line2, landmark;
  final String addressType,
      recipientName,
      phone,
      line1,
      city,
      state,
      postalCode,
      country;
  final bool makeDefault;

  Map<String, dynamic> toJson({bool forCreate = true}) => {
    if (label != null && label!.isNotEmpty) 'label': label,
    'address_type': addressType,
    'recipient_name': recipientName,
    'phone': phone,
    'address_line1': line1,
    if (line2 != null && line2!.isNotEmpty) 'address_line2': line2,
    if (landmark != null && landmark!.isNotEmpty) 'landmark': landmark,
    'city': city,
    'state': state,
    'postal_code': postalCode,
    'country': country,
    if (forCreate) 'is_default': makeDefault,
  };
}
