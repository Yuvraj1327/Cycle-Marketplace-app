import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../home/screens.dart';
import '../products/providers.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(rootCategoriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: [
          IconButton(
            onPressed: () => context.push('/search'),
            icon: const Icon(Icons.search),
          ),
          const CartButton(),
        ],
      ),
      body: AsyncBody(
        value: cats,
        onRetry: () => ref.invalidate(rootCategoriesProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.category_outlined,
                title: 'No categories yet',
                message:
                    'Categories will appear here as soon as they are set up.',
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(rootCategoriesProvider),
                child: GridView.builder(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  physics: const AlwaysScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.15,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final c = list[i];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => context.push(
                          '/products?categoryId=${c.id}&title=${Uri.encodeComponent(c.name)}',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Center(
                                  child: c.imageUrl != null
                                      ? AppNetworkImage(
                                          c.imageUrl,
                                          icon: kindIcon(c.kind),
                                        )
                                      : Icon(
                                          kindIcon(c.kind),
                                          size: 52,
                                          color: context.palette.primary,
                                        ),
                                ),
                              ),
                              Text(
                                c.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (c.productCount != null)
                                Text(
                                  '${c.productCount} items',
                                  style: TextStyle(
                                    color: context.palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
