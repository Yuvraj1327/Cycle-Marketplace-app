import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/auth_service.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/utils/images.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/vendor_widgets.dart';
import 'models.dart';
import 'providers.dart';
import 'repository.dart';

String productStatusLabel(String s) => switch (s) {
  'approved' => 'Live',
  'pending' => 'Pending approval',
  'rejected' => 'Rejected',
  'inactive' => 'Inactive',
  _ => humanize(s),
};

class ProductListCard extends StatelessWidget {
  const ProductListCard(this.p, {super.key, this.onTap, this.trailing});
  final VendorProduct p;
  final VoidCallback? onTap;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap ?? () => context.push('/products/${p.id}'),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 78,
              height: 78,
              child: AppNetworkImage(p.imageUrl, radius: 10),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    [
                      p.categoryName,
                      p.brand,
                      p.model,
                    ].where((e) => (e ?? '').isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        money(p.price),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        p.condition == 'used' ? 'Used' : 'New',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                      const Spacer(),
                      StatusChip(
                        p.displayStatus,
                        label: productStatusLabel(p.displayStatus),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        p.stock == 0
                            ? Icons.remove_shopping_cart_outlined
                            : Icons.inventory_2_outlined,
                        size: 14,
                        color: p.stock == 0
                            ? AppColors.danger
                            : AppColors.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        p.stock == 0 ? 'Out of stock' : 'Stock: ${p.stock}',
                        style: TextStyle(
                          fontSize: 12,
                          color: p.stock == 0
                              ? AppColors.danger
                              : AppColors.muted,
                          fontWeight: p.stock == 0
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                      if (!p.isAvailable)
                        const Text(
                          '  ·  Hidden by you',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      const Spacer(),
                      ?trailing,
                    ],
                  ),
                  if (p.isRejected && (p.reviewNotes ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Reason: ${p.reviewNotes}',
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 12,
                        ),
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

enum _Filter {
  all,
  newCycle,
  usedCycle,
  sparePart,
  accessory,
  active,
  inactive,
  pending,
  rejected,
}

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});
  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  _Filter _filter = _Filter.all;
  String _q = '';
  late PagedController<VendorProduct> _paged = _make();

  ProductFilter get _f => switch (_filter) {
    _Filter.all => ProductFilter(q: _q),
    _Filter.newCycle => ProductFilter(q: _q, productType: 'new_cycle'),
    _Filter.usedCycle => ProductFilter(q: _q, productType: 'used_cycle'),
    _Filter.sparePart => ProductFilter(q: _q, productType: 'spare_part'),
    _Filter.accessory => ProductFilter(q: _q, productType: 'accessory'),
    _Filter.active => ProductFilter(
      q: _q,
      approvalStatus: 'approved',
      isActive: true,
    ),
    _Filter.inactive => ProductFilter(q: _q, isActive: false),
    _Filter.pending => ProductFilter(q: _q, approvalStatus: 'pending'),
    _Filter.rejected => ProductFilter(q: _q, approvalStatus: 'rejected'),
  };

  PagedController<VendorProduct> _make() =>
      PagedController((p) => ref.read(productRepositoryProvider).list(_f, p));

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
    ref.listen(productsTickProvider, (_, _) => _paged.refresh());
    const labels = {
      _Filter.all: 'All',
      _Filter.newCycle: 'New cycles',
      _Filter.usedCycle: 'Used cycles',
      _Filter.sparePart: 'Spare parts',
      _Filter.accessory: 'Accessories',
      _Filter.active: 'Active',
      _Filter.inactive: 'Inactive',
      _Filter.pending: 'Pending approval',
      _Filter.rejected: 'Rejected',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          IconButton(
            tooltip: 'Inventory',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => context.push('/inventory'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/products/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add product'),
      ),
      body: Column(
        children: [
          SearchField(
            hint: 'Search your products',
            onChanged: (v) {
              _q = v.trim();
              _reset();
            },
          ),
          FilterChips<_Filter>(
            options: [for (final e in labels.entries) (e.key, e.value)],
            selected: _filter,
            onSelected: (f) {
              _filter = f;
              _reset();
            },
          ),
          Expanded(
            child: PagedListView<VendorProduct>(
              key: ValueKey(_paged),
              controller: _paged,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                4,
                AppSpacing.lg,
                96,
              ),
              empty: EmptyState(
                icon: Icons.pedal_bike,
                title: _filter == _Filter.all && _q.isEmpty
                    ? 'No products yet'
                    : 'No products match',
                message: 'Add your first listing to start selling.',
                actionLabel: _filter == _Filter.all ? 'Add product' : null,
                onAction: () => context.push('/products/new'),
              ),
              itemBuilder: (context, p) => ProductListCard(p),
            ),
          ),
        ],
      ),
    );
  }
}

/// Create / edit a listing. Approval and moderation fields do not exist here: only an administrator changes them.
class ProductFormScreen extends ConsumerStatefulWidget {
  const ProductFormScreen({super.key, this.productId});
  final String? productId;
  @override
  ConsumerState<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends ConsumerState<ProductFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _brand = TextEditingController(),
      _model = TextEditingController(),
      _desc = TextEditingController(),
      _price = TextEditingController(),
      _stock = TextEditingController(text: '1');
  final List<(TextEditingController, TextEditingController)> _specs = [];
  String? _categoryId;
  String _condition = 'new';
  bool _available = true, _active = true, _busy = false, _loaded = false;
  String? _progress, _error, _approval, _reviewNotes;
  List<ProductImage> _images = [];
  final List<PickedImage> _queued =
      []; // create mode: uploaded after the product exists
  late String? _id = widget.productId;

  @override
  void initState() {
    super.initState();
    if (_id == null) {
      _loaded = true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final p = await ref.read(productRepositoryProvider).get(_id!);
      _fill(p);
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  void _fill(VendorProduct p) {
    _name.text = p.name;
    _brand.text = p.brand ?? '';
    _model.text = p.model ?? '';
    _desc.text = p.description ?? '';
    _price.text = p.price.toStringAsFixed(
      p.price == p.price.roundToDouble() ? 0 : 2,
    );
    _stock.text = '${p.stock}';
    _categoryId = p.categoryId;
    _condition = p.condition;
    _available = p.isAvailable;
    _active = p.isActive;
    _images = p.images;
    _approval = p.approvalStatus;
    _reviewNotes = p.reviewNotes;
    for (final s in _specs) {
      s.$1.dispose();
      s.$2.dispose();
    }
    _specs
      ..clear()
      ..addAll(
        p.specifications.entries.map(
          (e) => (
            TextEditingController(text: e.key),
            TextEditingController(text: '${e.value}'),
          ),
        ),
      );
  }

  @override
  void dispose() {
    for (final c in [_name, _brand, _model, _desc, _price, _stock]) {
      c.dispose();
    }
    for (final s in _specs) {
      s.$1.dispose();
      s.$2.dispose();
    }
    super.dispose();
  }

  ProductInput _input() => ProductInput(
    categoryId: _categoryId!,
    name: _name.text.trim(),
    description: _desc.text.trim(),
    brand: _brand.text.trim(),
    model: _model.text.trim(),
    specifications: {
      for (final s in _specs)
        if (s.$1.text.trim().isNotEmpty && s.$2.text.trim().isNotEmpty)
          s.$1.text.trim(): s.$2.text.trim(),
    },
    condition: _condition,
    price: double.parse(_price.text.trim()),
    stock: int.parse(_stock.text.trim()),
    isAvailable: _available,
  );

  Future<String?> _upload(PickedImage img, String productId) async {
    final uid = ref.read(authServiceProvider).userId;
    if (uid == null) return null;
    final path = await ref
        .read(imageStorageProvider)
        .upload(
          bucket: ImageBucket.productImages,
          userId: uid,
          folder: productId,
          bytes: img.bytes,
          extension: img.extension,
          contentType: img.contentType,
        );
    return path;
  }

  Future<int> _uploadAll(List<PickedImage> imgs, String productId) async {
    var failed = 0;
    final repo = ref.read(productRepositoryProvider);
    for (var i = 0; i < imgs.length; i++) {
      if (mounted) {
        setState(
          () => _progress = 'Uploading image ${i + 1} of ${imgs.length}…',
        );
      }
      try {
        final path = await _upload(imgs[i], productId);
        if (path == null) throw StateError('no user');
        final saved = await repo.registerImage(
          productId,
          path,
          primary: _images.isEmpty && i == 0,
        );
        _images = [..._images, saved];
      } catch (_) {
        failed++;
      }
    }
    if (mounted) setState(() => _progress = null);
    return failed;
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_categoryId == null) {
      setState(() => _error = 'Choose a category.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(productRepositoryProvider);
    try {
      if (_id == null) {
        final created = await repo.create(_input());
        _id = created.id;
        ref.read(productsTickProvider.notifier).bump();
        final failed = await _uploadAll(_queued, created.id);
        _queued.clear();
        if (!mounted) return;
        showSnack(
          context,
          failed == 0
              ? 'Product created${created.isPendingApproval ? ' and sent for approval' : ''}'
              : 'Product created, but $failed image${failed == 1 ? '' : 's'} failed to upload. Add them from the product page.',
          error: failed > 0,
        );
        context.pushReplacement('/products/${created.id}');
      } else {
        final before = _approval;
        final saved = await repo.replace(_id!, _input(), isActive: _active);
        _fill(saved);
        ref.read(productsTickProvider.notifier).bump();
        ref.invalidate(productDetailProvider(_id!));
        if (mounted) {
          setState(() {});
          showSnack(
            context,
            saved.approvalStatus != before && saved.isPendingApproval
                ? 'Saved. This change sent the listing back for approval.'
                : 'Product saved',
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addImages() async {
    final room = 8 - _images.length - _queued.length;
    final picked = await pickImages(context, max: room);
    if (picked.isEmpty || !mounted) return;
    if (_id == null) {
      setState(() => _queued.addAll(picked));
      return;
    }
    setState(() => _busy = true);
    final failed = await _uploadAll(picked, _id!);
    ref.read(productsTickProvider.notifier).bump();
    if (mounted) {
      setState(() => _busy = false);
      if (failed > 0) {
        showSnack(
          context,
          '$failed image${failed == 1 ? '' : 's'} could not be uploaded.',
          error: true,
        );
      }
    }
  }

  Future<void> _imageAction(
    Future<void> Function(ProductRepository r) action,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(ref.read(productRepositoryProvider));
      _images = await ref.read(productRepositoryProvider).images(_id!);
      ref.read(productsTickProvider.notifier).bump();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deactivateToggle() async {
    final activate = !_active;
    if (!activate &&
        !await confirmDialog(
          context,
          title: 'Deactivate this product?',
          message:
              'It disappears from the marketplace until you activate it again. Existing orders are not affected.',
          confirmLabel: 'Deactivate',
          destructive: true,
        )) {
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final p = await ref.read(productRepositoryProvider).patch(_id!, {
        'is_active': activate,
      });
      _fill(p);
      ref.read(productsTickProvider.notifier).bump();
      if (mounted) {
        showSnack(
          context,
          activate ? 'Product activated' : 'Product deactivated',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirmDialog(
      context,
      title: 'Remove this product?',
      message:
          'This removes the listing. If it already appears in orders, the backend may keep it hidden instead of deleting it.',
      confirmLabel: 'Remove',
      destructive: true,
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(productRepositoryProvider).delete(_id!);
      ref.read(productsTickProvider.notifier).bump();
      if (mounted) {
        showSnack(context, 'Product removed');
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
    final cats = ref.watch(categoriesProvider);
    final editing = _id != null && widget.productId != null || _id != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.productId == null && _id == null
              ? 'Add product'
              : 'Edit product',
        ),
        actions: [
          if (_id != null)
            PopupMenuButton<String>(
              onSelected: (v) =>
                  v == 'toggle' ? _deactivateToggle() : _delete(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(
                    _active ? 'Deactivate listing' : 'Activate listing',
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Remove product'),
                ),
              ],
            ),
        ],
      ),
      body: !_loaded
          ? (_error != null
                ? ErrorView(_error!, onRetry: _load)
                : const LoadingView())
          : Form(
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
                  if (editing && _approval != null)
                    _ApprovalBanner(
                      status: _approval!,
                      notes: _reviewNotes,
                      active: _active,
                    ),
                  cats.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => StatusBanner(
                      'Categories could not be loaded: ${errorText(e)}',
                      color: AppColors.danger,
                    ),
                    data: (list) {
                      final leafs = list
                          .where((c) => productKinds.containsKey(c.kind))
                          .toList();
                      return DropdownButtonFormField<String>(
                        initialValue: leafs.any((c) => c.id == _categoryId)
                            ? _categoryId
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                        ),
                        items: [
                          for (final c in leafs)
                            DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                '${c.name}  ·  ${productKinds[c.kind]}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          _categoryId = v;
                          final kind = leafs.firstWhere((c) => c.id == v).kind;
                          if (kind == 'new_cycle') _condition = 'new';
                          if (kind == 'used_cycle') _condition = 'used';
                        }),
                        validator: (v) =>
                            v == null ? 'Choose a category' : null,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Product name',
                    ),
                    validator: (v) => (v ?? '').trim().length < 2
                        ? 'At least 2 characters'
                        : null,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _brand,
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Brand (optional)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _model,
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Model (optional)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  cats.maybeWhen(
                    data: (list) {
                      final kind = list
                          .where((c) => c.id == _categoryId)
                          .map((c) => c.kind)
                          .firstOrNull;
                      final locked =
                          kind == 'new_cycle' || kind == 'used_cycle';
                      return SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'new',
                            label: const Text('New'),
                            enabled: kind != 'used_cycle',
                          ),
                          ButtonSegment(
                            value: 'used',
                            label: const Text('Used'),
                            enabled: kind != 'new_cycle',
                          ),
                        ],
                        selected: {_condition},
                        onSelectionChanged: locked
                            ? null
                            : (s) => setState(() => _condition = s.first),
                      );
                    },
                    orElse: () => const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 14),
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
                            return d == null || d <= 0
                                ? 'Enter a price above 0'
                                : (d > 10000000 ? 'Too large' : null);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _stock,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Stock',
                            prefixIcon: Icon(Icons.inventory_2_outlined),
                          ),
                          validator: (v) {
                            final n = int.tryParse((v ?? '').trim());
                            return n == null || n < 0
                                ? 'Whole number, 0 or more'
                                : (n > 1000000 ? 'Too large' : null);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _desc,
                    maxLines: 4,
                    maxLength: 5000,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      alignLabelWithHint: true,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Available for sale'),
                    subtitle: const Text(
                      'Turn off to hide the listing temporarily.',
                    ),
                    value: _available,
                    onChanged: (v) => setState(() => _available = v),
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Specifications (optional)',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _specs.length >= 40
                            ? null
                            : () => setState(
                                () => _specs.add((
                                  TextEditingController(),
                                  TextEditingController(),
                                )),
                              ),
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  for (var i = 0; i < _specs.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _specs[i].$1,
                              maxLength: 60,
                              decoration: const InputDecoration(
                                labelText: 'Name',
                                hintText: 'Frame size',
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _specs[i].$2,
                              maxLength: 300,
                              decoration: const InputDecoration(
                                labelText: 'Value',
                                hintText: '52 cm',
                                counterText: '',
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => setState(() {
                              final s = _specs.removeAt(i);
                              s.$1.dispose();
                              s.$2.dispose();
                            }),
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: AppColors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  _ImagesSection(
                    images: _images,
                    queued: _queued,
                    busy: _busy,
                    progress: _progress,
                    onAdd: _addImages,
                    onRemoveQueued: (i) => setState(() => _queued.removeAt(i)),
                    onRemove: (img) async {
                      if (await confirmDialog(
                        context,
                        title: 'Remove this image?',
                        message: 'The image is removed from the listing.',
                        confirmLabel: 'Remove',
                        destructive: true,
                      )) {
                        await _imageAction((r) => r.removeImage(_id!, img.id));
                      }
                    },
                    onPrimary: (img) => _imageAction(
                      (r) => r.makePrimary(_id!, img.id).then((_) {}),
                    ),
                    onMove: (from, to) {
                      final ids = _images.map((e) => e.id).toList();
                      ids.insert(to, ids.removeAt(from));
                      return _imageAction(
                        (r) => r.reorder(_id!, ids).then((_) {}),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  AppButton(
                    label: _id == null ? 'Create product' : 'Save changes',
                    busy: _busy,
                    onPressed: _save,
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
    );
  }
}

class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({
    required this.status,
    this.notes,
    required this.active,
  });
  final String status;
  final String? notes;
  final bool active;
  @override
  Widget build(BuildContext context) => switch (status) {
    'rejected' => StatusBanner(
      'Rejected by the marketplace${(notes ?? '').isNotEmpty ? ': $notes' : '.'} Fix the issue and save to send it back for review.',
      color: AppColors.danger,
      icon: Icons.cancel_outlined,
    ),
    'pending' => const StatusBanner(
      'Waiting for approval. It is not visible to customers yet.',
      icon: Icons.hourglass_top,
    ),
    _ =>
      active
          ? const SizedBox.shrink()
          : const StatusBanner(
              'This listing is inactive and hidden from customers.',
              color: AppColors.muted,
              icon: Icons.visibility_off_outlined,
            ),
  };
}

class _ImagesSection extends StatelessWidget {
  const _ImagesSection({
    required this.images,
    required this.queued,
    required this.busy,
    required this.progress,
    required this.onAdd,
    required this.onRemove,
    required this.onRemoveQueued,
    required this.onPrimary,
    required this.onMove,
  });
  final List<ProductImage> images;
  final List<PickedImage> queued;
  final bool busy;
  final String? progress;
  final VoidCallback onAdd;
  final void Function(ProductImage) onRemove, onPrimary;
  final void Function(int) onRemoveQueued;
  final Future<void> Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    final total = images.length + queued.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Images ($total/8)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: busy || total >= 8 ? null : onAdd,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Add'),
            ),
          ],
        ),
        const Text(
          'JPG, PNG or WebP, up to 5 MB each. The first image is the main photo.',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(progress!),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (total == 0)
          const Text(
            'No images yet. Listings with photos sell better.',
            style: TextStyle(color: AppColors.muted),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < images.length; i++)
              SizedBox(
                width: 104,
                child: Column(
                  children: [
                    Stack(
                      children: [
                        SizedBox(
                          width: 104,
                          height: 104,
                          child: AppNetworkImage(images[i].url, radius: 10),
                        ),
                        if (images[i].isPrimary)
                          Positioned(
                            left: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'Main',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        Positioned(
                          right: 2,
                          top: 2,
                          child: InkWell(
                            onTap: busy ? null : () => onRemove(images[i]),
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          tooltip: 'Move earlier',
                          onPressed: busy || i == 0
                              ? null
                              : () => onMove(i, i - 1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          tooltip: 'Make main photo',
                          onPressed: busy || images[i].isPrimary
                              ? null
                              : () => onPrimary(images[i]),
                          icon: Icon(
                            images[i].isPrimary
                                ? Icons.star
                                : Icons.star_border,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          tooltip: 'Move later',
                          onPressed: busy || i == images.length - 1
                              ? null
                              : () => onMove(i, i + 1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            for (var i = 0; i < queued.length; i++)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      Uint8List.fromList(queued[i].bytes),
                      width: 104,
                      height: 104,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: InkWell(
                      onTap: () => onRemoveQueued(i),
                      child: const CircleAvatar(
                        radius: 11,
                        backgroundColor: Colors.black54,
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.warning,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Uploads on save',
                        style: TextStyle(color: Colors.white, fontSize: 9),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Stock overview and quick stock changes. The BACKEND owns stock (order checkout/cancel adjust it); this screen only submits the vendor's
/// manual correction, applied as a change relative to the freshest stock so concurrent orders are not overwritten.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});
  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _q = '';
  bool? _inStock;
  late PagedController<VendorProduct> _paged = _make();

  PagedController<VendorProduct> _make() => PagedController(
    (p) => ref
        .read(productRepositoryProvider)
        .list(ProductFilter(q: _q, inStock: _inStock), p, limit: 30),
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

  Future<void> _edit(VendorProduct p, int index) async {
    final ctrl = TextEditingController(text: '${p.stock}');
    final target = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Current stock: ${p.stock}'),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'New stock quantity',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(90, 44)),
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 0 && n <= 1000000) Navigator.pop(c, n);
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (target == null || target == p.stock) return;
    try {
      final repo = ref.read(productRepositoryProvider);
      final fresh = await repo.get(
        p.id,
      ); // an order may have changed the stock since this list loaded
      final next = (fresh.stock + (target - p.stock)).clamp(0, 1000000);
      final saved = await repo.patch(p.id, {'stock_quantity': next});
      _paged.replace(index, saved);
      ref.read(productsTickProvider.notifier).bump();
      if (mounted) {
        showSnack(
          context,
          fresh.stock != p.stock
              ? 'Stock had changed to ${fresh.stock} (new order?). Your change was applied on top: now ${saved.stock}.'
              : 'Stock updated to ${saved.stock}',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Inventory')),
    body: Column(
      children: [
        SearchField(
          hint: 'Search by name, brand or model',
          onChanged: (v) {
            _q = v.trim();
            _reset();
          },
        ),
        FilterChips<bool?>(
          options: const [
            (null, 'All stock'),
            (true, 'In stock'),
            (false, 'Out of stock'),
          ],
          selected: _inStock,
          onSelected: (v) {
            _inStock = v;
            _reset();
          },
        ),
        Expanded(
          child: PagedListView<VendorProduct>(
            key: ValueKey(_paged),
            controller: _paged,
            empty: const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Nothing here',
              message: 'No products match this view.',
            ),
            itemBuilder: (context, p) => ProductListCard(
              p,
              onTap: () => _edit(p, _paged.items.indexOf(p)),
              trailing: const Icon(
                Icons.edit_outlined,
                size: 16,
                color: AppColors.primary,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
