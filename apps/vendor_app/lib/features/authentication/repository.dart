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
