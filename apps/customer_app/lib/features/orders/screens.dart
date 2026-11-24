import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../checkout/screens.dart';
import 'models.dart';
import 'providers.dart';

class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});
  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  String? _status;
  late PagedController<OrderSummary> _paged = _make();

  PagedController<OrderSummary> _make() => PagedController(
    (p) => ref.read(orderRepositoryProvider).list(p, status: _status),
  );

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  void _setStatus(String? s) {
    final old = _paged;
    setState(() {
      _status = s;
      _paged = _make();
    });
    old.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      ordersTickProvider,
      (_, _) => _paged.refresh(),
    ); // reload after an order is placed / cancelled elsewhere
    const filters = [
      (null, 'All'),
      ('pending', 'Pending'),
      ('confirmed', 'Confirmed'),
      ('completed', 'Completed'),
      ('cancelled', 'Cancelled'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('My orders')),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: 8,
              ),
              children: [
                for (final f in filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _status == f.$1,
                      onSelected: (_) => _setStatus(f.$1),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: PagedListView<OrderSummary>(
              key: ValueKey(_paged),
              controller: _paged,
              empty: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: _status == null
                    ? 'No orders yet'
                    : 'No ${humanize(_status!).toLowerCase()} orders',
                message: 'Your purchases will show up here.',
                actionLabel: 'Start shopping',
                onAction: () => context.go('/home'),
              ),
              itemBuilder: (context, o) => Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/orders/${o.id}'),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                o.number,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            StatusChip(o.status),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${dateShort(o.createdAt)} · ${o.itemCount} item${o.itemCount == 1 ? '' : 's'}',
                          style: const TextStyle(color: AppColors.muted),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            PriceText(o.total),
                            const Spacer(),
                            Text(
                              o.paymentMethod == 'cod'
                                  ? 'Cash on delivery · '
                                  : 'Online · ',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 12,
                              ),
                            ),
                            StatusChip(o.paymentStatus),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Vendor-order progress steps actually used by the backend. Labels follow the client's wording.
const _steps = [
  ('pending', 'Placed'),
  ('accepted', 'Accepted'),
  ('preparing', 'Processing'),
  ('ready_for_dispatch', 'Ready for dispatch'),
  ('out_for_delivery', 'Shipped'),
  ('delivered', 'Delivered'),
];

class OrderDetailScreen extends ConsumerStatefulWidget {
  const OrderDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  bool _cancelling = false;

  Future<void> _cancel(OrderDetail o) async {
    final reason = await askReason(
      context,
      title: 'Cancel this order?',
      hint: 'Why are you cancelling?',
      action: 'Cancel order',
    );
    if (reason == null || _cancelling) return;
    setState(() => _cancelling = true);
    try {
      await ref
          .read(orderRepositoryProvider)
          .cancel(
            o.summary.id,
            reason,
          ); // nothing is shown as cancelled until the backend says so
      ref.invalidate(orderDetailProvider(widget.id));
      ref.invalidate(orderTrackingProvider(widget.id));
      ref.invalidate(orderPaymentsProvider(widget.id));
      ref.read(ordersTickProvider.notifier).bump();
      if (mounted) showSnack(context, 'Order cancelled');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(orderDetailProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Order details')),
      body: AsyncBody(
        value: order,
        onRetry: () => ref.invalidate(orderDetailProvider(widget.id)),
        builder: (o) {
          final s = o.summary;
          final payments = ref.watch(orderPaymentsProvider(widget.id));
          final tracking = ref.watch(orderTrackingProvider(widget.id));
          final unpaidOnline =
              s.paymentMethod == 'online' &&
              s.status == 'pending' &&
              (s.paymentStatus == 'pending' ||
                  s.paymentStatus == 'processing' ||
                  s.paymentStatus == 'failed');
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(orderDetailProvider(widget.id));
              ref.invalidate(orderTrackingProvider(widget.id));
              ref.invalidate(orderPaymentsProvider(widget.id));
            },
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.number,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    StatusChip(s.status),
                  ],
                ),
                Text(
                  'Placed on ${dateTime(s.createdAt)}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                if (s.status == 'cancelled')
                  _Cancelled(order: o, payments: payments.value ?? const []),
                if (unpaidOnline)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: PayNowCard(orderId: s.id, dueAt: o.paymentDueAt),
                  ),
                const SizedBox(height: 16),
                Text(
                  'Progress',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final v in o.vendorOrders) _VendorProgress(v: v),
                tracking.maybeWhen(
                  data: (t) => t.timeline.isEmpty
                      ? const SizedBox.shrink()
                      : _Timeline(t),
                  orElse: () => const SizedBox.shrink(),
                ),
                const SizedBox(height: 16),
                Text('Items', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final v in o.vendorOrders)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (v.vendorName != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.storefront_outlined,
                                    size: 18,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    v.vendorName!,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          for (final i in v.items)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 52,
                                    height: 52,
                                    child: AppNetworkImage(
                                      i.imageUrl,
                                      radius: 8,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          i.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          '${money(i.unitPrice)} × ${i.quantity}',
                                          style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    money(i.lineTotal),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  'Delivery address',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.place_outlined,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(o.addressText)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Payment', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        AmountRow('Subtotal', o.subtotal),
                        if (o.discount > 0)
                          AmountRow(
                            'Discount${o.couponCode != null ? ' (${o.couponCode})' : ''}',
                            o.discount,
                            negative: true,
                          ),
                        AmountRow('Delivery', o.deliveryCharge),
                        const Divider(height: 18),
                        AmountRow('Total', s.total, bold: true),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              s.paymentMethod == 'cod'
                                  ? 'Cash on delivery'
                                  : 'Online payment',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            StatusChip(s.paymentStatus),
                          ],
                        ),
                        ...payments.maybeWhen(
                          data: (list) => [
                            for (final p in list.where(
                              (p) =>
                                  p.status == 'failed' ||
                                  p.refundedAmount > 0 ||
                                  p.amountDue > 0 && p.method == 'cod',
                            ))
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    p.status == 'failed'
                                        ? 'A payment attempt failed${p.failureReason != null ? ': ${p.failureReason}' : ''}.'
                                        : p.refundedAmount > 0
                                        ? 'Refunded so far: ${money(p.refundedAmount)}'
                                        : 'Cash to pay on delivery: ${money(p.amountDue)}',
                                    style: const TextStyle(
                                      color: AppColors.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                          orElse: () => const [],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (o.canCancel)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                    ),
                    onPressed: _cancelling ? null : () => _cancel(o),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel order'),
                  ),
                if (!o.canCancel &&
                    s.status != 'cancelled' &&
                    s.status != 'completed')
                  const Center(
                    child: Text(
                      'This order can no longer be cancelled because preparation has started.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => context.push('/support/new?orderId=${s.id}'),
                  icon: const Icon(Icons.support_agent),
                  label: const Text('Need help with this order?'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Cancelled extends StatelessWidget {
  const _Cancelled({required this.order, required this.payments});
  final OrderDetail order;
  final List<Payment> payments;
  @override
  Widget build(BuildContext context) {
    final paid = payments
        .where(
          (p) => const {
            'successful',
            'partially_refunded',
            'refunded',
          }.contains(p.status),
        )
        .toList();
    String? refund;
    if (paid.isNotEmpty) {
      final p = paid.first;
      refund = p.status == 'refunded'
          ? 'Your refund of ${money(p.refundedAmount)} has been processed.'
          : p.refundedAmount > 0
          ? 'A partial refund of ${money(p.refundedAmount)} has been processed. The rest is being handled.'
          : 'You paid for this order. A refund request has been raised and is awaiting processing — it is not complete yet.';
    }
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.danger.withValues(alpha: .3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This order was cancelled',
            style: TextStyle(
              color: AppColors.danger,
              fontWeight: FontWeight.w800,
            ),
          ),
          if ((order.summary.cancelledReason ?? '').isNotEmpty)
            Text('Reason: ${order.summary.cancelledReason}'),
          if (order.cancelledAt != null)
            Text(
              dateTime(order.cancelledAt),
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          if (refund != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                refund,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}

class _VendorProgress extends StatelessWidget {
  const _VendorProgress({required this.v});
  final VendorOrder v;
  @override
  Widget build(BuildContext context) {
    final ended = v.status == 'cancelled' || v.status == 'rejected';
    final idx = _steps.indexWhere((s) => s.$1 == v.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    v.vendorName ?? v.number,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                StatusChip(
                  v.status,
                  label:
                      _steps
                          .where((s) => s.$1 == v.status)
                          .map((s) => s.$2)
                          .firstOrNull ??
                      humanize(v.status),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (ended)
              Text(
                v.status == 'rejected'
                    ? 'The seller could not fulfil this order${(v.rejectionReason ?? '').isNotEmpty ? ': ${v.rejectionReason}' : '.'}'
                    : 'Cancelled${(v.cancellationReason ?? '').isNotEmpty ? ': ${v.cancellationReason}' : '.'}',
                style: const TextStyle(color: AppColors.danger),
              )
            else
              Row(
                children: [
                  for (var i = 0; i < _steps.length; i++) ...[
                    Expanded(
                      child: Column(
                        children: [
                          Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: i <= idx
                                  ? AppColors.primary
                                  : AppColors.line,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _steps[i].$2,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 9,
                              color: i <= idx ? AppColors.ink : AppColors.muted,
                              fontWeight: i == idx
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (i < _steps.length - 1) const SizedBox(width: 3),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline(this.t);
  final OrderTracking t;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('History', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final e in t.timeline.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e.vendorName != null ? '${e.vendorName}: ' : ''}${humanize(e.toStatus)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          dateTime(e.at),
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                        if ((e.note ?? '').isNotEmpty)
                          Text(
                            e.note!,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
