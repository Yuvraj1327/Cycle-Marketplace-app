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
import '../service_bookings/screens.dart' show stageLabel, whenText;
import 'models.dart';

final pickupDetailProvider = FutureProvider.family
    .autoDispose<PickupRequest, String>(
      (ref, id) => ref.read(pickupRepositoryProvider).get(id),
    );

/// Doorstep logistics list. Two tabs because pickup and return delivery are separate processes with separate statuses.
class PickupsScreen extends ConsumerStatefulWidget {
  const PickupsScreen({super.key});
  @override
  ConsumerState<PickupsScreen> createState() => _PickupsScreenState();
}

class _PickupsScreenState extends ConsumerState<PickupsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Pickup & drop-off'),
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'Pickups'),
          Tab(text: 'Drop-offs'),
        ],
      ),
    ),
    body: TabBarView(
      controller: _tabs,
      children: const [
        _LogisticsList(delivery: false),
        _LogisticsList(delivery: true),
      ],
    ),
  );
}

class _LogisticsList extends ConsumerStatefulWidget {
  const _LogisticsList({required this.delivery});
  final bool delivery;
  @override
  ConsumerState<_LogisticsList> createState() => _LogisticsListState();
}

class _LogisticsListState extends ConsumerState<_LogisticsList>
    with AutomaticKeepAliveClientMixin {
  String? _stage;
  late PagedController<PickupRequest> _paged = _make();

  @override
  bool get wantKeepAlive => true;

  // API filter values: requested|scheduled|completed|failed|cancelled map to the stage names the app shows
  PagedController<PickupRequest> _make() => PagedController(
    (p) => ref
        .read(pickupRepositoryProvider)
        .list(
          p,
          pickupStatus: widget.delivery ? null : _stage,
          deliveryStatus: widget.delivery ? _stage : null,
        ),
  );

  void _set(String? s) {
    final old = _paged;
    setState(() {
      _stage = s;
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
    super.build(context);
    ref.listen(pickupsTickProvider, (_, _) => _paged.refresh());
    return Column(
      children: [
        FilterChips<String?>(
          options: const [
            (null, 'All'),
            ('pending', 'Requested'),
            ('scheduled', 'Scheduled'),
            ('completed', 'Completed'),
            ('failed', 'Failed'),
            ('cancelled', 'Cancelled'),
          ],
          selected: _stage,
          onSelected: _set,
        ),
        Expanded(
          child: PagedListView<PickupRequest>(
            key: ValueKey(_paged),
            controller: _paged,
            empty: EmptyState(
              icon: Icons.local_shipping_outlined,
              title: widget.delivery ? 'No drop-offs' : 'No pickups',
              message:
                  'Doorstep requests from customers with accepted bookings appear here.',
            ),
            itemBuilder: (context, r) {
              final l = r.logistics;
              final stage = widget.delivery ? l.deliveryStage : l.pickupStage;
              final at = widget.delivery
                  ? l.scheduledDeliveryAt
                  : l.scheduledPickupAt;
              final addr = widget.delivery ? l.dropoffAddress : l.pickupAddress;
              return Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/pickups/${r.id}'),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${r.bookingNumber ?? ''} · ${r.serviceName ?? ''}',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            StatusChip(stage, label: stageLabel(stage)),
                          ],
                        ),
                        Text(
                          r.customer?.name ?? 'Customer',
                          style: const TextStyle(color: AppColors.muted),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          Logistics.addressText(addr),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.schedule,
                              size: 16,
                              color: AppColors.muted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              at != null ? dateTime(at) : 'Not scheduled yet',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const Spacer(),
                            if ((widget.delivery
                                    ? l.dropoffCharge
                                    : l.pickupCharge) >
                                0)
                              Text(
                                money(
                                  widget.delivery
                                      ? l.dropoffCharge
                                      : l.pickupCharge,
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class PickupDetailScreen extends ConsumerStatefulWidget {
  const PickupDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PickupDetailScreen> createState() => _PickupDetailScreenState();
}

class _PickupDetailScreenState extends ConsumerState<PickupDetailScreen> {
  bool _busy = false;

  void _reload() {
    ref.invalidate(pickupDetailProvider(widget.id));
    ref.read(pickupsTickProvider.notifier).bump();
  }

  Future<void> _run(Future<PickupRequest> Function() action, String ok) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _reload();
      if (mounted) showSnack(context, ok);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<DateTime?> _pickWhen(DateTime? initial) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: initial != null && initial.isAfter(now) ? initial : now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? now),
    );
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<void> _schedule(PickupRequest r, {required bool delivery}) async {
    final l = r.logistics;
    final when = await _pickWhen(
      delivery
          ? l.scheduledDeliveryAt?.toLocal()
          : l.scheduledPickupAt?.toLocal(),
    );
    if (when == null) return;
    final repo = ref.read(pickupRepositoryProvider);
    await _run(
      () => repo.coordinate(
        r.id,
        pickupAt: delivery ? null : when,
        deliveryAt: delivery ? when : null,
        // the backend only moves the stage to "scheduled" when told to, together with the time
        pickupStatus: delivery ? null : 'scheduled',
        deliveryStatus: delivery ? 'scheduled' : null,
      ),
      delivery ? 'Return delivery scheduled' : 'Pickup scheduled',
    );
  }

  Future<void> _mark(
    PickupRequest r, {
    required bool delivery,
    required String status,
    required String title,
  }) async {
    final reason = await askReason(
      context,
      title: title,
      hint: 'What happened? (shown in the booking record)',
      action: 'Confirm',
    );
    if (reason == null) return;
    final repo = ref.read(pickupRepositoryProvider);
    await _run(
      () => repo.coordinate(
        r.id,
        pickupStatus: delivery ? null : status,
        deliveryStatus: delivery ? status : null,
        notes: reason,
      ),
      'Updated',
    );
  }

  Widget _block(PickupRequest r, {required bool delivery}) {
    final l = r.logistics;
    final stage = delivery ? l.deliveryStage : l.pickupStage;
    final addr = delivery ? l.dropoffAddress : l.pickupAddress;
    final at = delivery ? l.scheduledDeliveryAt : l.scheduledPickupAt;
    final done = delivery ? l.deliveredAt : l.pickedUpAt;
    final charge = delivery ? l.dropoffCharge : l.pickupCharge;
    final closed =
        stage == 'picked_up' || stage == 'delivered' || stage == 'cancelled';
    // delivery can only be coordinated after the cycle was picked up (or no pickup is needed); the backend enforces order and booking state.
    final bookingOpen = const {
      'accepted',
      'picked_up',
      'in_service',
      'ready_for_delivery',
    }.contains(r.bookingStatus);
    return SectionCard(
      title: delivery ? 'Return delivery' : 'Pickup',
      trailing: StatusChip(stage, label: stageLabel(stage)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Logistics.addressText(addr)),
          const SizedBox(height: 6),
          InfoRow('Scheduled', at != null ? dateTime(at) : 'Not scheduled'),
          if (done != null)
            InfoRow(
              delivery ? 'Delivered' : 'Picked up',
              dateTime(done),
              color: AppColors.success,
            ),
          if (charge > 0) InfoRow('Charge', money(charge)),
          if (!closed && bookingOpen)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _schedule(r, delivery: delivery),
                    icon: const Icon(Icons.event_available_outlined, size: 18),
                    label: Text(at == null ? 'Schedule' : 'Reschedule'),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _mark(
                            r,
                            delivery: delivery,
                            status: 'failed',
                            title: delivery
                                ? 'Delivery attempt failed'
                                : 'Pickup attempt failed',
                          ),
                    child: const Text('Attempt failed'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                    ),
                    onPressed: _busy
                        ? null
                        : () => _mark(
                            r,
                            delivery: delivery,
                            status: 'cancelled',
                            title: delivery
                                ? 'Cancel return delivery'
                                : 'Cancel pickup',
                          ),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          if (!closed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                delivery
                    ? 'Delivery is recorded as done when you mark the booking “Completed”.'
                    : 'Pickup is recorded as done when you mark the booking “Picked up”.',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          if (!closed && !bookingOpen)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Accept the booking before coordinating logistics.',
                style: TextStyle(color: AppColors.warning, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pickup & drop-off')),
    body: AsyncBody<PickupRequest>(
      value: ref.watch(pickupDetailProvider(widget.id)),
      onRetry: _reload,
      builder: (r) => RefreshIndicator(
        onRefresh: () async => _reload(),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${r.bookingNumber ?? ''} · ${r.serviceName ?? ''}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (r.bookingStatus != null) StatusChip(r.bookingStatus!),
              ],
            ),
            const Text(
              'Repair status is shown by the badge above. Pickup and return delivery have their own statuses below.',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Customer',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.customer?.name ?? 'Customer',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if ((r.customer?.phone ?? '').isNotEmpty)
                    TextButton.icon(
                      onPressed: () => launchUrl(
                        Uri(scheme: 'tel', path: r.customer!.phone),
                      ),
                      icon: const Icon(Icons.call_outlined, size: 18),
                      label: Text(r.customer!.phone!),
                    ),
                  InfoRow('Preferred slot', whenText(r.preferred)),
                  if ((r.logistics.instructions ?? '').isNotEmpty)
                    InfoRow('Instructions', r.logistics.instructions!),
                  if ((r.logistics.notes ?? '').isNotEmpty)
                    InfoRow('Your notes', r.logistics.notes!),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _block(r, delivery: false),
            const SizedBox(height: 12),
            _block(r, delivery: true),
            TextButton.icon(
              onPressed: () => context.push('/bookings/${r.bookingId}'),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open booking'),
            ),
          ],
        ),
      ),
    ),
  );
}
