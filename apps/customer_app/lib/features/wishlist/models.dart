import '../../core/utils/json.dart';
import '../cart/models.dart';

class WishlistItem {
  const WishlistItem({
    required this.id,
    required this.productId,
    this.product,
    required this.status,
  });
  final String id, productId, status;
  final CartProduct? product;
  bool get isAvailable => status == 'ok';
  factory WishlistItem.fromJson(Map<String, dynamic> j) => WishlistItem(
    id: j['id'] as String,
    productId: j['product_id'] as String,
    product: j['product'] is Map
        ? CartProduct.fromJson(asMap(j['product']))
        : null,
    status: (j['status'] as String?) ?? 'ok',
  );
}

class Wishlist {
  const Wishlist(this.items);
  final List<WishlistItem> items;
  static const empty = Wishlist([]);
  factory Wishlist.fromJson(dynamic json) => Wishlist(
    asMapList(asMap(json)['items']).map(WishlistItem.fromJson).toList(),
  );
  WishlistItem? byProduct(String productId) {
    for (final i in items) {
      if (i.productId == productId) return i;
    }
    return null;
  }
}
