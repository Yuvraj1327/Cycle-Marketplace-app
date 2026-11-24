import '../../core/api/api_client.dart';
import 'models.dart';

class WishlistRepository {
  WishlistRepository(this._api);
  final ApiClient _api;

  Future<Wishlist> get() async =>
      Wishlist.fromJson(await _api.get('/wishlist'));
  Future<void> add(String productId) async =>
      _api.post('/wishlist/items', body: {'product_id': productId});
  Future<void> remove(String itemId) async =>
      _api.delete('/wishlist/items/$itemId');
}
