import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../services/models.dart';
import 'models.dart';

// Home + categories data. Plain FutureProviders: cached while the app is open, refreshed by pull-to-refresh (ref.invalidate).
final bannersProvider = FutureProvider<List<PromoBanner>>(
  (ref) => ref.read(catalogRepositoryProvider).banners(),
);
final rootCategoriesProvider = FutureProvider<List<Category>>(
  (ref) => ref.read(catalogRepositoryProvider).categories(rootOnly: true),
);
final featuredProductsProvider = FutureProvider<List<ProductSummary>>(
  (ref) => ref.read(catalogRepositoryProvider).featured(limit: 10),
);
final latestProductsProvider = FutureProvider<List<ProductSummary>>(
  (ref) async =>
      (await ref
              .read(catalogRepositoryProvider)
              .products(
                const ProductQuery(sort: ProductSort.newest),
                1,
                limit: 10,
              ))
          .items,
);
final subCategoriesProvider = FutureProvider.family<List<Category>, String>(
  (ref, parentId) => ref
      .read(catalogRepositoryProvider)
      .categories(parentId: parentId, counts: false),
);
final productDetailProvider = FutureProvider.family
    .autoDispose<ProductDetail, String>(
      (ref, id) => ref.read(catalogRepositoryProvider).product(id),
    );
final serviceCategoriesProvider = FutureProvider<List<ServiceCategory>>(
  (ref) => ref.read(serviceRepositoryProvider).categories(),
);
