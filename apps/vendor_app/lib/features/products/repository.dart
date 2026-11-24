import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class ProductFilter {
  const ProductFilter({
    this.q,
    this.productType,
    this.approvalStatus,
    this.isActive,
    this.inStock,
  });
  final String? q, productType, approvalStatus;
  final bool? isActive, inStock;
}

class ProductRepository {
  ProductRepository(this._api);
  final ApiClient _api;

  Future<Paged<VendorProduct>> list(
    ProductFilter f,
    int page, {
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/vendor/products',
      query: {
        'q': f.q,
        'product_type': f.productType,
        'approval_status': f.approvalStatus,
        'is_active': f.isActive,
        'in_stock': f.inStock,
        'page': page,
        'limit': limit,
      },
    ),
    VendorProduct.fromJson,
  );

  Future<VendorProduct> get(String id) async =>
      VendorProduct.fromJson(asMap(await _api.get('/vendor/products/$id')));
  Future<VendorProduct> create(ProductInput p) async => VendorProduct.fromJson(
    asMap(await _api.post('/vendor/products', body: p.toJson())),
  );
  Future<VendorProduct> replace(
    String id,
    ProductInput p, {
    required bool isActive,
  }) async => VendorProduct.fromJson(
    asMap(
      await _api.put(
        '/vendor/products/$id',
        body: {...p.toJson(), 'is_active': isActive},
      ),
    ),
  );
  Future<VendorProduct> patch(String id, Map<String, dynamic> changes) async =>
      VendorProduct.fromJson(
        asMap(await _api.patch('/vendor/products/$id', body: changes)),
      );
  Future<void> delete(String id) async => _api.delete('/vendor/products/$id');

  Future<List<Category>> categories() async => asMapList(
    await _api.get(
      '/categories',
      query: {'include_counts': false},
      auth: false,
    ),
  ).map(Category.fromJson).toList();

  // images (binary already uploaded to Storage with the vendor's own session)
  Future<ProductImage> registerImage(
    String productId,
    String path, {
    bool primary = false,
  }) async => ProductImage.fromJson(
    asMap(
      await _api.post(
        '/vendor/products/$productId/images',
        body: {'storage_path': path, 'is_primary': primary},
      ),
    ),
  );
  Future<List<ProductImage>> images(String productId) async => asMapList(
    await _api.get('/vendor/products/$productId/images'),
  ).map(ProductImage.fromJson).toList();
  Future<List<ProductImage>> reorder(
    String productId,
    List<String> ids,
  ) async => asMapList(
    await _api.put(
      '/vendor/products/$productId/images/order',
      body: {'image_ids': ids},
    ),
  ).map(ProductImage.fromJson).toList();
  Future<ProductImage> makePrimary(String productId, String imageId) async =>
      ProductImage.fromJson(
        asMap(
          await _api.patch(
            '/vendor/products/$productId/images/$imageId',
            body: {'is_primary': true},
          ),
        ),
      );
  Future<void> removeImage(String productId, String imageId) async =>
      _api.delete('/vendor/products/$productId/images/$imageId');
}
