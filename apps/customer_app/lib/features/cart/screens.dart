import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import 'models.dart';
import 'providers.dart';

class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});
  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  final _busy =
      <
        String
      >{}; // item ids with an update in flight (prevents double taps / duplicate requests)
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(cartProvider.notifier).reload(),
    ); // always show the latest prices / stock when the cart opens
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _clear() async {
    if (!await confirmDialog(
      context,
      title: 'Clear cart?',
      message: 'All items will be removed from your cart.',
      confirmLabel: 'Clear',
      destructive: true,
    )) {
      return;
    }
    setState(() => _clearing = true);
    try {
      await ref.read(cartProvider.notifier).clear();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final data = cart.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My cart'),
        actions: [
          if (data != null && !data.isEmpty)
            TextButton(
              onPressed: _clearing ? null : _clear,
              child: const Text('Clear'),
            ),
        ],
      ),
      body: cart.when(
        loading: () => data == null ? const LoadingView() : _content(data),
        error: (e, _) => data == null
            ? ErrorView(
                e,
                onRetry: () => ref.read(cartProvider.notifier).reload(),
              )
            : _content(data),
        data: _content,
      ),
    );
  }

  Widget _content(Cart cart) {
    if (cart.isEmpty) {
      return EmptyState(
        icon: Icons.shopping_cart_outlined,
        title: 'Your cart is empty',
        message: 'Browse cycles, spare parts and accessories to get started.',
        actionLabel: 'Start shopping',
        onAction: () => context.go('/home'),
      );
    }
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(cartProvider.notifier).reload(),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                if (cart.hasUnavailable)
                  const _Notice(
                    'Some items are no longer available or exceed the stock. Remove or reduce them to continue.',
                    AppColors.danger,
                  ),
                if (cart.hasPriceChanges)
                  const _Notice(
                    'Prices changed for some items since you added them. The prices below are current.',
                    AppColors.warning,
                  ),
                if (cart.multiVendor)
                  const _Notice(
                    'Your cart has items from more than one seller.',
                    AppColors.info,
                  ),
                for (final item in cart.items) ...[
                  _CartTile(
                    item: item,
                    busy: _busy.contains(item.id),
                    onQty: (q) => _run(
                      item.id,
                      () async => ref
                          .read(cartProvider.notifier)
                          .setQuantity(item.id, q),
                    ),
                    onRemove: () => _run(
                      item.id,
                      () async =>
                          ref.read(cartProvider.notifier).remove(item.id),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: context.palette.surface,
              border: Border(top: BorderSide(color: context.palette.line)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AmountRow(
                  'Subtotal (${cart.totalQuantity} item${cart.totalQuantity == 1 ? '' : 's'})',
                  cart.subtotal,
                  bold: true,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Delivery charges and discounts are calculated at checkout.',
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: cart.canCheckout
                      ? () => context.push('/checkout')
                      : null,
                  child: const Text('Proceed to checkout'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .4)),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ],
    ),
  );
}

class _CartTile extends StatelessWidget {
  const _CartTile({
    required this.item,
    required this.busy,
    required this.onQty,
    required this.onRemove,
  });
  final CartItem item;
  final bool busy;
  final ValueChanged<int> onQty;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = item.product;
    final problem = !item.isOk;
    final label = switch (item.status) {
      'not_listed' => 'No longer available',
      'unavailable' => 'Currently unavailable',
      'out_of_stock' => 'Out of stock',
      'insufficient_stock' => 'Only ${item.availableQuantity} available',
      _ => null,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                    p?.name ?? 'Unavailable product',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (p?.vendor != null)
                    Text(
                      'Sold by ${p!.vendor!.businessName}',
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 4),
                  if (item.unitPrice != null)
                    Row(
                      children: [
                        PriceText(item.unitPrice!),
                        if (item.priceChanged &&
                            item.previousPrice != null) ...[
                          const SizedBox(width: 6),
                          PriceText(
                            item.previousPrice!,
                            strike: true,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  if (label != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: StatusChip(item.status, label: label),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (p != null && !problem ||
                          item.status == 'insufficient_stock')
                        QuantityStepper(
                          value: item.quantity,
                          max: item.availableQuantity.clamp(1, 99),
                          busy: busy,
                          onChanged: onQty,
                        ),
                      const Spacer(),
                      if (item.lineTotal != null && item.isOk)
                        Text(
                          money(item.lineTotal!),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      IconButton(
                        tooltip: 'Remove',
                        onPressed: busy ? null : onRemove,
                        icon: const Icon(
                          Icons.delete_outline,
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
    );
  }
}
