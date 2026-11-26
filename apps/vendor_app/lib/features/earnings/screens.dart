import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards_export.dart';
import 'models.dart';

String settlementStatusLabel(String s) => switch (s) {
  'pending' => 'Awaiting payment',
  'ready' => 'Ready for payout',
  'paid' => 'Paid out',
  'cancelled' => 'Cancelled',
  _ => humanize(s),
};
String? _d(DateTimeRange? r, bool from) =>
    r == null ? null : isoDate(from ? r.start : r.end);

/// Money screen. Every figure is a backend record (orders / settlements). Nothing is calculated or assumed here.
class EarningsScreen extends ConsumerWidget {
  const EarningsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(dashboardProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Earnings')),
      body: AsyncBody<Dashboard>(
        value: dash,
        onRetry: () => ref.invalidate(dashboardProvider),
        builder: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(dashboardProvider),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SectionCard(
                title: 'Product sales',
                child: Column(
                  children: [
                    AmountRow(
                      'Sales from completed orders',
                      d.salesTotal,
                      bold: true,
                    ),
                    AmountRow(
                      'Platform commission',
                      d.commissionTotal,
                      negative: true,
                    ),
                    const Divider(height: 14),
                    AmountRow(
                      'Sales after commission',
                      d.salesTotal - d.commissionTotal,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${d.completedOrders} completed order${d.completedOrders == 1 ? '' : 's'}. Commission is the amount the platform recorded on each order when it was completed. Other deductions (e.g. processed refunds) appear in settlements below.',
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Service work',
                child: Column(
                  children: [
                    AmountRow(
                      'Value of completed services',
                      d.serviceValue,
                      bold: true,
                    ),
                    InfoRow('Completed jobs', '${d.completedServices}'),
                    Text(
                      'This is the recorded price of finished bookings (estimate + recorded extra charges). Customers pay you directly: no service payment, commission or payout is processed by the platform.',
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Settlements',
                trailing: TextButton(
                  onPressed: () => context.push('/settlements'),
                  child: const Text('See all'),
                ),
                child: Column(
                  children: [
                    for (final s in const ['pending', 'ready', 'paid'])
                      _SettleRow(
                        label: settlementStatusLabel(s),
                        t: d.settlement(s),
                        status: s,
                      ),
                    const Divider(height: 14),
                    Text(
                      '“Paid out” means the platform recorded a payout it made to you outside the app. Settlements awaiting payment or ready for payout have not been transferred yet. The app never initiates transfers.',
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/commissions'),
                      icon: const Icon(Icons.percent),
                      label: const Text('Commissions'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/transactions'),
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('Transactions'),
                    ),
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

class _SettleRow extends StatelessWidget {
  const _SettleRow({
    required this.label,
    required this.t,
    required this.status,
  });
  final String label, status;
  final SettlementTotals? t;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        StatusChip(status, label: label),
        const SizedBox(width: 8),
        Text(
          t == null ? 'none' : '${t!.count} order${t!.count == 1 ? '' : 's'}',
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        const Spacer(),
        Text(
          money(t?.net ?? 0),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

/// Settlement records, per delivered order. `commissionView` puts the gross → commission → net breakdown first.
class SettlementsScreen extends ConsumerStatefulWidget {
  const SettlementsScreen({super.key, this.commissionView = false});
  final bool commissionView;
  @override
  ConsumerState<SettlementsScreen> createState() => _SettlementsScreenState();
}

class _SettlementsScreenState extends ConsumerState<SettlementsScreen> {
  String? _status;
  DateTimeRange? _range;
  late PagedController<Settlement> _paged = _make();

  PagedController<Settlement> _make() => PagedController(
    (p) => ref
        .read(earningsRepositoryProvider)
        .settlements(
          p,
          status: _status,
          dateFrom: _d(_range, true),
          dateTo: _d(_range, false),
        ),
  );

  void _reset() {
    final old = _paged;
    setState(() => _paged = _make());
    old.dispose();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardProvider).asData?.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.commissionView ? 'Commission & deductions' : 'Settlements',
        ),
      ),
      body: Column(
        children: [
          if (widget.commissionView && dash != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                12,
                AppSpacing.lg,
                0,
              ),
              child: SectionCard(
                title: 'Total commission on completed orders',
                child: Column(
                  children: [
                    AmountRow(
                      'Commission recorded by the platform',
                      dash.commissionTotal,
                      bold: true,
                    ),
                    Text(
                      'Rates are set by the platform administrator and may differ per order. This app shows what was recorded; it never calculates or changes commission.',
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          DateRangeBar(
            range: _range,
            onChanged: (r) {
              _range = r;
              _reset();
            },
          ),
          FilterChips<String?>(
            options: const [
              (null, 'All'),
              ('pending', 'Awaiting payment'),
              ('ready', 'Ready'),
              ('paid', 'Paid out'),
              ('cancelled', 'Cancelled'),
            ],
            selected: _status,
            onSelected: (s) {
              _status = s;
              _reset();
            },
          ),
          Expanded(
            child: PagedListView<Settlement>(
              key: ValueKey(_paged),
              controller: _paged,
              empty: const EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'No settlements',
                message:
                    'A settlement record is created when one of your orders is completed.',
              ),
              itemBuilder: (context, s) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.orderNumber ?? 'Order',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          StatusChip(
                            s.status,
                            label: settlementStatusLabel(s.status),
                          ),
                        ],
                      ),
                      Text(
                        dateTime(s.createdAt),
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      AmountRow('Gross amount', s.gross),
                      AmountRow(
                        'Platform commission${s.gross > 0 ? ' (${(s.commission / s.gross * 100).toStringAsFixed(1)}% of gross)' : ''}',
                        s.commission,
                        negative: true,
                      ),
                      if (s.deductions > 0)
                        AmountRow(
                          'Other deductions',
                          s.deductions,
                          negative: true,
                        ),
                      const Divider(height: 14),
                      AmountRow('Net amount', s.net, bold: true),
                      if (s.isPaid)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Paid out ${dateShort(s.settledAt)}${(s.payoutReference ?? '').isNotEmpty ? ' · ref ${s.payoutReference}' : ''}',
                            style: const TextStyle(
                              color: AppColors.success,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
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
