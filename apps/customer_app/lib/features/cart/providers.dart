import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/providers.dart';
import 'models.dart';

/// The cart lives on the server. Every action returns the recomputed cart, which becomes the state: totals shown are always the backend's.
class CartNotifier extends AsyncNotifier<Cart> {
  @override
  Future<Cart> build() async {
    final uid = ref.watch(currentUserIdProvider);
    if (uid == null) return Cart.empty;
    return ref.read(cartRepositoryProvider).get();
  }

  Future<Cart> _apply(Future<Cart> Function() call) async {
    final cart = await call();
    state = AsyncData(cart);
    return cart;
  }

  Future<void> reload() async {
    state = await AsyncValue.guard(
      () => ref.read(cartRepositoryProvider).get(),
    );
  }

  Future<Cart> add(String productId, {int quantity = 1}) => _apply(
    () => ref.read(cartRepositoryProvider).add(productId, quantity: quantity),
  );
  Future<Cart> setQuantity(String itemId, int quantity) => _apply(
    () => ref.read(cartRepositoryProvider).setQuantity(itemId, quantity),
  );
  Future<Cart> remove(String itemId) =>
      _apply(() => ref.read(cartRepositoryProvider).remove(itemId));
  Future<Cart> clear() =>
      _apply(() => ref.read(cartRepositoryProvider).clear());
}

final cartProvider = AsyncNotifierProvider<CartNotifier, Cart>(
  CartNotifier.new,
);
final cartCountProvider = Provider<int>(
  (ref) => ref
      .watch(cartProvider)
      .maybeWhen(data: (c) => c.totalQuantity, orElse: () => 0),
);
