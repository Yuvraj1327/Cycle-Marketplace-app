import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../features/cart/providers.dart';
import '../../features/notifications/providers.dart';
import '../../features/products/models.dart';
import '../../features/services/models.dart';
import '../../features/wishlist/providers.dart';
import '../utils/format.dart';
import 'common.dart';

class ProductCard extends ConsumerWidget {
  const ProductCard(this.product, {super.key, this.width});
  final ProductSummary product;
  final double? width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wished = ref.watch(wishlistedProvider(product.id));
    final p = product;
    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/product/${p.id}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AppNetworkImage(p.imageUrl, radius: 0),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Material(
                        color: Colors.white.withValues(alpha: .92),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () async {
                            try {
                              final added = await ref
                                  .read(wishlistProvider.notifier)
                                  .toggle(p.id);
                              if (context.mounted) {
                                showSnack(
                                  context,
                                  added
                                      ? 'Saved to wishlist'
                                      : 'Removed from wishlist',
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                showSnack(context, errorText(e), error: true);
                              }
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              wished ? Icons.favorite : Icons.favorite_border,
                              size: 20,
                              color: wished
                                  ? AppColors.danger
                                  : context.palette.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (p.isUsed)
                      const Positioned(
                        top: 8,
                        left: 8,
                        child: _Tag('Used', AppColors.warning),
                      ),
                    if (!p.inStock)
                      const Positioned(
                        bottom: 8,
                        left: 8,
                        child: _Tag('Out of stock', AppColors.danger),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if ((p.brand ?? '').isNotEmpty)
                      Text(
                        [p.brand, p.model].whereType<String>().join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                    const SizedBox(height: 4),
                    PriceText(p.price),
                    if (p.vendor != null)
                      Text(
                        'by ${p.vendor!.businessName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class ServiceCard extends StatelessWidget {
  const ServiceCard(this.service, {super.key});
  final ServiceItem service;
  @override
  Widget build(BuildContext context) {
    final s = service;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/service/${s.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: context.palette.primary.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.build_circle_outlined,
                      color: context.palette.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (s.provider != null)
                          Text(
                            s.provider!.businessName,
                            style: TextStyle(color: context.palette.muted),
                          ),
                      ],
                    ),
                  ),
                  PriceText(s.price),
                ],
              ),
              if ((s.description ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    s.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.palette.muted),
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _Meta(Icons.schedule, s.durationLabel),
                  if (s.provider?.location.isNotEmpty == true)
                    _Meta(Icons.place_outlined, s.provider!.location),
                  if (s.provider?.pickupAvailable == true)
                    const _Meta(
                      Icons.local_shipping_outlined,
                      'Doorstep pickup',
                    ),
                  if (!s.isAvailable)
                    const StatusChip(
                      'unavailable',
                      label: 'Currently unavailable',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: context.palette.muted),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(color: context.palette.muted, fontSize: 12)),
    ],
  );
}

/// App-bar cart icon with a live item-count badge (from the server cart).
class CartButton extends ConsumerWidget {
  const CartButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(cartCountProvider);
    return IconButton(
      tooltip: 'Cart',
      onPressed: () => context.push('/cart'),
      icon: Badge(
        isLabelVisible: n > 0,
        label: Text(n > 99 ? '99+' : '$n'),
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}

class NotificationsButton extends ConsumerWidget {
  const NotificationsButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref
        .watch(unreadCountProvider)
        .maybeWhen(data: (v) => v, orElse: () => 0);
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => context.push('/notifications'),
      icon: Badge(
        isLabelVisible: n > 0,
        label: Text('$n'),
        child: const Icon(Icons.notifications_none),
      ),
    );
  }
}

/// A labelled row used on detail screens.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.bold = false});
  final String label;
  final String value;
  final bool bold;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: TextStyle(color: context.palette.muted)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

class AmountRow extends StatelessWidget {
  const AmountRow(
    this.label,
    this.amount, {
    super.key,
    this.bold = false,
    this.negative = false,
  });
  final String label;
  final num amount;
  final bool bold, negative;
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
      fontSize: bold ? 17 : 14,
      color: negative ? AppColors.success : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text('${negative ? '− ' : ''}${money(amount)}', style: style),
        ],
      ),
    );
  }
}
