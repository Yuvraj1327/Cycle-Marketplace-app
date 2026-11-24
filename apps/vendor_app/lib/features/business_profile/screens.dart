import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_service.dart';
import '../../core/providers.dart';
import '../../core/utils/images.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/vendor_widgets.dart';
import 'models.dart';

String hhmm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay? parseHhmm(String? s) {
  if (s == null || s.length < 5) return null;
  final p = s.split(':');
  return TimeOfDay(
    hour: int.tryParse(p[0]) ?? 0,
    minute: int.tryParse(p[1]) ?? 0,
  );
}

/// Weekly opening hours. Closed days send `{closed: true}`; open days need open < close (the backend re-validates).
class HoursEditor extends StatelessWidget {
  const HoursEditor({super.key, required this.hours, required this.onChanged});
  final Map<String, DayHours> hours;
  final ValueChanged<Map<String, DayHours>> onChanged;

  Future<void> _pick(BuildContext context, String day, bool isOpen) async {
    final cur = hours[day] ?? const DayHours(open: '09:00', close: '18:00');
    final t = await showTimePicker(
      context: context,
      initialTime:
          parseHhmm(isOpen ? cur.open : cur.close) ??
          const TimeOfDay(hour: 9, minute: 0),
    );
    if (t == null) return;
    onChanged({
      ...hours,
      day: DayHours(
        open: isOpen ? hhmm(t) : cur.open ?? '09:00',
        close: isOpen ? cur.close ?? '18:00' : hhmm(t),
      ),
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final d in weekdays)
        Builder(
          builder: (context) {
            final h = hours[d];
            final closed = h == null || h.closed;
            return Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    weekdayLabels[d]!,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Switch(
                  value: !closed,
                  onChanged: (open) => onChanged({
                    ...hours,
                    d: open
                        ? const DayHours(open: '09:00', close: '18:00')
                        : const DayHours(closed: true),
                  }),
                ),
                if (closed)
                  const Text('Closed', style: TextStyle(color: AppColors.muted))
                else ...[
                  TextButton(
                    onPressed: () => _pick(context, d, true),
                    child: Text(h.open ?? '--:--'),
                  ),
                  const Text('to'),
                  TextButton(
                    onPressed: () => _pick(context, d, false),
                    child: Text(h.close ?? '--:--'),
                  ),
                ],
              ],
            );
          },
        ),
    ],
  );
}

/// Register the business (first time) or edit it. Verification status is never part of the form: only the admin can change it.
class BusinessFormScreen extends ConsumerStatefulWidget {
  const BusinessFormScreen({super.key, required this.editing});
  final bool editing;
  @override
  ConsumerState<BusinessFormScreen> createState() => _BusinessFormScreenState();
}

class _BusinessFormScreenState extends ConsumerState<BusinessFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name,
      _desc,
      _a1,
      _a2,
      _city,
      _state,
      _pin,
      _phone,
      _email,
      _areas,
      _radius;
  final Set<BusinessType> _types = {};
  Map<String, DayHours> _hours = {
    for (final d in weekdays)
      d: d == 'sun'
          ? const DayHours(closed: true)
          : const DayHours(open: '09:00', close: '18:00'),
  };
  List<String> _images = [];
  bool _pickup = false, _busy = false;
  String? _progress, _error;

  @override
  void initState() {
    super.initState();
    final v = widget.editing ? ref.read(authControllerProvider).vendor : null;
    _name = TextEditingController(text: v?.businessName);
    _desc = TextEditingController(text: v?.description);
    _a1 = TextEditingController(text: v?.addressLine1);
    _a2 = TextEditingController(text: v?.addressLine2);
    _city = TextEditingController(text: v?.city);
    _state = TextEditingController(text: v?.state);
    _pin = TextEditingController(text: v?.postalCode);
    _phone = TextEditingController(text: v?.contactPhone);
    _email = TextEditingController(
      text: v?.contactEmail ?? ref.read(authControllerProvider).me?.email,
    );
    _areas = TextEditingController(text: v?.servicePostalCodes.join(', '));
    _radius = TextEditingController(text: v?.serviceRadiusKm?.toString());
    if (v != null) {
      _types.addAll(v.businessTypes);
      if (v.operatingHours.isNotEmpty) {
        _hours = {
          for (final d in weekdays)
            d: v.operatingHours[d] ?? const DayHours(closed: true),
        };
      }
      _images = [...v.shopImagePaths];
      _pickup = v.pickupAvailable;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _desc,
      _a1,
      _a2,
      _city,
      _state,
      _pin,
      _phone,
      _email,
      _areas,
      _radius,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _addImages() async {
    final picked = await pickImages(context, max: 10 - _images.length);
    if (picked.isEmpty || !mounted) return;
    final uid = ref.read(authServiceProvider).userId;
    if (uid == null) return;
    setState(() => _busy = true);
    var failed = 0;
    for (var i = 0; i < picked.length; i++) {
      setState(
        () => _progress = 'Uploading image ${i + 1} of ${picked.length}…',
      );
      try {
        final path = await ref
            .read(imageStorageProvider)
            .upload(
              bucket: ImageBucket.shopImages,
              userId: uid,
              folder: 'shop',
              bytes: picked[i].bytes,
              extension: picked[i].extension,
              contentType: picked[i].contentType,
            );
        _images.add(path);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
    });
    if (failed > 0) {
      showSnack(
        context,
        '$failed image${failed == 1 ? '' : 's'} could not be uploaded.',
        error: true,
      );
    }
  }

  List<String> _codes() => _areas.text
      .split(RegExp(r'[,\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList();

  Future<void> _submit() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) return;
    if (_types.isEmpty) {
      setState(() => _error = 'Choose at least one business type.');
      return;
    }
    for (final e in _hours.entries) {
      final h = e.value;
      if (!h.closed && ((h.open ?? '').compareTo(h.close ?? '') >= 0)) {
        setState(
          () => _error =
              '${weekdayLabels[e.key]}: closing time must be after opening time.',
        );
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final input = BusinessInput(
      businessName: _name.text.trim(),
      businessTypes: _types.toList(),
      description: _desc.text.trim(),
      addressLine1: _a1.text.trim(),
      addressLine2: _a2.text.trim(),
      city: _city.text.trim(),
      state: _state.text.trim(),
      postalCode: _pin.text.trim(),
      contactPhone: _phone.text.trim(),
      contactEmail: _email.text.trim(),
      operatingHours: _hours,
      shopImagePaths: _images,
      servicePostalCodes: _codes(),
      serviceRadiusKm: double.tryParse(_radius.text.trim()),
      pickupAvailable: _pickup,
    );
    try {
      final repo = ref.read(vendorProfileRepositoryProvider);
      final saved = widget.editing
          ? await repo.update(input)
          : await repo.register(input);
      ref.read(authControllerProvider.notifier).setVendor(saved);
      if (!mounted) return;
      showSnack(
        context,
        widget.editing
            ? 'Business details saved'
            : 'Application submitted for verification',
      );
      if (widget.editing && context.canPop()) context.pop();
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.details.isEmpty
              ? e.message
              : '${e.message} (${e.details.map((d) => d['field']).join(', ')})',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final storage = ref.read(imageStorageProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editing ? 'Edit business' : 'Business details'),
        actions: [
          if (!widget.editing)
            TextButton(
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
              child: const Text('Log out'),
            ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (!widget.editing)
              const StatusBanner(
                'Step 2 of 2 — tell us about your business. An administrator verifies it before you can list products or services.',
                icon: Icons.verified_outlined,
              ),
            if (_error != null)
              StatusBanner(
                _error!,
                color: AppColors.danger,
                icon: Icons.error_outline,
              ),
            Text(
              'Business type',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in BusinessType.values)
                  FilterChip(
                    label: Text(t.label),
                    selected: _types.contains(t),
                    onSelected: (s) =>
                        setState(() => s ? _types.add(t) : _types.remove(t)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Business name'),
              maxLength: 150,
              validator: (v) =>
                  (v ?? '').trim().length < 2 ? 'At least 2 characters' : null,
            ),
            TextFormField(
              controller: _desc,
              decoration: const InputDecoration(
                labelText: 'About your business (optional)',
                alignLabelWithHint: true,
              ),
              maxLines: 3,
              maxLength: 2000,
            ),
            const SizedBox(height: 8),
            Text('Address', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              controller: _a1,
              decoration: const InputDecoration(labelText: 'Address line 1'),
              validator: _required,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _a2,
              decoration: const InputDecoration(
                labelText: 'Address line 2 (optional)',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _city,
                    decoration: const InputDecoration(labelText: 'City'),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _state,
                    decoration: const InputDecoration(labelText: 'State'),
                    validator: _required,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _pin,
              decoration: const InputDecoration(labelText: 'Postal code'),
              validator: (v) =>
                  RegExp(r'^[A-Za-z0-9 \-]{3,10}$').hasMatch((v ?? '').trim())
                  ? null
                  : '3-10 letters/digits',
            ),
            const SizedBox(height: 16),
            Text('Contact', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Business phone',
                hintText: '+919876543210',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              validator: (v) =>
                  RegExp(r'^\+?[0-9]{7,15}$').hasMatch((v ?? '').trim())
                  ? null
                  : 'Enter 7-15 digits',
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Business e-mail (optional)',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ||
                      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim())
                  ? null
                  : 'Enter a valid e-mail',
            ),
            const SizedBox(height: 16),
            Text(
              'Operating hours',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            HoursEditor(
              hours: _hours,
              onChanged: (h) => setState(() => _hours = h),
            ),
            const SizedBox(height: 12),
            Text(
              'Service area & pickup',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Offer doorstep pickup & drop-off'),
              subtitle: const Text(
                'Customers can ask you to collect and return their cycle.',
              ),
              value: _pickup,
              onChanged: (v) => setState(() => _pickup = v),
            ),
            TextFormField(
              controller: _areas,
              decoration: const InputDecoration(
                labelText: 'Pickup service-area postal codes',
                hintText: '411001, 411002',
                helperText:
                    'Comma separated. Leave empty to serve any address.',
              ),
              validator: (v) =>
                  _codes().every(
                    (c) => RegExp(r'^[A-Za-z0-9 \-]{3,10}$').hasMatch(c),
                  )
                  ? null
                  : 'Check the postal codes',
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _radius,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Service radius in km (optional)',
              ),
              validator: (v) {
                final d = double.tryParse((v ?? '').trim());
                return (v ?? '').trim().isEmpty ||
                        (d != null && d >= 0 && d <= 500)
                    ? null
                    : '0-500';
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Shop photos (${_images.length}/10)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy || _images.length >= 10 ? null : _addImages,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(_progress!),
                  ],
                ),
              ),
            if (_images.isEmpty)
              const Text(
                'No photos yet.',
                style: TextStyle(color: AppColors.muted),
              )
            else
              SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Stack(
                    children: [
                      SizedBox(
                        width: 92,
                        height: 92,
                        child: AppNetworkImage(
                          storage.publicUrl(ImageBucket.shopImages, _images[i]),
                          radius: 10,
                          icon: Icons.storefront,
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: InkWell(
                          onTap: () => setState(() => _images.removeAt(i)),
                          child: const CircleAvatar(
                            radius: 11,
                            backgroundColor: Colors.black54,
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 22),
            AppButton(
              label: widget.editing
                  ? 'Save changes'
                  : 'Submit for verification',
              busy: _busy && _progress == null,
              onPressed: _busy ? null : _submit,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Pending / rejected / suspended: the vendor cannot operate yet. All facts come from the backend.
class VendorStatusScreen extends ConsumerStatefulWidget {
  const VendorStatusScreen({super.key});
  @override
  ConsumerState<VendorStatusScreen> createState() => _VendorStatusScreenState();
}

class _VendorStatusScreenState extends ConsumerState<VendorStatusScreen> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    await ref.read(authControllerProvider.notifier).refreshVendor();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final v = auth.vendor;
    final (icon, color, title, body) = switch (auth.stage) {
      VendorStage.rejected => (
        Icons.cancel_outlined,
        AppColors.danger,
        'Application not approved',
        'Your business application was not approved.',
      ),
      VendorStage.suspended => (
        Icons.block,
        AppColors.danger,
        'Account suspended',
        'Your vendor account is suspended, so you cannot list products, take orders or manage bookings.',
      ),
      _ => (
        Icons.hourglass_top_rounded,
        AppColors.warning,
        'Verification pending',
        'Your application was submitted and is waiting for an administrator to verify it. You will be able to list products and services once it is approved.',
      ),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Business status'),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
            child: const Text('Log out'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _check,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Icon(icon, size: 72, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted),
            ),
            if ((v?.rejectionReason ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              StatusBanner(
                'Reason from the administrator: ${v!.rejectionReason}',
                color: AppColors.danger,
              ),
            ],
            if (v != null) ...[
              const SizedBox(height: 20),
              SectionCard(
                title: v.businessName,
                child: Column(
                  children: [
                    InfoRow(
                      'Type',
                      v.businessTypes.map((t) => t.label).join(', '),
                    ),
                    InfoRow('City', '${v.city}, ${v.state}'),
                    InfoRow('Phone', v.contactPhone),
                    InfoRow(
                      'Status',
                      humanizeStatus(v.verificationStatus),
                      bold: true,
                      color: color,
                    ),
                    if (v.reviewedAt != null)
                      InfoRow(
                        'Reviewed',
                        '${v.reviewedAt!.toLocal()}'.split('.').first,
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            AppButton(
              label: 'Check status',
              icon: Icons.refresh,
              busy: _checking,
              onPressed: _check,
            ),
            if (auth.stage == VendorStage.rejected) ...[
              const SizedBox(height: 10),
              AppButton(
                label: 'Update business details',
                outlined: true,
                icon: Icons.edit_outlined,
                onPressed: () => context.push('/business/edit'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your changes are saved to your application. There is no automatic re-submission yet: an administrator decides whether to review it again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
            if (auth.stage == VendorStage.suspended &&
                (AppConfig.supportEmail.isNotEmpty ||
                    AppConfig.supportPhone.isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  'Contact support: ${[AppConfig.supportEmail, AppConfig.supportPhone].where((e) => e.isNotEmpty).join(' · ')}',
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String humanizeStatus(String s) => s.isEmpty
    ? s
    : '${s[0].toUpperCase()}${s.substring(1).replaceAll('_', ' ')}';

/// Read-only business profile with an Edit action (not available while suspended: the backend refuses it too).
class BusinessProfileScreen extends ConsumerWidget {
  const BusinessProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final v = auth.vendor;
    final storage = ref.read(imageStorageProvider);
    if (v == null) return const Scaffold(body: LoadingView());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Business profile'),
        actions: [
          if (!v.isSuspended)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/business/edit'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (v.shopImagePaths.isNotEmpty)
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: v.shopImagePaths.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => SizedBox(
                  width: 200,
                  child: AppNetworkImage(
                    storage.publicUrl(
                      ImageBucket.shopImages,
                      v.shopImagePaths[i],
                    ),
                    icon: Icons.storefront,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  v.businessName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              StatusChip(v.verificationStatus),
            ],
          ),
          if ((v.description ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(v.description!),
            ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Business',
            child: Column(
              children: [
                InfoRow('Type', v.businessTypes.map((t) => t.label).join(', ')),
                InfoRow(
                  'Address',
                  [
                    v.addressLine1,
                    v.addressLine2,
                    v.city,
                    '${v.state} ${v.postalCode}',
                  ].where((e) => (e ?? '').isNotEmpty).join(', '),
                ),
                InfoRow('Phone', v.contactPhone),
                if ((v.contactEmail ?? '').isNotEmpty)
                  InfoRow('E-mail', v.contactEmail!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Operating hours',
            child: Column(
              children: [
                for (final d in weekdays)
                  InfoRow(
                    weekdayLabels[d]!,
                    (v.operatingHours[d] == null || v.operatingHours[d]!.closed)
                        ? 'Closed'
                        : '${v.operatingHours[d]!.open} – ${v.operatingHours[d]!.close}',
                  ),
                if (v.operatingHours.isEmpty)
                  const Text(
                    'Not set. Customers cannot book services until opening hours are configured.',
                    style: TextStyle(color: AppColors.warning),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Pickup & service area',
            child: Column(
              children: [
                InfoRow(
                  'Doorstep pickup',
                  v.pickupAvailable ? 'Offered' : 'Not offered',
                ),
                InfoRow(
                  'Postal codes',
                  v.servicePostalCodes.isEmpty
                      ? 'Any address'
                      : v.servicePostalCodes.join(', '),
                ),
                if (v.serviceRadiusKm != null)
                  InfoRow('Radius', '${v.serviceRadiusKm} km'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Verification',
            child: Column(
              children: [
                InfoRow(
                  'Status',
                  humanizeStatus(v.verificationStatus),
                  bold: true,
                ),
                const Text(
                  'Verification and permissions are managed by the platform administrator and cannot be changed in the app.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
