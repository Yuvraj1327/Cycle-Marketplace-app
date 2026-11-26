import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_service.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../addresses/models.dart';
import '../addresses/providers.dart';
import '../addresses/screens.dart';
import '../services/models.dart';
import '../services/providers.dart';
import 'models.dart';

class PickedPhoto {
  PickedPhoto(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
  String get extension {
    final e = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpg';
    return const {'jpg', 'jpeg', 'png', 'webp'}.contains(e)
        ? (e == 'jpeg' ? 'jpg' : e)
        : 'jpg';
  }

  String get contentType => switch (extension) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

/// Shared by the booking flow and the booking detail screen. Uploads each photo straight to Supabase Storage with the user's own session,
/// then registers its path with the backend (which verifies it). Returns how many failed.
Future<int> uploadBookingPhotos(
  WidgetRef ref,
  String bookingId,
  List<PickedPhoto> photos,
) async {
  final uid = ref.read(currentUserIdProvider)!;
  var failed = 0;
  for (final p in photos) {
    try {
      final path = await ref
          .read(imageStorageProvider)
          .uploadBookingImage(
            userId: uid,
            bookingId: bookingId,
            bytes: p.bytes,
            extension: p.extension,
            contentType: p.contentType,
          );
      await ref.read(bookingRepositoryProvider).registerImage(bookingId, path);
    } on AuthFailure {
      failed++;
    } on ApiException {
      failed++;
    }
  }
  return failed;
}

Future<List<PickedPhoto>> pickPhotos({int max = 5}) async {
  final files = await ImagePicker().pickMultiImage(
    imageQuality: 80,
    maxWidth: 1600,
    limit: max,
  );
  final out = <PickedPhoto>[];
  for (final f in files.take(max)) {
    final bytes = await f.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      continue; // the Storage bucket limit is 5 MB
    }
    out.add(PickedPhoto(f.name, bytes));
  }
  return out;
}

class BookingFlowScreen extends ConsumerStatefulWidget {
  const BookingFlowScreen({super.key, required this.serviceId});
  final String serviceId;
  @override
  ConsumerState<BookingFlowScreen> createState() => _BookingFlowScreenState();
}

class _BookingFlowScreenState extends ConsumerState<BookingFlowScreen> {
  int _step = 0;
  final _form = GlobalKey<FormState>();
  final _brand = TextEditingController(),
      _model = TextEditingController(),
      _details = TextEditingController(),
      _issue = TextEditingController(),
      _instructions = TextEditingController();
  final List<PickedPhoto> _photos = [];
  DateTime? _date;
  Slot? _slot;
  bool _pickup = false, _sameAddress = true, _submitting = false;
  String? _pickupAddressId, _dropoffAddressId, _slotMessage;

  @override
  void dispose() {
    for (final c in [_brand, _model, _details, _issue, _instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  static const _titles = ['Your cycle', 'Date & time', 'Pickup', 'Review'];

  void _next(ServiceItem s) {
    if (_step == 0 && !_form.currentState!.validate()) return;
    if (_step == 1 && (_date == null || _slot == null)) {
      showSnack(
        context,
        'Choose a date and an available time slot.',
        error: true,
      );
      return;
    }
    if (_step == 2 && _pickup && _pickupAddressId == null) {
      showSnack(context, 'Choose a pickup address.', error: true);
      return;
    }
    if (_step == 2 && _pickup && !_sameAddress && _dropoffAddressId == null) {
      showSnack(context, 'Choose a drop-off address.', error: true);
      return;
    }
    setState(() => _step++);
  }

  Future<void> _submit(ServiceItem s) async {
    if (_submitting) return; // prevents duplicate bookings from double taps
    setState(() => _submitting = true);
    try {
      final req = BookingRequest(
        serviceId: s.id,
        cycleBrand: _brand.text.trim(),
        cycleModel: _model.text.trim(),
        cycleDetails: _details.text.trim(),
        issue: _issue.text.trim(),
        date: isoDate(_date!),
        slotStart: _slot!.start,
        needsPickup: _pickup,
        pickupAddressId: _pickupAddressId,
        dropoffAddressId: _sameAddress ? null : _dropoffAddressId,
        instructions: _instructions.text.trim(),
      );
      final booking = await ref.read(bookingRepositoryProvider).create(req);
      ref.read(bookingsTickProvider.notifier).bump();
      var failed = 0;
      if (_photos.isNotEmpty) {
        failed = await uploadBookingPhotos(ref, booking.summary.id, _photos);
      }
      if (!mounted) return;
      if (failed > 0) {
        showSnack(
          context,
          '$failed photo${failed == 1 ? '' : 's'} could not be uploaded. You can add them from the booking.',
          error: true,
        );
      }
      context.pushReplacement('/bookings/${booking.summary.id}?new=1');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'slot_full' ||
          e.code == 'invalid_slot' ||
          e.code == 'slot_unavailable') {
        setState(() {
          _slot = null;
          _step = 1;
        });
        ref.invalidate(availabilityProvider);
      }
      showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(serviceDetailProvider(widget.serviceId));
    return Scaffold(
      appBar: AppBar(
        title: Text('Book: ${_titles[_step]}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / _titles.length,
            minHeight: 4,
            backgroundColor: context.palette.line,
          ),
        ),
      ),
      body: AsyncBody<ServiceItem>(
        value: service,
        onRetry: () => ref.invalidate(serviceDetailProvider(widget.serviceId)),
        builder: (s) => PopScope(
          canPop: _step == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _step--);
          },
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: switch (_step) {
                    0 => _cycleStep(s),
                    1 => _dateStep(s),
                    2 => _pickupStep(s),
                    _ => _reviewStep(s),
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: context.palette.surface,
                    border: Border(
                      top: BorderSide(color: context.palette.line),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (_step > 0)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _submitting
                                ? null
                                : () => setState(() => _step--),
                            child: const Text('Back'),
                          ),
                        ),
                      if (_step > 0) const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: _submitting
                              ? null
                              : (_step == 3
                                    ? () => _submit(s)
                                    : () => _next(s)),
                          child: _submitting
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _step == 3 ? 'Confirm booking' : 'Continue',
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- step 1
  Widget _cycleStep(ServiceItem s) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ServiceHeader(s),
        const SizedBox(height: 16),
        TextFormField(
          controller: _brand,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Cycle brand (optional)',
            prefixIcon: Icon(Icons.pedal_bike),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _model,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Model (optional)'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _details,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Type / size / colour (optional)',
            hintText: 'e.g. 26" hybrid, blue',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _issue,
          maxLines: 4,
          maxLength: 2000,
          decoration: const InputDecoration(
            labelText: 'Describe the problem',
            hintText: 'e.g. Rear brake squeals and the chain keeps slipping',
            alignLabelWithHint: true,
          ),
          validator: (v) => (v ?? '').trim().length < 10
              ? 'Please describe the problem (at least 10 characters)'
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          'Photos (optional, up to 5)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _photos.length; i++)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      _photos[i].bytes,
                      width: 78,
                      height: 78,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: InkWell(
                      onTap: () => setState(() => _photos.removeAt(i)),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(3),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            if (_photos.length < 5)
              InkWell(
                onTap: () async {
                  final added = await pickPhotos(max: 5 - _photos.length);
                  if (added.isNotEmpty) setState(() => _photos.addAll(added));
                },
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    border: Border.all(color: context.palette.primary),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.add_a_photo_outlined,
                    color: context.palette.primary,
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  // ---------------------------------------------------------------- step 2
  Widget _dateStep(ServiceItem s) {
    final opts = ref.watch(bookingOptionsProvider).value;
    final today = DateTime.now();
    final first = DateTime(today.year, today.month, today.day);
    final last = first.add(Duration(days: opts?.maxAdvanceDays ?? 60));
    final avail = _date == null
        ? null
        : ref.watch(availabilityProvider((s.id, isoDate(_date!))));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ServiceHeader(s),
        const SizedBox(height: 16),
        Text('Preferred date', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_month_outlined),
          label: Text(_date == null ? 'Choose a date' : dayLabel(_date!)),
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _date ?? first,
              firstDate: first,
              lastDate: last,
            );
            if (d != null) {
              setState(() {
                _date = d;
                _slot = null;
              });
            }
          },
        ),
        const SizedBox(height: 18),
        Text('Time slot', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'This is your preferred time. The provider confirms the appointment when they accept.',
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        if (avail == null)
          Text(
            'Pick a date to see available slots.',
            style: TextStyle(color: context.palette.muted),
          )
        else
          avail.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
              e,
              onRetry: () => ref.invalidate(availabilityProvider),
            ),
            data: (a) => a.slots.isEmpty
                ? Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      a.reasonText,
                      style: const TextStyle(
                        color: AppColors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sl in a.slots)
                        ChoiceChip(
                          label: Text(
                            '${time12(sl.start)} – ${time12(sl.end)}${sl.available ? '' : '  (full)'}',
                          ),
                          selected: _slot?.start == sl.start,
                          onSelected: sl.available
                              ? (_) => setState(() => _slot = sl)
                              : null,
                        ),
                    ],
                  ),
          ),
        if (_slotMessage != null) Text(_slotMessage!),
      ],
    );
  }

  // ---------------------------------------------------------------- step 3
  Widget _pickupStep(ServiceItem s) {
    final canPickup = s.provider?.pickupAvailable == true;
    final addresses = ref.watch(addressesProvider).value ?? const <Address>[];
    final opts = ref.watch(bookingOptionsProvider).value;
    final pickupList = addresses.where((a) => a.usableForPickup).toList();
    final dropList = addresses.where((a) => a.usableForDelivery).toList();
    Address? find(List<Address> l, String? id) =>
        l.where((a) => a.id == id).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ServiceHeader(s),
        const SizedBox(height: 12),
        if (!canPickup)
          Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(
                    Icons.storefront_outlined,
                    color: context.palette.primary,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This provider does not offer doorstep pickup. Please bring your cycle to the shop at the confirmed time.',
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Doorstep pickup & drop-off',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text(
              'The provider collects your cycle and brings it back after servicing.',
            ),
            value: _pickup,
            onChanged: (v) => setState(() => _pickup = v),
          ),
          if (_pickup) ...[
            const Divider(),
            Text(
              'Pickup address',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _AddressPicker(
              selected: find(pickupList, _pickupAddressId),
              onPick: (a) => setState(() => _pickupAddressId = a.id),
              kind: 'pickup',
              all: pickupList,
            ),
            if (s.provider!.serviceAreaPostalCodes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Service area: PIN ${s.provider!.serviceAreaPostalCodes.join(', ')}',
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Return to the same address'),
              value: _sameAddress,
              onChanged: (v) => setState(() => _sameAddress = v),
            ),
            if (!_sameAddress)
              _AddressPicker(
                selected: find(dropList, _dropoffAddressId),
                onPick: (a) => setState(() => _dropoffAddressId = a.id),
                kind: 'drop-off',
                all: dropList,
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _instructions,
              maxLength: 500,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Pickup instructions (optional)',
                hintText: 'Gate number, landmark, call before arriving...',
                counterText: '',
              ),
            ),
            Card(
              color: context.palette.primary.withValues(alpha: .06),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: opts == null
                    ? const Text('Loading charges…')
                    : opts.chargesConfigured
                    ? Column(
                        children: [
                          AmountRow('Pickup charge', opts.pickupCharge ?? 0),
                          AmountRow('Drop-off charge', opts.dropoffCharge ?? 0),
                        ],
                      )
                    : const Text(
                        'Pickup and drop-off charges have not been set by the platform yet. Your booking will show the amount once it is configured.',
                        style: TextStyle(fontSize: 13),
                      ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  // ---------------------------------------------------------------- step 4
  Widget _reviewStep(ServiceItem s) {
    final addresses = ref.watch(addressesProvider).value ?? const <Address>[];
    final opts = ref.watch(bookingOptionsProvider).value;
    String addr(String? id) =>
        addresses
            .where((a) => a.id == id)
            .map((a) => '${a.recipientName}, ${a.oneLine}')
            .firstOrNull ??
        '';
    final pickupCharge = _pickup ? (opts?.pickupCharge ?? 0) : 0.0,
        dropCharge = _pickup ? (opts?.dropoffCharge ?? 0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Review your booking',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoRow('Service', s.name, bold: true),
                InfoRow('Provider', s.provider?.businessName ?? ''),
                if (_brand.text.trim().isNotEmpty ||
                    _model.text.trim().isNotEmpty)
                  InfoRow(
                    'Cycle',
                    [
                      _brand.text.trim(),
                      _model.text.trim(),
                    ].where((e) => e.isNotEmpty).join(' '),
                  ),
                InfoRow('Problem', _issue.text.trim()),
                if (_photos.isNotEmpty)
                  InfoRow('Photos', '${_photos.length} attached'),
                const Divider(),
                InfoRow(
                  'Preferred time',
                  '${dayLabel(_date!)}, ${time12(_slot!.start)} – ${time12(_slot!.end)}',
                ),
                InfoRow(
                  'Pickup',
                  _pickup
                      ? 'Doorstep pickup & drop-off'
                      : 'I will bring the cycle to the shop',
                ),
                if (_pickup) InfoRow('Pickup from', addr(_pickupAddressId)),
                if (_pickup)
                  InfoRow(
                    'Return to',
                    _sameAddress ? 'Same address' : addr(_dropoffAddressId),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                AmountRow('Estimated service price', s.price),
                if (_pickup) AmountRow('Pickup charge', pickupCharge),
                if (_pickup) AmountRow('Drop-off charge', dropCharge),
                const Divider(height: 18),
                AmountRow(
                  'Estimated total',
                  s.price + pickupCharge + dropCharge,
                  bold: true,
                ),
                const SizedBox(height: 6),
                Text(
                  'No payment is taken now. If the provider finds extra work needed, any additional charge is recorded on your booking and you are notified.',
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ServiceHeader extends StatelessWidget {
  const _ServiceHeader(this.s);
  final ServiceItem s;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.palette.primary.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(Icons.build_circle_outlined, color: context.palette.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(
                s.provider?.businessName ?? '',
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        PriceText(s.price),
      ],
    ),
  );
}

class _AddressPicker extends ConsumerWidget {
  const _AddressPicker({
    required this.selected,
    required this.onPick,
    required this.kind,
    required this.all,
  });
  final Address? selected;
  final ValueChanged<Address> onPick;
  final String kind;
  final List<Address> all;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (all.isEmpty) {
      return OutlinedButton.icon(
        onPressed: () => context.push('/address-form'),
        icon: const Icon(Icons.add),
        label: Text('Add a $kind address'),
      );
    }
    return Column(
      children: [
        if (selected != null)
          AddressCard(address: selected!, manage: false, selected: true)
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: context.palette.line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'No $kind address chosen',
              style: TextStyle(color: context.palette.muted),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () async {
              final a = await showModalBottomSheet<Address>(
                context: context,
                isScrollControlled: true,
                builder: (c) => SafeArea(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final a in all)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AddressCard(
                            address: a,
                            manage: false,
                            selected: a.id == selected?.id,
                            onTap: () => Navigator.pop(c, a),
                          ),
                        ),
                    ],
                  ),
                ),
              );
              if (a != null) onPick(a);
            },
            child: Text(selected == null ? 'Choose' : 'Change'),
          ),
        ),
      ],
    );
  }
}
