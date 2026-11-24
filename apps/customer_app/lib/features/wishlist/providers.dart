import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/providers.dart';
import 'models.dart';

class WishlistNotifier extends AsyncNotifier<Wishlist> {
  @override
  Future<Wishlist> build() async {
    if (ref.watch(currentUserIdProvider) == null) return Wishlist.empty;
    return ref.read(wishlistRepositoryProvider).get();
  }

  Future<void> reload() async => state = await AsyncValue.guard(
    () => ref.read(wishlistRepositoryProvider).get(),
  );

  /// Adds or removes on the server, then re-reads the server's list so the UI never drifts from the backend.
  Future<bool> toggle(String productId) async {
    final repo = ref.read(wishlistRepositoryProvider);
    final existing = state.value?.byProduct(productId);
    if (existing != null) {
      await repo.remove(existing.id);
    } else {
      await repo.add(productId);
    }
    await reload();
    return existing == null;
  }

  Future<void> removeItem(String itemId) async {
    await ref.read(wishlistRepositoryProvider).remove(itemId);
    await reload();
  }
}

final wishlistProvider = AsyncNotifierProvider<WishlistNotifier, Wishlist>(
  WishlistNotifier.new,
);
final wishlistedProvider = Provider.family<bool, String>(
  (ref, productId) => ref
      .watch(wishlistProvider)
      .maybeWhen(
        data: (w) => w.byProduct(productId) != null,
        orElse: () => false,
      ),
);
