import '../../core/utils/json.dart';

class Me {
  const Me({
    required this.id,
    this.email,
    this.phone,
    required this.role,
    required this.status,
    required this.fullName,
    this.profilePhone,
    this.avatarPath,
  });
  final String id, role, status, fullName;
  final String? email, phone, profilePhone, avatarPath;
  bool get isVendor => role == 'vendor';
  bool get isActive => status == 'active';
  factory Me.fromJson(Map<String, dynamic> j) => Me(
    id: j['id'] as String,
    email: asStringOrNull(j['email']),
    phone: asStringOrNull(j['phone']),
    role: j['role'] as String,
    status: j['status'] as String,
    fullName: asStringOrNull(asMap(j['profile'])['full_name']) ?? '',
    profilePhone: asStringOrNull(asMap(j['profile'])['phone']),
    avatarPath: asStringOrNull(asMap(j['profile'])['avatar_path']),
  );
}
