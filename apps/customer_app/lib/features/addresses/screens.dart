import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/widgets/common.dart';
import 'models.dart';
import 'providers.dart';

/// Saved addresses. With `selectMode` it returns the tapped address to the caller (checkout / booking) instead of just listing.
class AddressesScreen extends ConsumerWidget {
  const AddressesScreen({super.key, this.selectMode = false});
  final bool selectMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(addressesProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(selectMode ? 'Choose an address' : 'My addresses'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/address-form'),
        icon: const Icon(Icons.add),
        label: const Text('Add address'),
      ),
      body: AsyncBody<List<Address>>(
        value: list,
        onRetry: () => ref.read(addressesProvider.notifier).reload(),
        builder: (items) => items.isEmpty
            ? EmptyState(
                icon: Icons.location_off_outlined,
                title: 'No saved addresses',
                message: 'Add an address for delivery and for cycle pickup.',
                actionLabel: 'Add address',
                onAction: () => context.push('/address-form'),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  96,
                ),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => AddressCard(
                  address: items[i],
                  onTap: selectMode ? () => context.pop(items[i]) : null,
                ),
              ),
      ),
    );
  }
}

class AddressCard extends ConsumerWidget {
  const AddressCard({
    super.key,
    required this.address,
    this.onTap,
    this.selected = false,
    this.manage = true,
  });
  final Address address;
  final VoidCallback? onTap;
  final bool selected, manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = address;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? context.palette.primary : context.palette.line,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    a.label?.toLowerCase() == 'work'
                        ? Icons.work_outline
                        : Icons.home_outlined,
                    color: context.palette.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      a.label?.isNotEmpty == true ? a.label! : a.recipientName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (a.isDefault)
                    const StatusChip('confirmed', label: 'Default'),
                  if (manage)
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'edit') {
                          context.push('/address-form?id=${a.id}');
                        } else if (v == 'default') {
                          try {
                            await ref
                                .read(addressesProvider.notifier)
                                .setDefault(a.id);
                          } catch (e) {
                            if (context.mounted) {
                              showSnack(context, errorText(e), error: true);
                            }
                          }
                        } else if (v == 'delete' &&
                            await confirmDialog(
                              context,
                              title: 'Delete address?',
                              message:
                                  'This address will be removed. Past orders keep their own copy.',
                              confirmLabel: 'Delete',
                              destructive: true,
                            )) {
                          try {
                            await ref
                                .read(addressesProvider.notifier)
                                .delete(a.id);
                          } catch (e) {
                            if (context.mounted) {
                              showSnack(context, errorText(e), error: true);
                            }
                          }
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        if (!a.isDefault)
                          const PopupMenuItem(
                            value: 'default',
                            child: Text('Make default'),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${a.recipientName} · ${a.phone}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(a.oneLine, style: TextStyle(color: context.palette.muted)),
              if ((a.landmark ?? '').isNotEmpty)
                Text(
                  'Landmark: ${a.landmark}',
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              const SizedBox(height: 6),
              Text(
                switch (a.addressType) {
                  'delivery' => 'Delivery only',
                  'pickup' => 'Pickup only',
                  _ => 'Delivery & pickup',
                },
                style: TextStyle(
                  color: context.palette.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AddressFormScreen extends ConsumerStatefulWidget {
  const AddressFormScreen({super.key, this.addressId});
  final String? addressId;
  @override
  ConsumerState<AddressFormScreen> createState() => _AddressFormScreenState();
}

class _AddressFormScreenState extends ConsumerState<AddressFormScreen> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController(),
      _name = TextEditingController(),
      _phone = TextEditingController(),
      _line1 = TextEditingController(),
      _line2 = TextEditingController(),
      _landmark = TextEditingController(),
      _city = TextEditingController(),
      _state = TextEditingController(),
      _postal = TextEditingController();
  String _type = 'both';
  bool _default = false, _busy = false, _loaded = false;

  @override
  void dispose() {
    for (final c in [
      _label,
      _name,
      _phone,
      _line1,
      _line2,
      _landmark,
      _city,
      _state,
      _postal,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _prefill(Address a) {
    _loaded = true;
    _label.text = a.label ?? '';
    _name.text = a.recipientName;
    _phone.text = a.phone;
    _line1.text = a.line1;
    _line2.text = a.line2 ?? '';
    _landmark.text = a.landmark ?? '';
    _city.text = a.city;
    _state.text = a.state;
    _postal.text = a.postalCode;
    _type = a.addressType;
    _default = a.isDefault;
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final input = AddressInput(
      label: _label.text.trim(),
      addressType: _type,
      recipientName: _name.text.trim(),
      phone: _phone.text.trim(),
      line1: _line1.text.trim(),
      line2: _line2.text.trim(),
      landmark: _landmark.text.trim(),
      city: _city.text.trim(),
      state: _state.text.trim(),
      postalCode: _postal.text.trim(),
      makeDefault: _default,
    );
    try {
      final n = ref.read(addressesProvider.notifier);
      widget.addressId == null
          ? await n.create(input)
          : await n.edit(widget.addressId!, input);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _req(String? v, String what) =>
      (v == null || v.trim().isEmpty) ? '$what is required' : null;

  @override
  Widget build(BuildContext context) {
    if (widget.addressId != null && !_loaded) {
      final existing = ref
          .watch(addressesProvider)
          .value
          ?.where((a) => a.id == widget.addressId);
      if (existing != null && existing.isNotEmpty) _prefill(existing.first);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.addressId == null ? 'Add address' : 'Edit address'),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label (e.g. Home, Work)',
                prefixIcon: Icon(Icons.label_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Recipient name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (v) => _req(v, 'Name'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              validator: (v) =>
                  RegExp(r'^\+?[0-9]{7,15}$').hasMatch((v ?? '').trim())
                  ? null
                  : 'Enter 7-15 digits',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _line1,
              decoration: const InputDecoration(
                labelText: 'House / street',
                prefixIcon: Icon(Icons.home_outlined),
              ),
              validator: (v) => _req(v, 'Address'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _line2,
              decoration: const InputDecoration(
                labelText: 'Area / locality (optional)',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _landmark,
              decoration: const InputDecoration(
                labelText: 'Landmark (optional)',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _city,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'City'),
                    validator: (v) => _req(v, 'City'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _state,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'State'),
                    validator: (v) => _req(v, 'State'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _postal,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN code',
                counterText: '',
              ),
              validator: (v) =>
                  RegExp(r'^[1-9][0-9]{5}$').hasMatch((v ?? '').trim())
                  ? null
                  : 'Enter a valid 6-digit PIN code',
            ),
            const SizedBox(height: 12),
            const Text(
              'Use this address for',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'both', label: Text('Both')),
                ButtonSegment(value: 'delivery', label: Text('Delivery')),
                ButtonSegment(value: 'pickup', label: Text('Pickup')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Make this my default address'),
              value: _default,
              onChanged: (v) => setState(() => _default = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save address'),
            ),
          ],
        ),
      ),
    );
  }
}
