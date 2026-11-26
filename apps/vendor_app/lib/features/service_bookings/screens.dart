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
import '../pickup_dropoff/models.dart';
import 'models.dart';
import 'providers.dart';

String bookingStatusLabel(String s) => bookingStatusLabels[s] ?? humanize(s);
String whenText(Schedule s) => s.date == null
    ? '—'
    : '${dateShort(DateTime.tryParse(s.date!))}, ${time12(s.slotStart)}';
String stageLabel(String s) => switch (s) {
  'requested' => 'Requested',
  'scheduled' => 'Scheduled',
  'picked_up' => 'Picked up',
  'delivered' => 'Delivered',
  'failed' => 'Attempt failed',
  'cancelled' => 'Cancelled',
  _ => humanize(s),
};

class BookingCard extends StatelessWidget {
  const BookingCard(this.b, {super.key});
  final VendorBooking b;
  @override
  Widget build(BuildContext context) => Card(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: b.isNew ? AppColors.warning : context.palette.line,
        width: b.isNew ? 1.5 : 1,
      ),
    ),
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
                StatusChip(b.status, label: bookingStatusLabel(b.status)),
              ],
            ),
            Text(
              '${b.number} · ${b.customer?.name ?? 'Customer'}',
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(b.issue, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.event_outlined,
                  size: 16,
                  color: context.palette.muted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    b.confirmed.isSet
                        ? 'Confirmed ${whenText(b.confirmed)}'
                        : 'Preferred ${whenText(b.preferred)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Text(
                  money(b.currentPrice),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            if (b.needsPickup)
              Padding(
                padding: EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.local_shipping_outlined,
                      size: 16,
                      color: context.palette.primary,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Doorstep pickup & drop-off',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.primary,
                      ),
                    ),
                  ],
                ),
              ),
            if (b.isNew)
              const Padding(
                padding: EdgeInsets.only(top: 6),
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

class BookingsListScreen extends ConsumerStatefulWidget {
  const BookingsListScreen({super.key});
  @override
  ConsumerState<BookingsListScreen> createState() => _BookingsListScreenState();
}

class _BookingsListScreenState extends ConsumerState<BookingsListScreen> {
  String? _status;
  String _q = '';
  late PagedController<VendorBooking> _paged = _make();

  PagedController<VendorBooking> _make() => PagedController(
    (p) => ref
        .read(serviceBookingRepositoryProvider)
        .list(p, status: _status, q: _q),
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
    ref.listen(bookingsTickProvider, (_, _) => _paged.refresh());
    final filters = <(String?, String)>[
      (null, 'All'),
      for (final s in [
        'pending',
        'accepted',
        'rejected',
        'picked_up',
        'in_service',
        'ready_for_delivery',
        'completed',
        'cancelled',
      ])
        (s, bookingStatusLabel(s)),
    ];
    return Column(
      children: [
        SearchField(
          hint: 'Search by booking number',
          onChanged: (v) {
            _q = v.trim();
            _reset();
          },
        ),
        FilterChips<String?>(
          options: filters,
          selected: _status,
          onSelected: (s) {
            _status = s;
            _reset();
          },
        ),
        Expanded(
          child: PagedListView<VendorBooking>(
            key: ValueKey(_paged),
            controller: _paged,
            empty: const EmptyState(
              icon: Icons.event_note_outlined,
              title: 'No bookings',
              message: 'Service requests from customers appear here.',
            ),
            itemBuilder: (context, b) => BookingCard(b),
          ),
        ),
      ],
    );
  }
}

class BookingDetailScreen extends ConsumerStatefulWidget {
  const BookingDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<BookingDetailScreen> createState() =>
      _BookingDetailScreenState();
}

class _BookingDetailScreenState extends ConsumerState<BookingDetailScreen> {
  bool _busy = false;

  void _reload() {
    ref.invalidate(bookingDetailProvider(widget.id));
    ref.invalidate(bookingTimelineProvider(widget.id));
    ref.read(bookingsTickProvider.notifier).bump();
    ref.read(pickupsTickProvider.notifier).bump();
  }

  /// Backend first, message second: success is only announced after the backend accepted the change.
  Future<void> _run(
    Future<VendorBooking> Function() action,
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
      _reload(); // e.g. slot_full / invalid_transition: show what the backend now says
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(VendorBooking b) async {
    if (!await confirmDialog(
      context,
      title: 'Accept this booking?',
      message:
          'The preferred slot ${whenText(b.preferred)} will be confirmed if capacity allows. The customer is notified.',
      confirmLabel: 'Accept',
    )) {
      return;
    }
    await _run(
      () => ref.read(serviceBookingRepositoryProvider).accept(b.id),
      'Booking accepted',
    );
  }

  Future<void> _reject(VendorBooking b) async {
    final reason = await askReason(
      context,
      title: 'Reject this booking?',
      hint: 'Reason shown to the customer',
      action: 'Reject booking',
    );
    if (reason == null) return;
    await _run(
      () => ref.read(serviceBookingRepositoryProvider).reject(b.id, reason),
      'Booking rejected',
    );
  }

  Future<void> _advance(VendorBooking b, String status) async {
    final note = await _askNote(
      context,
      title: 'Mark as ${bookingStatusLabel(status)}',
      hint: status == 'completed'
          ? 'Completion notes (what was done)'
          : 'Note for the customer (optional)',
      required: false,
    );
    if (note == null) return;
    await _run(
      () => ref
          .read(serviceBookingRepositoryProvider)
          .updateStatus(b.id, status, note: note),
      'Booking marked ${bookingStatusLabel(status).toLowerCase()}',
    );
  }

  Future<void> _cancel(VendorBooking b) async {
    final reason = await askReason(
      context,
      title: 'Cancel this accepted booking?',
      hint: 'Why can you not do it?',
      action: 'Cancel booking',
    );
    if (reason == null) return;
    await _run(
      () => ref
          .read(serviceBookingRepositoryProvider)
          .updateStatus(b.id, 'cancelled', note: reason),
      'Booking cancelled',
    );
  }

  Future<void> _addNote(VendorBooking b) async {
    final note = await _askNote(
      context,
      title: 'Add a service note',
      hint: 'Visible to the customer',
      required: true,
    );
    if (note == null || note.isEmpty) return;
    await _run(
      () => ref.read(serviceBookingRepositoryProvider).addNote(b.id, note),
      'Note added',
    );
  }

  Future<void> _addCharge(VendorBooking b) async {
    final res = await showModalBottomSheet<(double, String)>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _ChargeSheet(
        estimated: b.detail!.pricing.estimated,
        current: b.detail!.pricing.current,
      ),
    );
    if (res == null) return;
    await _run(
      () => ref
          .read(serviceBookingRepositoryProvider)
          .addCharge(b.id, res.$1, res.$2),
      'Charge recorded',
    );
  }

  Future<void> _reschedule(VendorBooking b) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate:
          DateTime.tryParse(b.confirmed.date ?? b.preferred.date ?? '') ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour:
            int.tryParse(
              (b.confirmed.slotStart ?? b.preferred.slotStart ?? '10:00').split(
                ':',
              )[0],
            ) ??
            10,
        minute: 0,
      ),
    );
    if (t == null) return;
    await _run(
      () => ref
          .read(serviceBookingRepositoryProvider)
          .reschedule(
            b.id,
            isoDate(d),
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
          ),
      'Appointment updated',
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(bookingDetailProvider(widget.id));
    final timeline = ref.watch(bookingTimelineProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Booking')),
      body: AsyncBody<VendorBooking>(
        value: async,
        onRetry: _reload,
        builder: (b) {
          final d = b.detail!;
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
                        b.serviceName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    StatusChip(b.status, label: bookingStatusLabel(b.status)),
                  ],
                ),
                Text(b.number, style: TextStyle(color: context.palette.muted)),
                if (b.status == 'rejected')
                  StatusBanner(
                    'Rejected${(d.rejectionReason ?? '').isNotEmpty ? ': ${d.rejectionReason}' : ''}',
                    color: AppColors.danger,
                  ),
                if (b.status == 'cancelled')
                  StatusBanner(
                    'Cancelled${(d.cancellationReason ?? '').isNotEmpty ? ': ${d.cancellationReason}' : ''}',
                    color: AppColors.danger,
                  ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Customer',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.customer?.name ?? 'Customer',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if ((b.customer?.phone ?? '').isNotEmpty)
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            Uri(scheme: 'tel', path: b.customer!.phone),
                          ),
                          icon: const Icon(Icons.call_outlined, size: 18),
                          label: Text(b.customer!.phone!),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Appointment',
                  trailing: b.status == 'accepted' || b.status == 'picked_up'
                      ? TextButton(
                          onPressed: _busy ? null : () => _reschedule(b),
                          child: const Text('Change'),
                        )
                      : null,
                  child: Column(
                    children: [
                      InfoRow('Preferred', whenText(b.preferred)),
                      InfoRow(
                        'Confirmed',
                        b.confirmed.isSet
                            ? whenText(b.confirmed)
                            : (b.isNew ? 'Not yet — accept to confirm' : '—'),
                        bold: b.confirmed.isSet,
                      ),
                      if (d.durationMinutes != null)
                        InfoRow(
                          'Estimated time',
                          'About ${d.durationMinutes! >= 60 ? '${d.durationMinutes! ~/ 60} h ${d.durationMinutes! % 60 == 0 ? '' : '${d.durationMinutes! % 60} min'}' : '${d.durationMinutes} min'}',
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Cycle & problem',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ('${d.cycle['brand'] ?? ''}'.isNotEmpty)
                        InfoRow('Brand', '${d.cycle['brand']}'),
                      if ('${d.cycle['model'] ?? ''}'.isNotEmpty)
                        InfoRow('Model', '${d.cycle['model']}'),
                      if ('${d.cycle['details'] ?? ''}'.isNotEmpty)
                        InfoRow('Details', '${d.cycle['details']}'),
                      const SizedBox(height: 4),
                      Text(
                        'Problem described',
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 13,
                        ),
                      ),
                      Text(b.issue),
                      if (d.images.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 90,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: d.images.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, i) => SizedBox(
                              width: 90,
                              child: InkWell(
                                onTap: d.images[i].url == null
                                    ? null
                                    : () => showDialog<void>(
                                        context: context,
                                        builder: (c) => Dialog(
                                          child: InteractiveViewer(
                                            child: AppNetworkImage(
                                              d.images[i].url,
                                              fit: BoxFit.contain,
                                              radius: 8,
                                            ),
                                          ),
                                        ),
                                      ),
                                child: AppNetworkImage(
                                  d.images[i].url,
                                  radius: 10,
                                  icon: Icons.image_outlined,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ] else
                        Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'No photos attached.',
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (d.logistics != null) ...[
                  const SizedBox(height: 12),
                  _LogisticsSummary(b: b, l: d.logistics!),
                ],
                const SizedBox(height: 12),
                if (!const {
                  'pending',
                  'rejected',
                  'cancelled',
                }.contains(b.status)) ...[
                  _RepairProgress(b: b),
                  const SizedBox(height: 12),
                ],
                SectionCard(
                  title: 'Price & charges',
                  trailing: b.chargesOpen
                      ? TextButton.icon(
                          onPressed: _busy ? null : () => _addCharge(b),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add charge'),
                        )
                      : null,
                  child: Column(
                    children: [
                      AmountRow('Original estimate', d.pricing.estimated),
                      for (final c in d.charges)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '${c.amount >= 0 ? 'Additional' : 'Correction'}: ${c.reason}${c.role != null ? '  (${c.role})' : ''}',
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
                      const Divider(height: 16),
                      AmountRow(
                        'Current service price',
                        d.pricing.current,
                        bold: true,
                      ),
                      if (b.needsPickup) ...[
                        AmountRow('Pickup charge', d.pricing.pickup),
                        AmountRow('Drop-off charge', d.pricing.dropoff),
                        AmountRow(
                          'Total incl. pickup/drop-off',
                          d.pricing.totalCurrent,
                          bold: true,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        'The original estimate is never overwritten; extra work is recorded as separate charges. Customer approval of extra charges is not available in the platform yet, so recorded charges are NOT confirmed by the customer. Nothing is collected through the app; settle payment with the customer directly.',
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
                  title: 'Service notes',
                  trailing: TextButton.icon(
                    onPressed:
                        _busy ||
                            const {'rejected', 'cancelled'}.contains(b.status)
                        ? null
                        : () => _addNote(b),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add note'),
                  ),
                  child: d.notes.isEmpty && (d.completionNotes ?? '').isEmpty
                      ? Text(
                          'No notes yet.',
                          style: TextStyle(color: context.palette.muted),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final n in d.notes)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  n.role == 'vendor'
                                      ? Icons.storefront_outlined
                                      : Icons.sticky_note_2_outlined,
                                  size: 20,
                                ),
                                title: Text(n.note),
                                subtitle: Text(
                                  '${humanize(n.role)} · ${dateTime(n.at)}',
                                ),
                              ),
                            if ((d.completionNotes ?? '').isNotEmpty)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.verified_outlined,
                                  color: AppColors.success,
                                ),
                                title: const Text('Completion notes'),
                                subtitle: Text(d.completionNotes!),
                              ),
                          ],
                        ),
                ),
                timeline.maybeWhen(
                  data: (events) => events.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: SectionCard(
                            title: 'Status history',
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
                                          decoration: BoxDecoration(
                                            color: context.palette.primary,
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
                                                bookingStatusLabel(e.toStatus),
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              Text(
                                                dateTime(e.at),
                                                style: TextStyle(
                                                  color: context.palette.muted,
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
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
                const SizedBox(height: 20),
                if (b.isNew)
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: 'Reject',
                          outlined: true,
                          danger: true,
                          onPressed: _busy ? null : () => _reject(b),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppButton(
                          label: 'Accept',
                          busy: _busy,
                          onPressed: () => _accept(b),
                        ),
                      ),
                    ],
                  ),
                for (final s in b.nextSteps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppButton(
                      label: 'Mark as ${bookingStatusLabel(s)}',
                      busy: _busy,
                      onPressed: () => _advance(b, s),
                    ),
                  ),
                if (b.canCancel)
                  AppButton(
                    label: 'Cancel booking',
                    outlined: true,
                    danger: true,
                    onPressed: _busy ? null : () => _cancel(b),
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

Future<String?> _askNote(
  BuildContext context, {
  required String title,
  required String hint,
  required bool required,
}) {
  final ctrl = TextEditingController();
  final key = GlobalKey<FormState>();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.of(c).viewInsets.bottom + 20,
      ),
      child: Form(
        key: key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextFormField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              maxLength: 1000,
              decoration: InputDecoration(hintText: hint),
              validator: (v) => required && (v ?? '').trim().length < 2
                  ? 'Please write a note'
                  : null,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                if (key.currentState!.validate()) {
                  Navigator.pop(c, ctrl.text.trim());
                }
              },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(ctrl.dispose);
}

class _ChargeSheet extends StatefulWidget {
  const _ChargeSheet({required this.estimated, required this.current});
  final double estimated, current;
  @override
  State<_ChargeSheet> createState() => _ChargeSheetState();
}

class _ChargeSheetState extends State<_ChargeSheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController(), _reason = TextEditingController();
  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amt = double.tryParse(_amount.text.trim());
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Record an additional charge',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Original estimate ${money(widget.estimated)} · current price ${money(widget.current)}',
              style: TextStyle(color: context.palette.muted),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount (₹)',
                helperText:
                    'Use a negative amount to record a correction/discount',
              ),
              validator: (v) {
                final d = double.tryParse((v ?? '').trim());
                return d == null || d == 0 ? 'Enter a non-zero amount' : null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _reason,
              onChanged: (_) => setState(() {}),
              maxLines: 2,
              maxLength: 300,
              decoration: const InputDecoration(
                labelText: 'Reason (shown to the customer)',
              ),
              validator: (v) => (v ?? '').trim().length < 3
                  ? 'Please explain the extra work'
                  : null,
            ),
            if (amt != null && amt != 0)
              Text(
                'New current price: ${money(widget.current + amt)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                if (_form.currentState!.validate()) {
                  Navigator.pop(context, (
                    double.parse(_amount.text.trim()),
                    _reason.text.trim(),
                  ));
                }
              },
              child: const Text('Record charge'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RepairProgress extends StatelessWidget {
  const _RepairProgress({required this.b});
  final VendorBooking b;
  @override
  Widget build(BuildContext context) {
    final steps = [
      ('accepted', 'Accepted'),
      if (b.needsPickup) ('picked_up', 'Picked up'),
      ('in_service', 'In service'),
      (
        'ready_for_delivery',
        b.needsPickup ? 'Ready for delivery' : 'Ready to collect',
      ),
      ('completed', 'Completed'),
    ];
    final idx = steps.indexWhere((s) => s.$1 == b.status);
    return SectionCard(
      title: 'Repair progress',
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Icon(
                      i <= idx
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 22,
                      color: i <= idx
                          ? context.palette.primary
                          : context.palette.line,
                    ),
                    if (i < steps.length - 1)
                      Container(
                        width: 2,
                        height: 22,
                        color: i < idx
                            ? context.palette.primary
                            : context.palette.line,
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    steps[i].$2,
                    style: TextStyle(
                      fontWeight: i == idx ? FontWeight.w800 : FontWeight.w500,
                      color: i <= idx
                          ? context.palette.ink
                          : context.palette.muted,
                    ),
                  ),
                ),
              ],
            ),
          if (b.needsPickup)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Marking “Picked up” records the pickup as done; “Completed” records the return delivery as done. Pickup/drop-off scheduling is coordinated separately.',
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _LogisticsSummary extends ConsumerWidget {
  const _LogisticsSummary({required this.b, required this.l});
  final VendorBooking b;
  final Logistics l;
  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Pickup & drop-off (separate from repair status)',
    trailing: TextButton(
      onPressed: () => context.push('/pickups/${l.id}'),
      child: const Text('Coordinate'),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Pickup', style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            StatusChip(l.pickupStage, label: stageLabel(l.pickupStage)),
          ],
        ),
        Text(
          Logistics.addressText(l.pickupAddress),
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text(
              'Return delivery',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            StatusChip(l.deliveryStage, label: stageLabel(l.deliveryStage)),
          ],
        ),
        Text(
          Logistics.addressText(l.dropoffAddress),
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        if ((l.instructions ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Customer instructions: ${l.instructions}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    ),
  );
}
