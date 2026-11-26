import '../../core/api/api_client.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class AuthRepository {
  AuthRepository(this._api);
  final ApiClient _api;

  /// Who the backend says this user is (role + status come from the database).
  Future<Me> me() async => Me.fromJson(asMap(await _api.get('/auth/me')));

  /// Best effort: asks Supabase Auth (through the backend) to end the session. The app also signs out locally, so failures are ignored.
  Future<void> logout() async {
    try {
      await _api.post('/auth/logout');
    } catch (_) {}
  }
}

class ProfileRepository {
  ProfileRepository(this._api);
  final ApiClient _api;

  Future<Profile> get() async =>
      Profile.fromJson(asMap(await _api.get('/profiles/me')));

  /// Only name, phone and avatar are editable; role/status/email are rejected by the backend.
  Future<Profile> update({
    String? fullName,
    String? phone,
    String? avatarPath,
  }) async => Profile.fromJson(
    asMap(
      await _api.put(
        '/profiles/me',
        body: {
          'full_name': ?fullName,
          'phone': ?phone,
          'avatar_path': ?avatarPath,
        },
      ),
    ),
  );
}
