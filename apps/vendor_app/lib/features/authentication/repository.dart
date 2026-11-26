import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class AuthRepository {
  AuthRepository(this._api);
  final ApiClient _api;
  Future<Me> me() async => Me.fromJson(asMap(await _api.get('/auth/me')));
  Future<void> logout() async {
    try {
      await _api.post('/auth/logout');
    } on ApiException {
      // signing out locally must always work, even offline or with an expired token
    }
  }
}

/// The signed-in user's own account row. Only name, phone and picture are editable; role, status and e-mail are rejected by the backend.
class ProfileRepository {
  ProfileRepository(this._api);
  final ApiClient _api;

  Future<void> update({
    String? fullName,
    String? phone,
    String? avatarPath,
  }) async {
    await _api.put(
      '/profiles/me',
      body: {
        'full_name': ?fullName,
        'phone': ?phone,
        'avatar_path': ?avatarPath,
      },
    );
  }
}
