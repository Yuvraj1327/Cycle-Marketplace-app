import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/vendor_widgets.dart';
import '../business_profile/models.dart';
import 'models.dart';

final serviceCategoriesProvider = FutureProvider<List<ServiceCategory>>(
  (ref) => ref.read(serviceRepositoryProvider).categories(),
);

class ServicesListScreen extends ConsumerStatefulWidget {
  const ServicesListScreen({super.key});
  @override
  ConsumerState<ServicesListScreen> createState() => _ServicesListScreenState();
}

class _ServicesListScreenState extends ConsumerState<ServicesListScreen> {
  bool? _active;
  late PagedController<VendorService> _paged = _make();

  PagedController<VendorService> _make() => PagedController(
    (p) => ref.read(serviceRepositoryProvider).list(p, isActive: _active),
  );

  void _set(bool? a) {
    final old = _paged;
    setState(() {
      _active = a;
      _paged = _make();
    });
    old.dispose();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  Future<void> _toggle(
    VendorService s,
    int index, {
    bool? available,
    bool? active,
  }) async {
    if (active == false &&
        !await confirmDialog(
          context,
          title: 'Deactivate this service?',
          message:
              'Customers can no longer book “${s.name}”. Existing bookings are not affected.',
          confirmLabel: 'Deactivate',
          destructive: true,
        )) {
      return;
    }
    try {
      final saved = await ref.read(serviceRepositoryProvider).patch(s.id, {
        'is_available': ?available,
        'is_active': ?active,
      });
      _paged.replace(index, saved);
      ref.read(servicesTickProvider.notifier).bump();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(servicesTickProvider, (_, _) => _paged.refresh());
    return Column(
      children: [
        FilterChips<bool?>(
          options: const [(null, 'All'), (true, 'Active'), (false, 'Inactive')],
          selected: _active,
          onSelected: _set,
        ),
        Expanded(
          child: PagedListView<VendorService>(
            key: ValueKey(_paged),
            controller: _paged,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              4,
              AppSpacing.lg,
              96,
            ),
            empty: EmptyState(
              icon: Icons.build_circle_outlined,
              title: 'No services yet',
              message:
                  'Add the repairs and servicing you offer so customers can book you.',
              actionLabel: 'Add a service',
              onAction: () => context.push('/services/new'),
            ),
            itemBuilder: (context, s) {
              final i = _paged.items.indexOf(s);
              return Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/services/${s.id}'),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.name,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            StatusChip(
                              s.isActive ? 'approved' : 'inactive',
                              label: s.isActive ? 'Active' : 'Inactive',
                            ),
                          ],
                        ),
                        Text(
                          s.categoryName ?? '',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                        if ((s.description ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              s.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              money(s.price),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (s.durationMinutes != null)
                              Text(
                                '~${s.durationMinutes! >= 60 ? '${s.durationMinutes! ~/ 60}h${s.durationMinutes! % 60 == 0 ? '' : ' ${s.durationMinutes! % 60}m'}' : '${s.durationMinutes}m'}',
                                style: const TextStyle(color: AppColors.muted),
                              ),
                            const Spacer(),
                            const Text(
                              'Bookable',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                              ),
                            ),
                            Switch(
                              value: s.isAvailable,
                              onChanged: s.isActive
                                  ? (v) => _toggle(s, i, available: v)
                                  : null,
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

class ServiceFormScreen extends ConsumerStatefulWidget {
  const ServiceFormScreen({super.key, this.service});
  final VendorService? service;
  @override
  ConsumerState<ServiceFormScreen> createState() => _ServiceFormScreenState();
}

class _ServiceFormScreenState extends ConsumerState<ServiceFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _desc, _price, _duration, _perSlot;
  String? _categoryId;
  bool _available = true, _active = true, _busy = false;
  final Set<String> _days = {};
  int _slot = 60;
  String? _error;

  bool get _editing => widget.service != null;

  @override
  void initState() {
    super.initState();
    final s = widget.service;
    _name = TextEditingController(text: s?.name);
    _desc = TextEditingController(text: s?.description);
    _price = TextEditingController(
      text: s == null
          ? ''
          : s.price.toStringAsFixed(s.price == s.price.roundToDouble() ? 0 : 2),
    );
    _duration = TextEditingController(text: s?.durationMinutes?.toString());
    _perSlot = TextEditingController(text: '${s?.maxPerSlot ?? 1}');
    _categoryId = s?.categoryId;
    _available = s?.isAvailable ?? true;
    _active = s?.isActive ?? true;
    _days.addAll(s?.availableDays ?? const []);
    _slot = s?.slotMinutes ?? 60;
  }

  @override
  void dispose() {
    for (final c in [_name, _desc, _price, _duration, _perSlot]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final input = ServiceInput(
      categoryId: _categoryId!,
      name: _name.text.trim(),
      description: _desc.text.trim(),
      price: double.parse(_price.text.trim()),
      durationMinutes: int.tryParse(_duration.text.trim()),
      isAvailable: _available,
      availableDays: _days.isEmpty
          ? null
          : dayCodes.where(_days.contains).toList(),
      slotMinutes: _slot,
      maxPerSlot: int.parse(_perSlot.text.trim()),
    );
    try {
      final repo = ref.read(serviceRepositoryProvider);
      _editing
          ? await repo.replace(widget.service!.id, input, isActive: _active)
          : await repo.create(input);
      ref.read(servicesTickProvider.notifier).bump();
      if (mounted) {
        showSnack(context, _editing ? 'Service saved' : 'Service added');
        context.pop();
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirmDialog(
      context,
      title: 'Remove this service?',
      message: 'Customers will no longer see it. Existing bookings are kept.',
      confirmLabel: 'Remove',
      destructive: true,
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(serviceRepositoryProvider).delete(widget.service!.id);
      ref.read(servicesTickProvider.notifier).bump();
      if (mounted) {
        showSnack(context, 'Service removed');
        context.pop();
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(serviceCategoriesProvider);
    final noHours = ref.watch(
      authControllerProvider.select(
        (s) => s.vendor?.operatingHours.isEmpty ?? true,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit service' : 'Add service'),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _delete,
            ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (_error != null)
              StatusBanner(
                _error!,
                color: AppColors.danger,
                icon: Icons.error_outline,
              ),
            if (noHours)
              const StatusBanner(
                'Your business opening hours are not set, so customers cannot book any slot yet. Set them in Account → Business profile.',
                icon: Icons.schedule,
              ),
            cats.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => StatusBanner(
                'Categories could not be loaded: ${errorText(e)}',
                color: AppColors.danger,
              ),
              data: (list) => DropdownButtonFormField<String>(
                initialValue: list.any((c) => c.id == _categoryId)
                    ? _categoryId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Service category',
                ),
                items: [
                  for (final c in list)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
                validator: (v) => v == null ? 'Choose a category' : null,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              maxLength: 150,
              decoration: const InputDecoration(labelText: 'Service name'),
              validator: (v) =>
                  (v ?? '').trim().length < 2 ? 'At least 2 characters' : null,
            ),
            TextFormField(
              controller: _desc,
              maxLines: 3,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Price (₹)',
                      prefixIcon: Icon(Icons.currency_rupee),
                    ),
                    validator: (v) {
                      final d = double.tryParse((v ?? '').trim());
                      return d == null || d < 0 ? 'Enter a price' : null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _duration,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Est. minutes',
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return null;
                      final n = int.tryParse(t);
                      return n == null || n < 5 || n > 1440 ? '5-1440' : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Availability', style: Theme.of(context).textTheme.titleSmall),
            const Text(
              'Bookings are only offered inside your business opening hours. Narrow it down here if this service is not offered every day.',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                for (final d in dayCodes)
                  FilterChip(
                    label: Text(weekdayLabels[d]!.substring(0, 3)),
                    selected: _days.contains(d),
                    onSelected: (s) =>
                        setState(() => s ? _days.add(d) : _days.remove(d)),
                  ),
              ],
            ),
            Text(
              _days.isEmpty
                  ? 'Offered on every open day'
                  : 'Offered only on the selected days',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _slot,
                    decoration: const InputDecoration(labelText: 'Slot length'),
                    items: [
                      for (final m in {
                        30,
                        45,
                        60,
                        90,
                        120,
                        180,
                        240,
                        _slot,
                      }.toList()..sort())
                        DropdownMenuItem(value: m, child: Text('$m min')),
                    ],
                    onChanged: (v) => setState(() => _slot = v ?? 60),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _perSlot,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Bookings per slot',
                    ),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 1 || n > 50 ? '1-50' : null;
                    },
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Open for booking'),
              subtitle: const Text(
                'Turn off to pause new bookings without removing the service.',
              ),
              value: _available,
              onChanged: (v) => setState(() => _available = v),
            ),
            if (_editing)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text(
                  'Inactive services are hidden from customers.',
                ),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            const SizedBox(height: 14),
            AppButton(
              label: _editing ? 'Save changes' : 'Add service',
              busy: _busy,
              onPressed: _save,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Edit entry point: always loads the service from the backend (works after a restart/deep link; never relies on route extras).
class ServiceEditScreen extends ConsumerWidget {
  const ServiceEditScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_serviceByIdProvider(id));
    return async.when(
      data: (s) => ServiceFormScreen(service: s),
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Edit service')),
        body: const LoadingView(),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Edit service')),
        body: ErrorView(
          e,
          onRetry: () => ref.invalidate(_serviceByIdProvider(id)),
        ),
      ),
    );
  }
}

final _serviceByIdProvider = FutureProvider.family
    .autoDispose<VendorService, String>(
      (ref, id) => ref.read(serviceRepositoryProvider).get(id),
    );
