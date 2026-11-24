import '../../core/api/api_client.dart';
import 'models.dart';

/// Every method returns the whole recomputed cart from the backend; the app never does cart arithmetic itself.
class CartRepository {
  CartRepository(this._api);
  final ApiClient _api;

  Future<Cart> get() async => Cart.fromJson(await _api.get('/cart'));
  Future<Cart> add(String productId, {int quantity = 1}) async => Cart.fromJson(
    await _api.post(
      '/cart/items',
      body: {'product_id': productId, 'quantity': quantity},
    ),
  );
  Future<Cart> setQuantity(String itemId, int quantity) async => Cart.fromJson(
    await _api.put('/cart/items/$itemId', body: {'quantity': quantity}),
  );
  Future<Cart> remove(String itemId) async =>
      Cart.fromJson(await _api.delete('/cart/items/$itemId'));
  Future<Cart> clear() async => Cart.fromJson(await _api.delete('/cart/clear'));
}
