import '../../core/api/api_client.dart';
import '../../core/models/paged.dart';
import '../../core/utils/json.dart';
import 'models.dart';

class CatalogRepository {
  CatalogRepository(this._api);
  final ApiClient _api;

  Future<Paged<ProductSummary>> products(
    ProductQuery q,
    int page, {
    int limit = 20,
  }) async => Paged.fromJson(
    await _api.get(
      '/products',
      query: q.toQuery(page, limit: limit),
      auth: false,
    ),
    ProductSummary.fromJson,
  );

  Future<List<ProductSummary>> featured({int limit = 10}) async => asMapList(
    await _api.get('/products/featured', query: {'limit': limit}, auth: false),
  ).map(ProductSummary.fromJson).toList();

  Future<ProductDetail> product(String id) async => ProductDetail.fromJson(
    asMap(await _api.get('/products/$id', auth: false)),
  );

  Future<List<Category>> categories({
    String? kind,
    String? parentId,
    bool rootOnly = false,
    bool counts = true,
  }) async => asMapList(
    await _api.get(
      '/categories',
      query: {
        'kind': kind,
        'parent_id': parentId,
        'root_only': rootOnly ? true : null,
        'include_counts': counts,
      },
      auth: false,
    ),
  ).map(Category.fromJson).toList();

  Future<List<PromoBanner>> banners() async => asMapList(
    await _api.get('/banners', auth: false),
  ).map(PromoBanner.fromJson).toList();
}
