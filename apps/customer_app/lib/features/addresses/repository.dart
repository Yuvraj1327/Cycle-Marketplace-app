import '../../core/api/api_client.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class AddressRepository {
  AddressRepository(this._api);
  final ApiClient _api;

  Future<List<Address>> list() async =>
      asMapList(await _api.get('/addresses')).map(Address.fromJson).toList();
  Future<Address> create(AddressInput a) async =>
      Address.fromJson(asMap(await _api.post('/addresses', body: a.toJson())));
  Future<Address> update(String id, AddressInput a) async => Address.fromJson(
    asMap(await _api.put('/addresses/$id', body: a.toJson(forCreate: false))),
  );
  Future<void> delete(String id) async => _api.delete('/addresses/$id');
  Future<Address> setDefault(String id) async =>
      Address.fromJson(asMap(await _api.patch('/addresses/$id/default')));
}
