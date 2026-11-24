import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/vendor_widgets.dart';
import 'models.dart';
import 'providers.dart';

String orderStatusLabel(String s) => vendorOrderStatusLabels[s] ?? humanize(s);

class OrderCard extends StatelessWidget {
  const OrderCard(this.o, {super.key});
  final VendorOrder o;
  @override
  Widget build(BuildContext context) => Card(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: o.isNew ? AppColors.warning : AppColors.line,
        width: o.isNew ? 1.5 : 1,
      ),
    ),
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
                StatusChip(o.status, label: orderStatusLabel(o.status)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Order ${o.orderNumber} · ${dateTime(o.placedAt)}',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.shopping_bag_outlined,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 4),
                Text('${o.itemCount} item${o.itemCount == 1 ? '' : 's'}'),
                const SizedBox(width: 12),
                const Icon(
                  Icons.payments_outlined,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 4),
                Text(
                  '${o.paymentMethod == 'cod' ? 'COD' : 'Online'} · ${humanize(o.paymentStatus)}',
                  style: const TextStyle(fontSize: 13),
                ),
                const Spacer(),
                Text(
                  money(o.total),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            if (o.isNew)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Waiting for your response',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key, this.initialStatus});
  final String? initialStatus;
  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  late String? _status = widget.initialStatus;
  late PagedController<VendorOrder> _paged = _make();

  PagedController<VendorOrder> _make() => PagedController(
    (p) => ref.read(orderRepositoryProvider).list(p, status: _status),
  );

  void _set(String? s) {
    final old = _paged;
    setState(() {
      _status = s;
      _paged = _make();
    });
    old.dispose();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ordersTickProvider, (_, _) => _paged.refresh());
    const filters = <(String?, String)>[
      (null, 'All'),
      ('pending', 'New'),
      ('accepted', 'Accepted'),
      ('preparing', 'Processing'),
      ('ready_for_dispatch', 'Ready to dispatch'),
      ('out_for_delivery', 'Shipped'),
      ('delivered', 'Completed'),
      ('rejected', 'Rejected'),
      ('cancelled', 'Cancelled'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none),
            onPressed: () => context.push('/notifications'),
          ),
        ],
      ),
      body: Column(
        children: [
          FilterChips<String?>(
            options: filters,
            selected: _status,
            onSelected: _set,
          ),
          Expanded(
            child: PagedListView<VendorOrder>(
              key: ValueKey(_paged),
              controller: _paged,
              empty: EmptyState(
                icon: Icons.inbox_outlined,
                title: _status == null
                    ? 'No orders yet'
                    : 'No ${orderStatusLabel(_status!).toLowerCase()} orders',
                message: 'Customer orders for your products appear here.',
              ),
              itemBuilder: (context, o) => OrderCard(o),
            ),
          ),
        ],
      ),
    );
  }
}

class OrderDetailScreen extends ConsumerStatefulWidget {
  const OrderDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  bool _busy = false;

  void _reload() {
    ref.invalidate(orderDetailProvider(widget.id));
    ref.invalidate(orderTimelineProvider(widget.id));
    ref.read(ordersTickProvider.notifier).bump();
  }

  /// Runs a backend action. The success message is shown only AFTER the backend accepted the change; errors show the backend's reason.
  Future<void> _run(
    Future<VendorOrder> Function() action,
    String success,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _reload();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(VendorOrder o) async {
    if (!await confirmDialog(
      context,
      title: 'Accept this order?',
      message: 'You commit to fulfil ${o.number}. The customer is notified.',
      confirmLabel: 'Accept',
    )) {
      return;
    }
    await _run(
      () => ref.read(orderRepositoryProvider).accept(o.id),
      'Order accepted',
    );
  }

  Future<void> _reject(VendorOrder o) async {
    final reason = await askReason(
      context,
      title: 'Reject this order?',
      hint: 'Reason shown to the customer',
      action: 'Reject order',
    );
    if (reason == null) return;
    await _run(
      () => ref.read(orderRepositoryProvider).reject(o.id, reason),
      'Order rejected. Reserved stock is returned by the system; a refund is requested if the customer had paid.',
    );
  }

  Future<void> _advance(VendorOrder o, String status) async {
    if (!await confirmDialog(
      context,
      title: 'Mark as ${orderStatusLabel(status)}?',
      message: 'The customer is notified of this status.',
      confirmLabel: 'Update',
    )) {
      return;
    }
    await _run(
      () => ref.read(orderRepositoryProvider).updateStatus(o.id, status),
      'Order marked ${orderStatusLabel(status).toLowerCase()}',
    );
  }

  Future<void> _cancel(VendorOrder o) async {
    final reason = await askReason(
      context,
      title: 'Cancel this order?',
      hint: 'Why can you not fulfil it?',
      action: 'Cancel order',
    );
    if (reason == null) return;
    await _run(
      () => ref
          .read(orderRepositoryProvider)
          .updateStatus(o.id, 'cancelled', note: reason),
      'Order cancelled',
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(orderDetailProvider(widget.id));
    final timeline = ref.watch(orderTimelineProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Order details')),
      body: AsyncBody<VendorOrder>(
        value: async,
        onRetry: _reload,
        builder: (o) {
          final d = o.detail!;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        o.number,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    StatusChip(o.status, label: orderStatusLabel(o.status)),
                  ],
                ),
                Text(
                  'Parent order ${o.orderNumber} · placed ${dateTime(o.placedAt)}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                if (o.status == 'rejected')
                  StatusBanner(
                    'Rejected${(d.rejectionReason ?? '').isNotEmpty ? ': ${d.rejectionReason}' : ''}',
                    color: AppColors.danger,
                  ),
                if (o.status == 'cancelled')
                  StatusBanner(
                    'Cancelled${(d.cancellationReason ?? '').isNotEmpty ? ': ${d.cancellationReason}' : ''}',
                    color: AppColors.danger,
                  ),
                const SizedBox(height: 14),
                SectionCard(
                  title: 'Items',
                  child: Column(
                    children: [
                      for (final i in d.items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 56,
                                height: 56,
                                child: AppNetworkImage(i.imageUrl, radius: 8),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      i.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      [i.brand, i.model, i.condition]
                                          .where((e) => (e ?? '').isNotEmpty)
                                          .join(' · '),
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      '${money(i.unitPrice)} × ${i.quantity}',
                                      style: const TextStyle(fontSize: 12),
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
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Deliver to',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.recipient,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(d.addressText),
                      if (d.phone.isNotEmpty)
                        TextButton.icon(
                          onPressed: () =>
                              launchUrl(Uri(scheme: 'tel', path: d.phone)),
                          icon: const Icon(Icons.call_outlined, size: 18),
                          label: Text(d.phone),
                        ),
                      if ((d.customerNote ?? '').isNotEmpty)
                        Text(
                          'Customer note: ${d.customerNote}',
                          style: const TextStyle(fontStyle: FontStyle.italic),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Payment',
                  child: Column(
                    children: [
                      InfoRow(
                        'Method',
                        o.paymentMethod == 'cod'
                            ? 'Cash on delivery'
                            : 'Online',
                      ),
                      InfoRow('Status', humanize(o.paymentStatus), bold: true),
                      const Text(
                        'Payment status is set by the platform from verified payment records. You cannot change it.',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Your amount',
                  child: Column(
                    children: [
                      AmountRow('Items subtotal', o.subtotal),
                      AmountRow(
                        'Platform commission',
                        o.commission ?? 0,
                        negative: true,
                      ),
                      const Divider(height: 16),
                      AmountRow('Net payable to you', d.netPayable, bold: true),
                      if (o.commission == null)
                        const Text(
                          'Commission is calculated by the platform when the order is completed.',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'Order total charged to customer ${money(o.total)} (includes delivery ${money(d.deliveryCharge)}, discount ${money(d.discount)}); these are settled by the platform.',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                timeline.maybeWhen(
                  data: (events) => events.isEmpty
                      ? const SizedBox.shrink()
                      : SectionCard(
                          title: 'Timeline',
                          child: Column(
                            children: [
                              for (final e in events.reversed)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              orderStatusLabel(e.toStatus),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
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
                  orElse: () => const SizedBox.shrink(),
                ),
                const SizedBox(height: 20),
                if (o.isNew)
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: 'Reject',
                          outlined: true,
                          danger: true,
                          onPressed: _busy ? null : () => _reject(o),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppButton(
                          label: 'Accept order',
                          busy: _busy,
                          onPressed: () => _accept(o),
                        ),
                      ),
                    ],
                  ),
                for (final s in o.nextSteps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppButton(
                      label: 'Mark as ${orderStatusLabel(s)}',
                      busy: _busy,
                      onPressed: () => _advance(o, s),
                    ),
                  ),
                if (o.canCancel)
                  AppButton(
                    label: 'Cancel order',
                    outlined: true,
                    danger: true,
                    onPressed: _busy ? null : () => _cancel(o),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}
