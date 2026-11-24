import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../cart/providers.dart';
import 'models.dart';
import 'providers.dart';

class WishlistScreen extends ConsumerStatefulWidget {
  const WishlistScreen({super.key});
  @override
  ConsumerState<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends ConsumerState<WishlistScreen> {
  final _busy = <String>{};

  Future<void> _do(String id, Future<void> Function() f, {String? ok}) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await f();
      if (ok != null && mounted) showSnack(context, ok);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wl = ref.watch(wishlistProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wishlist'),
        actions: const [CartButton()],
      ),
      body: AsyncBody<Wishlist>(
        value: wl,
        onRetry: () => ref.read(wishlistProvider.notifier).reload(),
        builder: (w) => w.items.isEmpty
            ? EmptyState(
                icon: Icons.favorite_border,
                title: 'Nothing saved yet',
                message: 'Tap the heart on any product to keep it here.',
                actionLabel: 'Browse products',
                onAction: () => context.go('/home'),
              )
            : RefreshIndicator(
                onRefresh: () => ref.read(wishlistProvider.notifier).reload(),
                child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: w.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final it = w.items[i];
                    final p = it.product;
                    final busy = _busy.contains(it.id);
                    return Card(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: p == null
                            ? null
                            : () => context.push('/product/${p.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 84,
                                height: 84,
                                child: AppNetworkImage(p?.imageUrl),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p?.name ??
                                          'This product is no longer listed',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    if (p != null) PriceText(p.price),
                                    if (!it.isAvailable)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: StatusChip(
                                          it.status,
                                          label: it.status == 'not_listed'
                                              ? 'No longer listed'
                                              : it.status == 'out_of_stock'
                                              ? 'Out of stock'
                                              : 'Unavailable',
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        if (it.isAvailable)
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              style: OutlinedButton.styleFrom(
                                                minimumSize:
                                                    const Size.fromHeight(38),
                                              ),
                                              onPressed: busy
                                                  ? null
                                                  : () => _do(
                                                      it.id,
                                                      () async => ref
                                                          .read(
                                                            cartProvider
                                                                .notifier,
                                                          )
                                                          .add(it.productId),
                                                      ok: 'Added to cart',
                                                    ),
                                              icon: const Icon(
                                                Icons.add_shopping_cart,
                                                size: 18,
                                              ),
                                              label: const Text('Add to cart'),
                                            ),
                                          )
                                        else
                                          const Spacer(),
                                        IconButton(
                                          tooltip: 'Remove',
                                          onPressed: busy
                                              ? null
                                              : () => _do(
                                                  it.id,
                                                  () => ref
                                                      .read(
                                                        wishlistProvider
                                                            .notifier,
                                                      )
                                                      .removeItem(it.id),
                                                ),
                                          icon: const Icon(
                                            Icons.favorite,
                                            color: AppColors.danger,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
