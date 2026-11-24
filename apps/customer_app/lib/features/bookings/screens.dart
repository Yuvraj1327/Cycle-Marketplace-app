import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import 'booking_flow.dart';
import 'models.dart';
import 'providers.dart';

export 'booking_flow.dart';

String _when(Schedule s) => s.date == null
    ? ''
    : '${dateShort(DateTime.tryParse(s.date!))}, ${time12(s.slotStart)}';

class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key});
  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  String? _status;
  late PagedController<BookingSummary> _paged = _make();

  PagedController<BookingSummary> _make() => PagedController(
    (p) => ref.read(bookingRepositoryProvider).list(p, status: _status),
  );

  void _setStatus(String? s) {
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
    ref.listen(bookingsTickProvider, (_, _) => _paged.refresh());
    const filters = [
      (null, 'All'),
      ('pending', 'Pending'),
      ('accepted', 'Accepted'),
      ('in_service', 'In service'),
      ('completed', 'Completed'),
      ('cancelled', 'Cancelled'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('My service bookings')),
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
            child: PagedListView<BookingSummary>(
              key: ValueKey(_paged),
              controller: _paged,
              empty: EmptyState(
                icon: Icons.event_note_outlined,
                title: 'No bookings yet',
                message: 'Book a service and track your repair here.',
                actionLabel: 'Browse services',
                onAction: () => context.go('/services'),
              ),
              itemBuilder: (context, b) => Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/bookings/${b.id}'),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                b.serviceName,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            StatusChip(b.status),
                          ],
                        ),
                        Text(
                          '${b.vendorName ?? ''} · ${b.number}',
                          style: const TextStyle(color: AppColors.muted),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.event_outlined,
                              size: 16,
                              color: AppColors.muted,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                b.confirmed.isSet
                                    ? 'Confirmed: ${_when(b.confirmed)}'
                                    : 'Preferred: ${_when(b.preferred)}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            PriceText(b.currentPrice),
                          ],
                        ),
                        if (b.needsPickup)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.local_shipping_outlined,
                                  size: 16,
                                  color: AppColors.primary,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Doorstep pickup & drop-off',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
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
    );
  }
}

class BookingDetailScreen extends ConsumerStatefulWidget {
  const BookingDetailScreen({
    super.key,
    required this.id,
    this.justBooked = false,
  });
  final String id;
  final bool justBooked;
  @override
  ConsumerState<BookingDetailScreen> createState() =>
      _BookingDetailScreenState();
}

class _BookingDetailScreenState extends ConsumerState<BookingDetailScreen> {
  bool _busy = false;

  void _reload() {
    ref.invalidate(bookingDetailProvider(widget.id));
    ref.invalidate(bookingTrackingProvider(widget.id));
  }

  Future<void> _cancel(BookingDetail b) async {
    final reason = await askReason(
      context,
      title: 'Cancel this booking?',
      hint: 'Why are you cancelling?',
      action: 'Cancel booking',
    );
    if (reason == null || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(bookingRepositoryProvider).cancel(b.summary.id, reason);
      ref.read(bookingsTickProvider.notifier).bump();
      _reload();
      if (mounted) showSnack(context, 'Booking cancelled');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPhotos(BookingDetail b) async {
    final picked = await pickPhotos(max: 5 - b.images.length);
    if (picked.isEmpty || _busy) return;
    setState(() => _busy = true);
    final failed = await uploadBookingPhotos(ref, b.summary.id, picked);
    _reload();
    if (mounted) {
      setState(() => _busy = false);
      showSnack(
        context,
        failed == 0
            ? 'Photos added'
            : '$failed photo${failed == 1 ? '' : 's'} could not be uploaded',
        error: failed > 0,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(bookingDetailProvider(widget.id));
    final tracking = ref.watch(bookingTrackingProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Booking details')),
      body: AsyncBody<BookingDetail>(
        value: detail,
        onRetry: _reload,
        builder: (b) {
          final s = b.summary;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (widget.justBooked)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: AppColors.success,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Booking ${s.number} sent to ${s.vendorName ?? 'the provider'}. You will be notified when it is accepted.',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.serviceName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    StatusChip(s.status),
                  ],
                ),
                Text(
                  '${s.number}${b.categoryName != null ? ' · ${b.categoryName}' : ''}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                if (s.status == 'rejected')
                  _Banner(
                    'The provider could not take this booking${(b.rejectionReason ?? '').isNotEmpty ? ': ${b.rejectionReason}' : '.'}',
                    AppColors.danger,
                  ),
                if (s.status == 'cancelled')
                  _Banner(
                    'This booking was cancelled${(b.cancellationReason ?? '').isNotEmpty ? ': ${b.cancellationReason}' : '.'}',
                    AppColors.danger,
                  ),
                const SizedBox(height: 16),
                Text(
                  'Repair progress',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                _RepairProgress(status: s.status, needsPickup: s.needsPickup),
                if (b.pickup != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Pickup & drop-off',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _PickupCard(b.pickup!),
                ],
                const SizedBox(height: 16),
                Text(
                  'Appointment',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        InfoRow('Preferred', _when(s.preferred)),
                        InfoRow(
                          'Confirmed',
                          s.confirmed.isSet
                              ? _when(s.confirmed)
                              : s.status == 'pending'
                              ? 'Waiting for the provider'
                              : '—',
                          bold: s.confirmed.isSet,
                        ),
                        if (b.durationMinutes != null)
                          InfoRow(
                            'Estimated time',
                            'About ${b.durationMinutes! >= 60 ? '${b.durationMinutes! ~/ 60} hr${b.durationMinutes! % 60 == 0 ? '' : ' ${b.durationMinutes! % 60} min'}' : '${b.durationMinutes} min'}',
                          ),
                        if (b.vendor != null)
                          InfoRow(
                            'Provider',
                            '${b.vendor!['business_name'] ?? s.vendorName ?? ''}${b.vendor!['city'] != null ? ' · ${b.vendor!['city']}' : ''}',
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your cycle',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((b.cycle['brand'] ?? '').toString().isNotEmpty)
                          InfoRow('Brand', '${b.cycle['brand']}'),
                        if ((b.cycle['model'] ?? '').toString().isNotEmpty)
                          InfoRow('Model', '${b.cycle['model']}'),
                        if ((b.cycle['details'] ?? '').toString().isNotEmpty)
                          InfoRow('Details', '${b.cycle['details']}'),
                        const SizedBox(height: 4),
                        const Text(
                          'Problem described',
                          style: TextStyle(color: AppColors.muted),
                        ),
                        Text(b.issue),
                        if (b.images.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 84,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: b.images.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, i) => SizedBox(
                                width: 84,
                                child: AppNetworkImage(
                                  b.images[i].url,
                                  radius: 10,
                                  icon: Icons.image_outlined,
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (s.status == 'pending' && b.images.length < 5)
                          TextButton.icon(
                            onPressed: _busy ? null : () => _addPhotos(b),
                            icon: const Icon(Icons.add_a_photo_outlined),
                            label: const Text('Add photos'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Charges', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        AmountRow(
                          'Estimated service price',
                          b.pricing.estimated,
                        ),
                        for (final c in b.charges)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    '${c.amount >= 0 ? 'Additional' : 'Adjustment'}: ${c.reason}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  '${c.amount >= 0 ? '+ ' : '− '}${money(c.amount.abs())}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: c.amount >= 0
                                        ? AppColors.warning
                                        : AppColors.success,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (b.pickup != null)
                          AmountRow('Pickup charge', b.pricing.pickupCharge),
                        if (b.pickup != null)
                          AmountRow('Drop-off charge', b.pricing.dropoffCharge),
                        const Divider(height: 18),
                        AmountRow(
                          'Current total',
                          b.pricing.totalCurrent,
                          bold: true,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          b.pricing.logisticsConfigured == false
                              ? 'Pickup/drop-off charges are not configured yet (shown as ₹0). Nothing is charged in the app — the provider settles payment with you.'
                              : 'Nothing is charged in the app — the provider settles payment with you.',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (b.notes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Notes from the provider',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  for (final n in b.notes)
                    Card(
                      child: ListTile(
                        leading: const Icon(
                          Icons.sticky_note_2_outlined,
                          color: AppColors.primary,
                        ),
                        title: Text(n.note),
                        subtitle: Text(dateTime(n.at)),
                      ),
                    ),
                ],
                if ((b.completionNotes ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.verified_outlined,
                        color: AppColors.success,
                      ),
                      title: const Text('Completion notes'),
                      subtitle: Text(b.completionNotes!),
                    ),
                  ),
                ],
                tracking.maybeWhen(
                  data: (t) => _History(t),
                  orElse: () => const SizedBox.shrink(),
                ),
                const SizedBox(height: 20),
                if (b.canCancel)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                    ),
                    onPressed: _busy ? null : () => _cancel(b),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel booking'),
                  ),
                if (!b.canCancel &&
                    !const {
                      'cancelled',
                      'rejected',
                      'completed',
                    }.contains(s.status))
                  const Center(
                    child: Text(
                      'The cycle is already with the provider, so this booking can no longer be cancelled here. Contact support if you need help.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                TextButton.icon(
                  onPressed: () =>
                      context.push('/support/new?bookingId=${s.id}'),
                  icon: const Icon(Icons.support_agent),
                  label: const Text('Report a problem with this booking'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.all(12),
    width: double.infinity,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .3)),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w700),
    ),
  );
}

/// Repair status progression. Adapts to bookings WITHOUT doorstep pickup (no "Picked up" step).
class _RepairProgress extends StatelessWidget {
  const _RepairProgress({required this.status, required this.needsPickup});
  final String status;
  final bool needsPickup;
  @override
  Widget build(BuildContext context) {
    final steps = [
      ('pending', 'Pending'),
      ('accepted', 'Accepted'),
      if (needsPickup) ('picked_up', 'Picked up'),
      ('in_service', 'In service'),
      (
        'ready_for_delivery',
        needsPickup ? 'Ready for delivery' : 'Ready to collect',
      ),
      ('completed', 'Completed'),
    ];
    final ended = status == 'cancelled' || status == 'rejected';
    final idx = steps.indexWhere((s) => s.$1 == status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (var i = 0; i < steps.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      Icon(
                        ended
                            ? Icons.radio_button_unchecked
                            : (i <= idx
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked),
                        size: 22,
                        color: ended
                            ? AppColors.line
                            : (i <= idx ? AppColors.primary : AppColors.line),
                      ),
                      if (i < steps.length - 1)
                        Container(
                          width: 2,
                          height: 24,
                          color: !ended && i < idx
                              ? AppColors.primary
                              : AppColors.line,
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      steps[i].$2,
                      style: TextStyle(
                        fontWeight: !ended && i == idx
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: !ended && i <= idx
                            ? AppColors.ink
                            : AppColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Pickup and return-delivery progress, shown separately from the repair status.
class _PickupCard extends StatelessWidget {
  const _PickupCard(this.p);
  final Pickup p;
  static const _pick = ['requested', 'scheduled', 'picked_up'];
  static const _drop = ['requested', 'scheduled', 'delivered'];

  Widget _row(
    BuildContext context,
    String title,
    String stage,
    List<String> flow,
    DateTime? at,
    DateTime? done,
    String address,
  ) {
    final idx = flow.indexOf(stage);
    final problem = stage == 'failed' || stage == 'cancelled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const Spacer(),
            StatusChip(stage, label: humanize(stage)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < flow.length; i++) ...[
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: !problem && i <= idx
                            ? AppColors.primary
                            : AppColors.line,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      humanize(flow[i]),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: i == idx
                            ? FontWeight.w800
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (i < flow.length - 1) const SizedBox(width: 4),
            ],
          ],
        ),
        const SizedBox(height: 6),
        if (at != null)
          Text(
            'Scheduled: ${dateTime(at)}',
            style: const TextStyle(fontSize: 13),
          ),
        if (done != null)
          Text(
            'Completed: ${dateTime(done)}',
            style: const TextStyle(fontSize: 13, color: AppColors.success),
          ),
        Text(
          address,
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            context,
            'Pickup',
            p.pickupStage,
            _pick,
            p.scheduledPickupAt,
            p.pickedUpAt,
            Pickup.addressText(p.pickupAddress),
          ),
          const Divider(height: 24),
          _row(
            context,
            'Return delivery',
            p.deliveryStage,
            _drop,
            p.scheduledDeliveryAt,
            p.deliveredAt,
            Pickup.addressText(p.dropoffAddress),
          ),
          if ((p.instructions ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Your instructions: ${p.instructions}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if ((p.notes ?? '').isNotEmpty)
            Text(
              'Provider note: ${p.notes}',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
    ),
  );
}

class _History extends StatelessWidget {
  const _History(this.t);
  final BookingTracking t;
  @override
  Widget build(BuildContext context) => t.timeline.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'History',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
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
                                  humanize(e.toStatus),
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
          ),
        );
}
