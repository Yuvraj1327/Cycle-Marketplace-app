import '../../core/api/api_client.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class VendorProfileRepository {
  VendorProfileRepository(this._api);
  final ApiClient _api;

  Future<VendorProfile> me() async =>
      VendorProfile.fromJson(asMap(await _api.get('/vendors/me')));
  Future<VendorProfile> register(BusinessInput b) async =>
      VendorProfile.fromJson(
        asMap(await _api.post('/vendors/register', body: b.toJson())),
      );
  Future<VendorProfile> update(BusinessInput b) async => VendorProfile.fromJson(
    asMap(await _api.put('/vendors/me', body: b.toJson(forUpdate: true))),
  );

  /// Lightweight re-check of the admin's decision.
  Future<({String status, String? reason, bool canOperate})> status() async {
    final j = asMap(await _api.get('/vendors/me/status'));
    return (
      status: (j['verification_status'] as String?) ?? 'pending',
      reason: asStringOrNull(j['rejection_reason']),
      canOperate: j['can_operate'] == true,
    );
  }
}
