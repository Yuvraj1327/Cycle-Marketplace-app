import '../../core/utils/json.dart';
import '../products/models.dart';

class CartProduct {
  const CartProduct({
    required this.id,
    required this.name,
    this.brand,
    this.model,
    required this.condition,
    required this.price,
    required this.stockQuantity,
    this.imageUrl,
    this.vendor,
  });
  final String id, name, condition;
  final String? brand, model, imageUrl;
  final double price;
  final int stockQuantity;
  final Seller? vendor;
  factory CartProduct.fromJson(Map<String, dynamic> j) => CartProduct(
    id: j['id'] as String,
    name: j['name'] as String,
    brand: asStringOrNull(j['brand']),
    model: asStringOrNull(j['model']),
    condition: (j['condition'] as String?) ?? 'new',
    price: asDouble(j['price']),
    stockQuantity: asInt(j['stock_quantity']),
    imageUrl: asStringOrNull(j['primary_image_url']),
    vendor: j['vendor'] is Map ? Seller.fromJson(asMap(j['vendor'])) : null,
  );
}

class CartItem {
  const CartItem({
    required this.id,
    required this.productId,
    required this.quantity,
    this.product,
    this.unitPrice,
    this.lineTotal,
    required this.status,
    required this.availableQuantity,
    required this.priceChanged,
    this.previousPrice,
  });
  final String id, productId, status;
  final int quantity, availableQuantity;
  final CartProduct? product;
  final double? unitPrice, lineTotal, previousPrice;
  final bool priceChanged;
  bool get isOk => status == 'ok';
  factory CartItem.fromJson(Map<String, dynamic> j) => CartItem(
    id: j['id'] as String,
    productId: j['product_id'] as String,
    quantity: asInt(j['quantity']),
    product: j['product'] is Map
        ? CartProduct.fromJson(asMap(j['product']))
        : null,
    unitPrice: asDoubleOrNull(j['unit_price']),
    lineTotal: asDoubleOrNull(j['line_total']),
    status: (j['status'] as String?) ?? 'ok',
    availableQuantity: asInt(j['available_quantity']),
    priceChanged: j['price_changed'] == true,
    previousPrice: asDoubleOrNull(j['previous_price']),
  );
}

class Cart {
  const Cart({
    required this.id,
    required this.items,
    required this.distinctItems,
    required this.totalQuantity,
    required this.subtotal,
    required this.multiVendor,
    required this.hasUnavailable,
    required this.hasPriceChanges,
  });
  final String id;
  final List<CartItem> items;
  final int distinctItems, totalQuantity;
  final double subtotal;
  final bool multiVendor, hasUnavailable, hasPriceChanges;
  bool get isEmpty => items.isEmpty;
  bool get canCheckout => items.isNotEmpty && !hasUnavailable;

  static const empty = Cart(
    id: '',
    items: [],
    distinctItems: 0,
    totalQuantity: 0,
    subtotal: 0,
    multiVendor: false,
    hasUnavailable: false,
    hasPriceChanges: false,
  );

  factory Cart.fromJson(dynamic json) {
    final j = asMap(json);
    final s = asMap(j['summary']);
    return Cart(
      id: j['id'] as String,
      items: asMapList(j['items']).map(CartItem.fromJson).toList(),
      distinctItems: asInt(s['distinct_items']),
      totalQuantity: asInt(s['total_quantity']),
      subtotal: asDouble(s['subtotal']),
      multiVendor: s['multi_vendor'] == true,
      hasUnavailable: s['has_unavailable_items'] == true,
      hasPriceChanges: s['has_price_changes'] == true,
    );
  }
}
