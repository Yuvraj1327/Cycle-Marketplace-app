import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'models.dart';

final categoriesProvider = FutureProvider<List<Category>>(
  (ref) => ref.read(productRepositoryProvider).categories(),
);
final productDetailProvider = FutureProvider.family
    .autoDispose<VendorProduct, String>(
      (ref, id) => ref.read(productRepositoryProvider).get(id),
    );
