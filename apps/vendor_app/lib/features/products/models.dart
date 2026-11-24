import '../../core/utils/json.dart';

class Category {
  const Category({
    required this.id,
    required this.kind,
    required this.name,
    this.parentId,
  });
  final String id, kind, name;
  final String? parentId;
  factory Category.fromJson(Map<String, dynamic> j) => Category(
    id: j['id'] as String,
    kind: (j['kind'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    parentId: asStringOrNull(j['parent_id']),
  );
}

const productKinds = {
  'new_cycle': 'New cycles',
  'used_cycle': 'Used cycles',
  'spare_part': 'Spare parts',
  'accessory': 'Accessories',
};

class ProductImage {
  const ProductImage({
    required this.id,
    required this.url,
    required this.path,
    required this.isPrimary,
    required this.sortOrder,
  });
  final String id, url, path;
  final bool isPrimary;
  final int sortOrder;
  factory ProductImage.fromJson(Map<String, dynamic> j) => ProductImage(
    id: j['id'] as String,
    url: (j['url'] as String?) ?? '',
    path: (j['storage_path'] as String?) ?? '',
    isPrimary: j['is_primary'] == true,
    sortOrder: asInt(j['sort_order']),
  );
}

/// Owner view of a listing. `approval_status` / moderation fields are READ-ONLY here (admin decides).
class VendorProduct {
  const VendorProduct({
    required this.id,
    required this.name,
    this.brand,
    this.model,
    required this.productType,
    required this.categoryId,
    this.categoryName,
    required this.condition,
    required this.price,
    required this.isAvailable,
    required this.inStock,
    required this.stock,
    this.imageUrl,
    this.description,
    required this.specifications,
    required this.images,
    required this.isActive,
    required this.approvalStatus,
    this.reviewNotes,
  });
  final String id, name, productType, categoryId, condition, approvalStatus;
  final String? brand, model, categoryName, imageUrl, description, reviewNotes;
  final double price;
  final bool isAvailable, inStock, isActive;
  final int stock;
  final Map<String, dynamic> specifications;
  final List<ProductImage> images;

  bool get isRejected => approvalStatus == 'rejected';
  bool get isPendingApproval => approvalStatus == 'pending';
  bool get isLive => approvalStatus == 'approved' && isActive && isAvailable;

  /// One badge for the list: what the customer-facing state of this listing is.
  String get displayStatus {
    if (isRejected) return 'rejected';
    if (isPendingApproval) return 'pending';
    if (!isActive) return 'inactive';
    return 'approved';
  }

  factory VendorProduct.fromJson(Map<String, dynamic> j) => VendorProduct(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    brand: asStringOrNull(j['brand']),
    model: asStringOrNull(j['model']),
    productType: (j['product_type'] as String?) ?? '',
    categoryId: (j['category_id'] as String?) ?? '',
    categoryName: asStringOrNull(asMap(j['category'])['name']),
    condition: (j['condition'] as String?) ?? 'new',
    price: asDouble(j['price']),
    isAvailable: j['is_available'] == true,
    inStock: j['in_stock'] == true,
    stock: asInt(j['stock_quantity']),
    imageUrl: asStringOrNull(j['primary_image_url']),
    description: asStringOrNull(j['description']),
    specifications: asMap(j['specifications']),
    images: asMapList(j['images']).map(ProductImage.fromJson).toList(),
    isActive: j['is_active'] != false,
    approvalStatus: (j['approval_status'] as String?) ?? 'pending',
    reviewNotes: asStringOrNull(j['review_notes']),
  );
}

/// What the vendor may send. No vendor id, product type, approval or featured fields exist here.
class ProductInput {
  const ProductInput({
    required this.categoryId,
    required this.name,
    this.description,
    this.brand,
    this.model,
    required this.specifications,
    required this.condition,
    required this.price,
    required this.stock,
    required this.isAvailable,
  });
  final String categoryId, name, condition;
  final String? description, brand, model;
  final Map<String, dynamic> specifications;
  final double price;
  final int stock;
  final bool isAvailable;

  Map<String, dynamic> toJson() => {
    'category_id': categoryId,
    'name': name,
    'description': (description ?? '').isEmpty ? null : description,
    'brand': (brand ?? '').isEmpty ? null : brand,
    'model': (model ?? '').isEmpty ? null : model,
    'specifications': specifications,
    'condition': condition,
    'price': price,
    'stock_quantity': stock,
    'is_available': isAvailable,
  };
}
