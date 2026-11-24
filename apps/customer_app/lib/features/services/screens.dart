import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../products/providers.dart';
import 'models.dart';
import 'providers.dart';

export '../bookings/booking_flow.dart' show BookingFlowScreen;

class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key, this.initialCategoryId, this.vendorId});
  final String? initialCategoryId, vendorId;
  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  String? _categoryId;
  late PagedController<ServiceItem> _paged = _make();

  @override
  void initState() {
    super.initState();
    _categoryId = widget.initialCategoryId;
    _paged = _make();
  }

  @override
  void didUpdateWidget(ServicesScreen old) {
    super.didUpdateWidget(old);
    if (old.initialCategoryId != widget.initialCategoryId ||
        old.vendorId != widget.vendorId) {
      _select(widget.initialCategoryId);
    }
  }

  PagedController<ServiceItem> _make() => PagedController(
    (p) => ref
        .read(serviceRepositoryProvider)
        .services(p, categoryId: _categoryId, vendorId: widget.vendorId),
  );

  void _select(String? id) {
    final old = _paged;
    setState(() {
      _categoryId = id;
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
    final cats = ref.watch(serviceCategoriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cycle services'),
        actions: [
          IconButton(
            tooltip: 'My bookings',
            icon: const Icon(Icons.event_note_outlined),
            onPressed: () => context.push('/bookings'),
          ),
        ],
      ),
      body: Column(
        children: [
          cats.when(
            loading: () => const SizedBox(height: 52),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton.icon(
                onPressed: () => ref.invalidate(serviceCategoriesProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Could not load categories — retry'),
              ),
            ),
            data: (list) => SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: 10,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('All'),
                      selected: _categoryId == null,
                      onSelected: (_) => _select(null),
                    ),
                  ),
                  for (final c in list)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(c.name),
                        selected: _categoryId == c.id,
                        onSelected: (_) => _select(c.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: PagedListView<ServiceItem>(
              key: ValueKey(_paged),
              controller: _paged,
              empty: const EmptyState(
                icon: Icons.build_circle_outlined,
                title: 'No services found',
                message:
                    'No provider offers this service yet. Try another category.',
              ),
              itemBuilder: (_, s) => ServiceCard(s),
            ),
          ),
        ],
      ),
    );
  }
}

class ServiceDetailScreen extends ConsumerWidget {
  const ServiceDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(serviceDetailProvider(id));
    return Scaffold(
      appBar: AppBar(title: const Text('Service details')),
      body: AsyncBody<ServiceItem>(
        value: service,
        onRetry: () => ref.invalidate(serviceDetailProvider(id)),
        builder: (s) {
          final p = s.provider;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    if (s.categoryName != null)
                      Text(
                        s.categoryName!,
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      s.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    PriceText(
                      s.price,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Text(
                      'Estimated price — the provider confirms any additional work after inspecting your cycle.',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      children: [
                        Chip(
                          avatar: const Icon(Icons.schedule, size: 16),
                          label: Text('Takes about ${s.durationLabel}'),
                        ),
                        if (p?.pickupAvailable == true)
                          const Chip(
                            avatar: Icon(
                              Icons.local_shipping_outlined,
                              size: 16,
                            ),
                            label: Text('Doorstep pickup & drop-off'),
                          ),
                        if (!s.isAvailable)
                          const StatusChip(
                            'unavailable',
                            label: 'Not accepting bookings',
                          ),
                      ],
                    ),
                    if ((s.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'What is included',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(s.description!, style: const TextStyle(height: 1.4)),
                    ],
                    if (p != null) ...[
                      const SizedBox(height: 20),
                      Text(
                        'Service provider',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const CircleAvatar(
                                    backgroundColor: AppColors.line,
                                    child: Icon(
                                      Icons.storefront_outlined,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.businessName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        if (p.location.isNotEmpty)
                                          Text(
                                            p.location,
                                            style: const TextStyle(
                                              color: AppColors.muted,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              InfoRow(
                                'Opening hours',
                                _hours(p.operatingHours),
                              ),
                              if (p.serviceAreaPostalCodes.isNotEmpty)
                                InfoRow(
                                  'Service area',
                                  'PIN ${p.serviceAreaPostalCodes.join(', ')}',
                                ),
                              InfoRow(
                                'Doorstep pickup',
                                p.pickupAvailable
                                    ? 'Available'
                                    : 'Not offered — bring your cycle to the shop',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    border: Border(top: BorderSide(color: AppColors.line)),
                  ),
                  child: FilledButton(
                    onPressed: s.isAvailable
                        ? () => context.push('/book/${s.id}')
                        : null,
                    child: Text(
                      s.isAvailable
                          ? 'Book this service'
                          : 'Currently unavailable',
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _hours(Map<String, dynamic> h) {
    if (h.isEmpty) return 'Not provided';
    const names = {
      'mon': 'Mon',
      'tue': 'Tue',
      'wed': 'Wed',
      'thu': 'Thu',
      'fri': 'Fri',
      'sat': 'Sat',
      'sun': 'Sun',
    };
    final groups = <String, List<String>>{};
    for (final d in names.keys) {
      final v = h[d];
      final label = v is Map && v['closed'] != true && v['open'] != null
          ? '${_t(v['open'])}–${_t(v['close'])}'
          : 'Closed';
      groups.putIfAbsent(label, () => []).add(names[d]!);
    }
    return groups.entries
        .map(
          (e) =>
              '${e.value.length > 1 ? '${e.value.first}–${e.value.last}' : e.value.first}: ${e.key}',
        )
        .join('\n');
  }

  static String _t(dynamic hhmm) {
    final s = '$hhmm';
    if (s.length < 5) return s;
    final h = int.tryParse(s.substring(0, 2)) ?? 0;
    return '${h % 12 == 0 ? 12 : h % 12}:${s.substring(3, 5)} ${h >= 12 ? 'PM' : 'AM'}';
  }
}
