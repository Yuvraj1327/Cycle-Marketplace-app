import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/providers.dart';
import '../../core/widgets/cards_export.dart';
import '../earnings/models.dart';
import '../notifications/screens.dart';
import '../orders/models.dart';
import '../orders/providers.dart';
import '../orders/screens.dart';
import '../service_bookings/models.dart';
import '../service_bookings/providers.dart';
import '../service_bookings/screens.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final dash = ref.watch(dashboardProvider);
    void refresh() {
      ref.invalidate(dashboardProvider);
      ref.invalidate(recentOrdersProvider);
      ref.invalidate(recentBookingsProvider);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          auth.vendor?.businessName ?? 'Dashboard',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: const [NotificationsButton()],
      ),
      body: AsyncBody<Dashboard>(
        value: dash,
        onRetry: refresh,
        builder: (d) => RefreshIndicator(
          onRefresh: () async => refresh(),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (d.pendingOrders + d.pendingBookings > 0)
                StatusBanner(
                  '${d.pendingOrders} new order${d.pendingOrders == 1 ? '' : 's'} and ${d.pendingBookings} new booking${d.pendingBookings == 1 ? '' : 's'} waiting for your response.',
                  icon: Icons.notifications_active_outlined,
                ),
              Text('Overview', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.2,
                children: [
                  MetricCard(
                    label: 'Total orders',
                    value: '${d.orderTotal}',
                    icon: Icons.receipt_long_outlined,
                    onTap: () => context.go('/orders'),
                  ),
                  MetricCard(
                    label: 'Pending orders',
                    value: '${d.pendingOrders}',
                    icon: Icons.hourglass_top,
                    color: AppColors.warning,
                    onTap: () => context.go('/orders?status=pending'),
                  ),
                  MetricCard(
                    label: 'Completed orders',
                    value: '${d.completedOrders}',
                    icon: Icons.check_circle_outline,
                    color: AppColors.success,
                  ),
                  MetricCard(
                    label: 'Products',
                    value: '${d.productTotal}',
                    icon: Icons.pedal_bike,
                    caption: '${d.productsActive} active',
                    onTap: () => context.go('/products'),
                  ),
                  MetricCard(
                    label: 'Pending bookings',
                    value: '${d.pendingBookings}',
                    icon: Icons.event_note_outlined,
                    color: AppColors.warning,
                    onTap: () => context.go('/services'),
                  ),
                  MetricCard(
                    label: 'Completed services',
                    value: '${d.completedServices}',
                    icon: Icons.build_circle_outlined,
                    color: AppColors.success,
                  ),
                ],
              ),
              if (d.productsPending +
                      d.productsRejected +
                      d.productsOutOfStock >
                  0) ...[
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Needs attention',
                  child: Column(
                    children: [
                      if (d.productsPending > 0)
                        _Attention(
                          Icons.hourglass_top,
                          '${d.productsPending} product${d.productsPending == 1 ? '' : 's'} waiting for approval',
                          () => context.go('/products'),
                        ),
                      if (d.productsRejected > 0)
                        _Attention(
                          Icons.cancel_outlined,
                          '${d.productsRejected} product${d.productsRejected == 1 ? '' : 's'} rejected',
                          () => context.go('/products'),
                        ),
                      if (d.productsOutOfStock > 0)
                        _Attention(
                          Icons.remove_shopping_cart_outlined,
                          '${d.productsOutOfStock} product${d.productsOutOfStock == 1 ? '' : 's'} out of stock',
                          () => context.push('/inventory'),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Revenue summary',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SectionCard(
                title: 'From records held by the platform',
                trailing: TextButton(
                  onPressed: () => context.push('/earnings'),
                  child: const Text('Details'),
                ),
                child: Column(
                  children: [
                    AmountRow('Product sales (completed orders)', d.salesTotal),
                    AmountRow(
                      'Platform commission',
                      d.commissionTotal,
                      negative: true,
                    ),
                    AmountRow(
                      'Service work completed (recorded)',
                      d.serviceValue,
                    ),
                    const Divider(height: 14),
                    AmountRow(
                      'Settlements awaiting payout',
                      d.netPending,
                      bold: true,
                    ),
                    AmountRow(
                      'Paid out (recorded by platform)',
                      d.netPaid,
                      bold: true,
                      color: AppColors.success,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('Activity', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SectionCard(
                title: 'Orders by status',
                child: CountBars(
                  rows: [
                    for (final s in [
                      'pending',
                      'accepted',
                      'preparing',
                      'ready_for_dispatch',
                      'out_for_delivery',
                      'delivered',
                      'rejected',
                      'cancelled',
                    ])
                      (
                        label: vendorOrderStatusLabels[s]!,
                        value: d.orders(s),
                        color: StatusChip.colorFor(s),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SectionCard(
                title: 'Bookings by status',
                child: CountBars(
                  rows: [
                    for (final s in [
                      'pending',
                      'accepted',
                      'picked_up',
                      'in_service',
                      'ready_for_delivery',
                      'completed',
                      'rejected',
                      'cancelled',
                    ])
                      (
                        label: bookingStatusLabels[s]!,
                        value: d.bookings(s),
                        color: StatusChip.colorFor(s),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Quick actions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Add product'),
                    onPressed: () => context.push('/products/new'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: const Text('Manage products'),
                    onPressed: () => context.go('/products'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('View orders'),
                    onPressed: () => context.go('/orders'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.build_circle_outlined, size: 18),
                    label: const Text('Manage services'),
                    onPressed: () => context.go('/services'),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.local_shipping_outlined, size: 18),
                    label: const Text('Pickups'),
                    onPressed: () => context.push('/pickups'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _RecentOrders(),
              const SizedBox(height: 12),
              const _RecentBookings(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _Attention extends StatelessWidget {
  const _Attention(this.icon, this.text, this.onTap);
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: AppColors.warning),
    title: Text(text),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _RecentOrders extends ConsumerWidget {
  const _RecentOrders();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentOrdersProvider);
    return recent.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SizedBox.shrink(),
      data: (orders) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recent orders',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => context.go('/orders'),
                child: const Text('See all'),
              ),
            ],
          ),
          if (orders.isEmpty)
            const Text(
              'No orders yet.',
              style: TextStyle(color: AppColors.muted),
            )
          else
            for (final o in orders)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OrderCard(o),
              ),
        ],
      ),
    );
  }
}

class _RecentBookings extends ConsumerWidget {
  const _RecentBookings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentBookingsProvider);
    return recent.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SizedBox.shrink(),
      data: (items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recent bookings',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => context.go('/services'),
                child: const Text('See all'),
              ),
            ],
          ),
          if (items.isEmpty)
            const Text(
              'No service bookings yet.',
              style: TextStyle(color: AppColors.muted),
            )
          else
            for (final b in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: BookingCard(b),
              ),
        ],
      ),
    );
  }
}
