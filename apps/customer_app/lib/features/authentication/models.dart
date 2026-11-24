import '../../core/utils/json.dart';

class Profile {
  const Profile({
    required this.id,
    required this.fullName,
    this.email,
    this.phone,
    required this.role,
    required this.status,
    this.avatarPath,
  });
  final String id, fullName, role, status;
  final String? email, phone, avatarPath;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    id: j['id'] as String,
    fullName: (j['full_name'] as String?) ?? '',
    email: asStringOrNull(j['email']),
    phone: asStringOrNull(j['phone']),
    role: j['role'] as String,
    status: j['status'] as String,
    avatarPath: asStringOrNull(j['avatar_path']),
  );
}

/// GET /auth/me. The role and status come from the BACKEND database, never from the token or the app.
class Me {
  const Me({
    required this.id,
    this.email,
    this.phone,
    required this.role,
    required this.status,
    required this.profile,
  });
  final String id, role, status;
  final String? email, phone;
  final Profile profile;
  bool get isCustomer => role == 'customer';
  bool get isActive => status == 'active';

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    id: j['id'] as String,
    email: asStringOrNull(j['email']),
    phone: asStringOrNull(j['phone']),
    role: j['role'] as String,
    status: j['status'] as String,
    profile: Profile.fromJson(asMap(j['profile'])),
  );
}
