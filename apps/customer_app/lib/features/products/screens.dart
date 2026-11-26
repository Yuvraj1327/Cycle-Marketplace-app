import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../cart/providers.dart';
import '../wishlist/providers.dart';
import 'models.dart';
import 'providers.dart';

/// Product browsing + search. Search text, filters and sorting are sent to the BACKEND; this screen never filters results itself.
class ProductListScreen extends ConsumerStatefulWidget {
  const ProductListScreen({
    super.key,
    required this.title,
    this.categoryId,
    this.productType,
    this.condition,
    this.autofocusSearch = false,
  });
  final String title;
  final String? categoryId, productType, condition;
  final bool autofocusSearch;
  @override
  ConsumerState<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends ConsumerState<ProductListScreen> {
  late ProductQuery _query;
  late PagedController<ProductSummary> _paged;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _query = ProductQuery(
      categoryId: widget.categoryId,
      productType: widget.productType,
      condition: widget.condition,
    );
    _paged = _newController();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        _paged.loadMore();
      }
    });
    _paged.addListener(_rebuild);
    _paged.loadMore();
  }

  PagedController<ProductSummary> _newController() => PagedController(
    (page) => ref.read(catalogRepositoryProvider).products(_query, page),
  );

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _apply(ProductQuery q) {
    _paged.removeListener(_rebuild);
    _paged.dispose();
    setState(() {
      _query = q;
      _paged = _newController()..addListener(_rebuild);
    });
    _paged.loadMore();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _paged.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      final t = text.trim();
      if ((t.isEmpty ? null : t) != _query.q) {
        _apply(
          ProductQuery(
            q: t.isEmpty ? null : t,
            categoryId: _query.categoryId,
            productType: _query.productType,
            minPrice: _query.minPrice,
            maxPrice: _query.maxPrice,
            brand: _query.brand,
            condition: _query.condition,
            inStock: _query.inStock,
            sort: _query.sort,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final subs = widget.categoryId == null
        ? null
        : ref.watch(subCategoriesProvider(widget.categoryId!));
    return Scaffold(
      appBar: AppBar(
        title: widget.autofocusSearch
            ? TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onSearchChanged,
                onSubmitted: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Search cycles, parts, accessories',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
              )
            : Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Sort',
            icon: const Icon(Icons.swap_vert),
            onPressed: _pickSort,
          ),
          IconButton(
            tooltip: 'Filters',
            icon: Badge(
              isLabelVisible: _query.activeFilterCount > 0,
              label: Text('${_query.activeFilterCount}'),
              child: const Icon(Icons.tune),
            ),
            onPressed: _openFilters,
          ),
          const CartButton(),
        ],
      ),
      body: Column(
        children: [
          if (!widget.autofocusSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search in ${widget.title}',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            _onSearchChanged('');
                          },
                        ),
                ),
              ),
            ),
          if (subs != null)
            subs.maybeWhen(
              data: (list) => list.isEmpty
                  ? const SizedBox.shrink()
                  : SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                          vertical: 8,
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: const Text('All'),
                              selected: _query.categoryId == widget.categoryId,
                              onSelected: (_) =>
                                  _apply(_copy(categoryId: widget.categoryId)),
                            ),
                          ),
                          for (final c in list)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(c.name),
                                selected: _query.categoryId == c.id,
                                onSelected: (_) =>
                                    _apply(_copy(categoryId: c.id)),
                              ),
                            ),
                        ],
                      ),
                    ),
              orElse: () => const SizedBox.shrink(),
            ),
          if (_query.activeFilterCount > 0 ||
              _query.sort != ProductSort.relevance)
            _ActiveFilters(
              query: _query,
              onClear: () => _apply(
                ProductQuery(
                  q: _query.q,
                  categoryId: _query.categoryId,
                  productType: _query.productType,
                ),
              ),
            ),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  ProductQuery _copy({String? categoryId}) => ProductQuery(
    q: _query.q,
    categoryId: categoryId,
    productType: _query.productType,
    minPrice: _query.minPrice,
    maxPrice: _query.maxPrice,
    brand: _query.brand,
    condition: _query.condition,
    inStock: _query.inStock,
    sort: _query.sort,
  );

  Widget _results() {
    final c = _paged;
    if (c.isInitialLoading) return const LoadingView();
    if (c.error != null && c.items.isEmpty) {
      return ErrorView(c.error!, onRetry: c.refresh);
    }
    if (c.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No products found',
        message: _query.q != null || _query.activeFilterCount > 0
            ? 'Try a different search or clear the filters.'
            : 'Nothing is listed here yet.',
        actionLabel: _query.activeFilterCount > 0 ? 'Clear filters' : null,
        onAction: _query.activeFilterCount > 0
            ? () => _apply(
                ProductQuery(
                  q: _query.q,
                  categoryId: _query.categoryId,
                  productType: _query.productType,
                ),
              )
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: c.refresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: .66,
              ),
              itemCount: c.items.length,
              itemBuilder: (_, i) => ProductCard(c.items[i]),
            ),
          ),
          SliverToBoxAdapter(
            child: c.loading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : c.error != null
                ? TextButton.icon(
                    onPressed: c.loadMore,
                    icon: const Icon(Icons.refresh),
                    label: Text('${errorText(c.error!)}  Tap to retry'),
                  )
                : Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Center(
                      child: Text(
                        '${c.total} product${c.total == 1 ? '' : 's'}',
                        style: TextStyle(color: context.palette.muted),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSort() async {
    final chosen = await showModalBottomSheet<ProductSort>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in ProductSort.values)
              ListTile(
                title: Text(s.label),
                trailing: s == _query.sort
                    ? Icon(Icons.check, color: context.palette.primary)
                    : null,
                onTap: () => Navigator.pop(c, s),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != _query.sort) {
      _apply(_query.copyWith(sort: chosen));
    }
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<ProductQuery>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _FilterSheet(initial: _query),
    );
    if (result != null) _apply(result);
  }
}

class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.query, required this.onClear});
  final ProductQuery query;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (query.minPrice != null || query.maxPrice != null)
        '${query.minPrice != null ? money(query.minPrice!) : '₹0'} – ${query.maxPrice != null ? money(query.maxPrice!) : 'any'}',
      if ((query.brand ?? '').isNotEmpty) query.brand!,
      if (query.condition != null) humanize(query.condition!),
      if (query.inStock == true) 'In stock',
      if (query.sort != ProductSort.relevance) query.sort.label,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.palette.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial});
  final ProductQuery initial;
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final TextEditingController _min = TextEditingController(
    text: widget.initial.minPrice?.toStringAsFixed(0) ?? '',
  );
  late final TextEditingController _max = TextEditingController(
    text: widget.initial.maxPrice?.toStringAsFixed(0) ?? '',
  );
  late final TextEditingController _brand = TextEditingController(
    text: widget.initial.brand ?? '',
  );
  late String? _condition = widget.initial.condition;
  late bool _inStock = widget.initial.inStock == true;
  String? _error;

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    _brand.dispose();
    super.dispose();
  }

  void _apply() {
    final min = double.tryParse(_min.text.trim()),
        max = double.tryParse(_max.text.trim());
    if (min != null && max != null && min > max) {
      setState(() => _error = 'Minimum price cannot be above the maximum.');
      return;
    }
    final q = widget.initial;
    Navigator.pop(
      context,
      ProductQuery(
        q: q.q,
        categoryId: q.categoryId,
        productType: q.productType,
        minPrice: min,
        maxPrice: max,
        brand: _brand.text.trim().isEmpty ? null : _brand.text.trim(),
        condition: _condition,
        inStock: _inStock ? true : null,
        sort: q.sort,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      4,
      20,
      MediaQuery.of(context).viewInsets.bottom + 20,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Filters', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          const Text(
            'Price range (₹)',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _min,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Min'),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('–'),
              ),
              Expanded(
                child: TextField(
                  controller: _max,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Max'),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _brand,
            decoration: const InputDecoration(
              labelText: 'Brand',
              prefixIcon: Icon(Icons.sell_outlined),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Condition',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Any'),
                selected: _condition == null,
                onSelected: (_) => setState(() => _condition = null),
              ),
              ChoiceChip(
                label: const Text('New'),
                selected: _condition == 'new',
                onSelected: (_) => setState(() => _condition = 'new'),
              ),
              ChoiceChip(
                label: const Text('Used'),
                selected: _condition == 'used',
                onSelected: (_) => setState(() => _condition = 'used'),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('In stock only'),
            value: _inStock,
            onChanged: (v) => setState(() => _inStock = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(
                    context,
                    ProductQuery(
                      q: widget.initial.q,
                      categoryId: widget.initial.categoryId,
                      productType: widget.initial.productType,
                      sort: widget.initial.sort,
                    ),
                  ),
                  child: const Text('Reset'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

// ============================================================================================================================ detail
class ProductDetailScreen extends ConsumerStatefulWidget {
  const ProductDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  int _qty = 1;
  bool _busy = false;
  final _page = PageController();
  int _image = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _addToCart(ProductSummary p, {bool buyNow = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(cartProvider.notifier).add(p.id, quantity: _qty);
      if (!mounted) return;
      if (buyNow) {
        context.push('/cart');
      } else {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added $_qty × ${p.name} to your cart'),
            action: SnackBarAction(
              label: 'VIEW CART',
              textColor: Colors.white,
              onPressed: () => context.push('/cart'),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(productDetailProvider(widget.id));
    return Scaffold(
      appBar: AppBar(
        actions: [
          detail.maybeWhen(
            data: (d) => IconButton(
              tooltip: 'Wishlist',
              icon: Icon(
                ref.watch(wishlistedProvider(d.summary.id))
                    ? Icons.favorite
                    : Icons.favorite_border,
                color: ref.watch(wishlistedProvider(d.summary.id))
                    ? AppColors.danger
                    : null,
              ),
              onPressed: () async {
                try {
                  final added = await ref
                      .read(wishlistProvider.notifier)
                      .toggle(d.summary.id);
                  if (context.mounted) {
                    showSnack(
                      context,
                      added ? 'Saved to wishlist' : 'Removed from wishlist',
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    showSnack(context, errorText(e), error: true);
                  }
                }
              },
            ),
            orElse: () => const SizedBox.shrink(),
          ),
          const CartButton(),
        ],
      ),
      body: AsyncBody(
        value: detail,
        onRetry: () => ref.invalidate(productDetailProvider(widget.id)),
        builder: (d) {
          final p = d.summary;
          final canBuy = p.isAvailable && p.inStock;
          final maxQty = p.stockQuantity < 1
              ? 1
              : (p.stockQuantity > 99 ? 99 : p.stockQuantity);
          if (_qty > maxQty) _qty = maxQty;
          final urls = d.images.isNotEmpty
              ? d.images.map((i) => i.url).toList()
              : [if (p.imageUrl != null) p.imageUrl!];
          return Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    AspectRatio(
                      aspectRatio: 1.2,
                      child: Stack(
                        children: [
                          urls.isEmpty
                              ? const AppNetworkImage(null, radius: 0)
                              : PageView.builder(
                                  controller: _page,
                                  itemCount: urls.length,
                                  onPageChanged: (i) =>
                                      setState(() => _image = i),
                                  itemBuilder: (_, i) => AppNetworkImage(
                                    urls[i],
                                    radius: 0,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                          if (urls.length > 1)
                            Positioned(
                              bottom: 10,
                              left: 0,
                              right: 0,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var i = 0; i < urls.length; i++)
                                    Container(
                                      width: 7,
                                      height: 7,
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: i == _image
                                            ? context.palette.primary
                                            : Colors.white.withValues(
                                                alpha: .8,
                                              ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              StatusChip(
                                p.condition,
                                label: p.isUsed ? 'Used' : 'New',
                              ),
                              const SizedBox(width: 8),
                              if (d.categoryName != null)
                                Text(
                                  d.categoryName!,
                                  style: TextStyle(
                                    color: context.palette.muted,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            p.name,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if ((p.brand ?? '').isNotEmpty)
                            Text(
                              [p.brand, p.model]
                                  .whereType<String>()
                                  .where((s) => s.isNotEmpty)
                                  .join(' · '),
                              style: TextStyle(
                                color: context.palette.muted,
                                fontSize: 15,
                              ),
                            ),
                          const SizedBox(height: 10),
                          PriceText(
                            p.price,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                canBuy ? Icons.check_circle : Icons.cancel,
                                size: 18,
                                color: canBuy
                                    ? AppColors.success
                                    : AppColors.danger,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                !p.isAvailable
                                    ? 'Currently unavailable'
                                    : !p.inStock
                                    ? 'Out of stock'
                                    : p.stockQuantity <= 5
                                    ? 'Only ${p.stockQuantity} left'
                                    : 'In stock',
                                style: TextStyle(
                                  color: canBuy
                                      ? AppColors.success
                                      : AppColors.danger,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          if ((d.description ?? '').isNotEmpty) ...[
                            const SizedBox(height: 20),
                            Text(
                              'About this product',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              d.description!,
                              style: const TextStyle(height: 1.4),
                            ),
                          ],
                          if (d.specifications.isNotEmpty) ...[
                            const SizedBox(height: 20),
                            Text(
                              'Specifications',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  children: [
                                    for (final e in d.specifications.entries)
                                      InfoRow(
                                        e.key,
                                        e.value is List
                                            ? (e.value as List).join(', ')
                                            : '${e.value}',
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          if (p.vendor != null) ...[
                            const SizedBox(height: 20),
                            Text(
                              'Seller',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: context.palette.line,
                                  child: Icon(
                                    Icons.storefront_outlined,
                                    color: context.palette.primary,
                                  ),
                                ),
                                title: Text(
                                  p.vendor!.businessName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  p.vendor!.location.isEmpty
                                      ? 'Verified seller'
                                      : p.vendor!.location,
                                ),
                                trailing: p.vendor!.pickupAvailable
                                    ? const Chip(
                                        label: Text('Pickup'),
                                        visualDensity: VisualDensity.compact,
                                      )
                                    : null,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
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
                      QuantityStepper(
                        value: _qty,
                        max: maxQty,
                        busy: !canBuy,
                        onChanged: (v) => setState(() => _qty = v),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: (!canBuy || _busy)
                              ? null
                              : () => _addToCart(p),
                          icon: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.add_shopping_cart),
                          label: Text(canBuy ? 'Add to cart' : 'Unavailable'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
