import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards_export.dart';
import '../orders/models.dart';
import '../orders/screens.dart' show orderStatusLabel;
import '../service_bookings/models.dart';

String? _d(DateTimeRange? r, bool from) =>
    r == null ? null : isoDate(from ? r.start : r.end);

/// Transactions = the money-bearing records the platform actually holds: product orders (payment method/status, commission) and completed service jobs.
/// Payment gateway references are not exposed to vendors by the backend.
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});
  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  DateTimeRange? _range;
  String? _orderStatus = 'delivered';
  late PagedController<VendorOrder> _orders = _mkOrders();
  late PagedController<VendorBooking> _jobs = _mkJobs();

  PagedController<VendorOrder> _mkOrders() => PagedController(
    (p) => ref
        .read(orderRepositoryProvider)
        .list(
          p,
          status: _orderStatus,
          dateFrom: _d(_range, true),
          dateTo: _d(_range, false),
        ),
  );
  PagedController<VendorBooking> _mkJobs() => PagedController(
    (p) => ref
        .read(serviceBookingRepositoryProvider)
        .list(
          p,
          status: 'completed',
          dateFrom: _d(_range, true),
          dateTo: _d(_range, false),
        ),
  );

  void _reset() {
    final o = _orders, j = _jobs;
    setState(() {
      _orders = _mkOrders();
      _jobs = _mkJobs();
    });
    o.dispose();
    j.dispose();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _orders.dispose();
    _jobs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Transactions'),
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'Product sales'),
          Tab(text: 'Services'),
        ],
      ),
    ),
    body: Column(
      children: [
        DateRangeBar(
          range: _range,
          onChanged: (r) {
            _range = r;
            _reset();
          },
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              Column(
                children: [
                  FilterChips<String?>(
                    options: const [
                      ('delivered', 'Completed'),
                      (null, 'All orders'),
                      ('cancelled', 'Cancelled'),
                      ('rejected', 'Rejected'),
                    ],
                    selected: _orderStatus,
                    onSelected: (s) {
                      _orderStatus = s;
                      _reset();
                    },
                  ),
                  Expanded(
                    child: PagedListView<VendorOrder>(
                      key: ValueKey(_orders),
                      controller: _orders,
                      empty: const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No transactions',
                        message: 'Completed sales appear here.',
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
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                    ),
                                    StatusChip(
                                      o.status,
                                      label: orderStatusLabel(o.status),
                                    ),
                                  ],
                                ),
                                Text(
                                  dateTime(o.placedAt),
                                  style: TextStyle(
                                    color: context.palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                InfoRow(
                                  'Payment',
                                  '${o.paymentMethod == 'cod' ? 'Cash on delivery' : 'Online'} · ${humanize(o.paymentStatus)}',
                                ),
                                AmountRow('Order amount (yours)', o.subtotal),
                                AmountRow(
                                  'Commission',
                                  o.commission ?? 0,
                                  negative: true,
                                ),
                                AmountRow(
                                  'Net',
                                  o.subtotal - (o.commission ?? 0),
                                  bold: true,
                                ),
                                if (o.commission == null)
                                  Text(
                                    'Commission not recorded yet (set on completion).',
                                    style: TextStyle(
                                      color: context.palette.muted,
                                      fontSize: 12,
                                    ),
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
              PagedListView<VendorBooking>(
                key: ValueKey(_jobs),
                controller: _jobs,
                empty: const EmptyState(
                  icon: Icons.build_circle_outlined,
                  title: 'No completed services',
                  message:
                      'Finished service bookings appear here with their recorded price.',
                ),
                itemBuilder: (context, b) => Card(
                  child: ListTile(
                    onTap: () => context.push('/bookings/${b.id}'),
                    title: Text(b.serviceName),
                    subtitle: Text(
                      '${b.number} · ${b.customer?.name ?? ''}\nRecorded price; settled directly with the customer',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      money(b.currentPrice),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
