import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../addresses/providers.dart';
import '../cart/providers.dart';
import '../notifications/providers.dart';
import '../products/models.dart';
import '../products/providers.dart';
import '../wishlist/providers.dart';

IconData kindIcon(String kind) => switch (kind) {
  'new_cycle' => Icons.pedal_bike,
  'used_cycle' => Icons.recycling,
  'spare_part' => Icons.settings_outlined,
  'accessory' => Icons.sports_motorsports_outlined,
  _ => Icons.category_outlined,
};

/// Where a promotional banner leads. Only destinations the backend defines are honoured.
void openBanner(BuildContext context, PromoBanner b) {
  switch (b.actionType) {
    case 'product' when b.actionValue != null:
      context.push('/product/${b.actionValue}');
    case 'category' when b.actionValue != null:
      context.push(
        '/products?categoryId=${b.actionValue}&title=${Uri.encodeComponent(b.title)}',
      );
    case 'service' when b.actionValue != null:
      context.go('/services?categoryId=${b.actionValue}');
    default:
      break;
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).me;
    final address = ref.watch(selectedAddressProvider);
    final first = (me?.profile.fullName ?? '').trim().split(' ').first;

    Future<void> refresh() async {
      ref.invalidate(bannersProvider);
      ref.invalidate(rootCategoriesProvider);
      ref.invalidate(featuredProductsProvider);
      ref.invalidate(latestProductsProvider);
      ref.invalidate(serviceCategoriesProvider);
      ref.invalidate(unreadCountProvider);
      await Future.wait([
        ref.read(cartProvider.notifier).reload(),
        ref.read(wishlistProvider.notifier).reload(),
        ref.read(addressesProvider.notifier).reload(),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        toolbarHeight: 64,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              first.isEmpty ? 'Hello!' : 'Hello, $first',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            InkWell(
              onTap: () => context.push('/addresses'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.place_outlined,
                    size: 15,
                    color: context.palette.muted,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      address == null
                          ? 'Add a delivery address'
                          : '${address.city} ${address.postalCode}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.muted,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 16,
                    color: context.palette.muted,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: const [
          NotificationsButton(),
          CartButton(),
          SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const _SearchBar(),
            const _Banners(),
            const _CategoryRow(),
            _ProductRow(title: 'Featured', provider: featuredProductsProvider),
            _ProductRow(
              title: 'Latest arrivals',
              provider: latestProductsProvider,
              newest: true,
            ),
            const _ServicesSection(),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.lg),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/search'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.palette.line),
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: context.palette.muted),
            SizedBox(width: 10),
            Text(
              'Search cycles, parts, accessories',
              style: TextStyle(color: context.palette.muted),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Banners extends ConsumerStatefulWidget {
  const _Banners();
  @override
  ConsumerState<_Banners> createState() => _BannersState();
}

class _BannersState extends ConsumerState<_Banners> {
  final _page = PageController(viewportFraction: .92);
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banners = ref.watch(bannersProvider);
    return banners.when(
      loading: () => const SizedBox(height: 150, child: LoadingView()),
      error: (e, _) =>
          const SizedBox.shrink(), // a failing banner must not break the home screen
      data: (list) {
        if (list.isEmpty) {
          return const SizedBox.shrink(); // no banners configured: show nothing (never fake ones)
        }
        return Column(
          children: [
            SizedBox(
              height: 150,
              child: PageView.builder(
                controller: _page,
                itemCount: list.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) {
                  final b = list[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      onTap: () => openBanner(context, b),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AppNetworkImage(
                            b.imageUrl,
                            radius: 16,
                            icon: Icons.campaign_outlined,
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Colors.black.withValues(alpha: .65),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 14,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  b.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if ((b.subtitle ?? '').isNotEmpty)
                                  Text(
                                    b.subtitle!,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (list.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < list.length; i++)
                      Container(
                        width: i == _index ? 18 : 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: i == _index
                              ? context.palette.primary
                              : context.palette.line,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CategoryRow extends ConsumerWidget {
  const _CategoryRow();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(rootCategoriesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Shop by category',
          actionLabel: 'All',
          onAction: () => context.go('/categories'),
        ),
        cats.when(
          loading: () => const SizedBox(height: 96, child: LoadingView()),
          error: (e, _) => SizedBox(
            height: 120,
            child: ErrorView(
              e,
              onRetry: () => ref.invalidate(rootCategoriesProvider),
            ),
          ),
          data: (list) => list.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    'Categories will appear here once they are set up.',
                    style: TextStyle(color: context.palette.muted),
                  ),
                )
              : SizedBox(
                  height: 104,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      final c = list[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => context.push(
                          '/products?categoryId=${c.id}&title=${Uri.encodeComponent(c.name)}',
                        ),
                        child: SizedBox(
                          width: 84,
                          child: Column(
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color: context.palette.primary.withValues(
                                    alpha: .1,
                                  ),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: c.imageUrl != null
                                    ? AppNetworkImage(
                                        c.imageUrl,
                                        radius: 18,
                                        icon: kindIcon(c.kind),
                                      )
                                    : Icon(
                                        kindIcon(c.kind),
                                        color: context.palette.primary,
                                        size: 30,
                                      ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                c.name,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProductRow extends ConsumerWidget {
  const _ProductRow({
    required this.title,
    required this.provider,
    this.newest = false,
  });
  final String title;
  final FutureProvider<List<ProductSummary>> provider;
  final bool newest;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(provider);
    return data.when(
      loading: () => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title),
          const SizedBox(height: 120, child: LoadingView()),
        ],
      ),
      error: (e, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title),
          SizedBox(
            height: 140,
            child: ErrorView(e, onRetry: () => ref.invalidate(provider)),
          ),
        ],
      ),
      data: (items) {
        if (items.isEmpty) {
          return const SizedBox.shrink(); // nothing featured yet: hide the section instead of showing fake items
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title,
              onAction: newest
                  ? () => context.push(
                      '/products?title=${Uri.encodeComponent(title)}',
                    )
                  : null,
            ),
            SizedBox(
              height: 262,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => ProductCard(items[i], width: 168),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ServicesSection extends ConsumerWidget {
  const _ServicesSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(serviceCategoriesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Cycle servicing & repair',
          actionLabel: 'Book',
          onAction: () => context.go('/services'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Card(
            color: context.palette.primary,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => context.go('/services'),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.local_shipping_outlined,
                      color: Colors.white,
                      size: 34,
                    ),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Doorstep pickup & drop-off',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Where your provider offers it, we collect your cycle, repair it and bring it back.',
                            style: TextStyle(color: Colors.white70),
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
        cats.maybeWhen(
          data: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in list)
                        ActionChip(
                          avatar: const Icon(Icons.build_outlined, size: 16),
                          label: Text(c.name),
                          onPressed: () =>
                              context.go('/services?categoryId=${c.id}'),
                        ),
                    ],
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
    );
  }
}
