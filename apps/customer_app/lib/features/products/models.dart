import '../../core/utils/json.dart';

class Seller {
  const Seller({
    required this.id,
    required this.businessName,
    this.city,
    this.state,
    this.pickupAvailable = false,
  });
  final String id, businessName;
  final String? city, state;
  final bool pickupAvailable;

  factory Seller.fromJson(Map<String, dynamic> j) => Seller(
    id: j['id'] as String,
    businessName: (j['business_name'] as String?) ?? '',
    city: asStringOrNull(j['city']),
    state: asStringOrNull(j['state']),
    pickupAvailable: j['pickup_available'] == true,
  );
  String get location =>
      [city, state].whereType<String>().where((s) => s.isNotEmpty).join(', ');
}

class Category {
  const Category({
    required this.id,
    this.parentId,
    required this.kind,
    required this.name,
    required this.slug,
    this.description,
    this.imageUrl,
    this.productCount,
  });
  final String id, kind, name, slug;
  final String? parentId, description, imageUrl;
  final int? productCount;

  factory Category.fromJson(Map<String, dynamic> j) => Category(
    id: j['id'] as String,
    parentId: asStringOrNull(j['parent_id']),
    kind: j['kind'] as String,
    name: j['name'] as String,
    slug: (j['slug'] as String?) ?? '',
    description: asStringOrNull(j['description']),
    imageUrl: asStringOrNull(j['image_url']),
    productCount: j['product_count'] == null ? null : asInt(j['product_count']),
  );
}

class ProductSummary {
  const ProductSummary({
    required this.id,
    required this.name,
    this.brand,
    this.model,
    required this.productType,
    required this.condition,
    required this.price,
    required this.isAvailable,
    required this.inStock,
    required this.stockQuantity,
    required this.isFeatured,
    this.imageUrl,
    this.vendor,
  });
  final String id, name, productType, condition;
  final String? brand, model, imageUrl;
  final double price;
  final bool isAvailable, inStock, isFeatured;
  final int stockQuantity;
  final Seller? vendor;

  factory ProductSummary.fromJson(Map<String, dynamic> j) => ProductSummary(
    id: j['id'] as String,
    name: j['name'] as String,
    brand: asStringOrNull(j['brand']),
    model: asStringOrNull(j['model']),
    productType: (j['product_type'] as String?) ?? '',
    condition: (j['condition'] as String?) ?? 'new',
    price: asDouble(j['price']),
    isAvailable: j['is_available'] == true,
    inStock: j['in_stock'] == true,
    stockQuantity: asInt(j['stock_quantity']),
    isFeatured: j['is_featured'] == true,
    imageUrl: asStringOrNull(j['primary_image_url']),
    vendor: j['vendor'] is Map ? Seller.fromJson(asMap(j['vendor'])) : null,
  );
  bool get isUsed => condition == 'used';
}

class ProductImage {
  const ProductImage({required this.id, required this.url, this.altText});
  final String id, url;
  final String? altText;
  factory ProductImage.fromJson(Map<String, dynamic> j) => ProductImage(
    id: j['id'] as String,
    url: j['url'] as String,
    altText: asStringOrNull(j['alt_text']),
  );
}

class ProductDetail {
  const ProductDetail({
    required this.summary,
    this.description,
    required this.specifications,
    this.categoryName,
    required this.images,
  });
  final ProductSummary summary;
  final String? description, categoryName;
  final Map<String, dynamic> specifications;
  final List<ProductImage> images;

  factory ProductDetail.fromJson(Map<String, dynamic> j) => ProductDetail(
    summary: ProductSummary.fromJson(j),
    description: asStringOrNull(j['description']),
    specifications: asMap(j['specifications']),
    categoryName: j['category'] is Map
        ? asStringOrNull(asMap(j['category'])['name'])
        : null,
    images: asMapList(j['images']).map(ProductImage.fromJson).toList(),
  );
}

enum ProductSort {
  relevance('relevance', 'Relevance'),
  priceLow('price_low_to_high', 'Price: low to high'),
  priceHigh('price_high_to_low', 'Price: high to low'),
  newest('newest', 'Newest first');

  const ProductSort(this.api, this.label);
  final String api, label;
}

/// Everything the product list sends to the backend. The backend does the filtering; the app never filters results itself.
class ProductQuery {
  const ProductQuery({
    this.q,
    this.categoryId,
    this.productType,
    this.minPrice,
    this.maxPrice,
    this.brand,
    this.condition,
    this.inStock,
    this.sort = ProductSort.relevance,
  });
  final String? q, categoryId, productType, brand, condition;
  final double? minPrice, maxPrice;
  final bool? inStock;
  final ProductSort sort;

  ProductQuery copyWith({
    String? q,
    String? categoryId,
    String? productType,
    double? minPrice,
    double? maxPrice,
    String? brand,
    String? condition,
    bool? inStock,
    ProductSort? sort,
    bool clearPrice = false,
    bool clearBrand = false,
    bool clearCondition = false,
    bool clearStock = false,
    bool clearCategory = false,
  }) => ProductQuery(
    q: q ?? this.q,
    categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
    productType: productType ?? this.productType,
    minPrice: clearPrice ? null : (minPrice ?? this.minPrice),
    maxPrice: clearPrice ? null : (maxPrice ?? this.maxPrice),
    brand: clearBrand ? null : (brand ?? this.brand),
    condition: clearCondition ? null : (condition ?? this.condition),
    inStock: clearStock ? null : (inStock ?? this.inStock),
    sort: sort ?? this.sort,
  );

  Map<String, dynamic> toQuery(int page, {int limit = 20}) => {
    'q': q,
    'category_id': categoryId,
    'product_type': productType,
    'min_price': minPrice,
    'max_price': maxPrice,
    'brand': brand,
    'condition': condition,
    'in_stock': inStock,
    'sort_by': sort.api,
    'page': page,
    'limit': limit,
  };

  int get activeFilterCount => [
    minPrice != null || maxPrice != null,
    brand != null && brand!.isNotEmpty,
    condition != null,
    inStock != null,
  ].where((b) => b).length;

  @override
  bool operator ==(Object other) =>
      other is ProductQuery &&
      other.q == q &&
      other.categoryId == categoryId &&
      other.productType == productType &&
      other.minPrice == minPrice &&
      other.maxPrice == maxPrice &&
      other.brand == brand &&
      other.condition == condition &&
      other.inStock == inStock &&
      other.sort == sort;
  @override
  int get hashCode => Object.hash(
    q,
    categoryId,
    productType,
    minPrice,
    maxPrice,
    brand,
    condition,
    inStock,
    sort,
  );
}

class PromoBanner {
  const PromoBanner({
    required this.id,
    required this.title,
    this.subtitle,
    required this.imageUrl,
    required this.actionType,
    this.actionValue,
  });
  final String id, title, imageUrl, actionType;
  final String? subtitle, actionValue;
  factory PromoBanner.fromJson(Map<String, dynamic> j) => PromoBanner(
    id: j['id'] as String,
    title: j['title'] as String,
    subtitle: asStringOrNull(j['subtitle']),
    imageUrl: j['image_url'] as String,
    actionType: (j['action_type'] as String?) ?? 'none',
    actionValue: asStringOrNull(j['action_value']),
  );
}
