import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'models.dart';

final orderDetailProvider = FutureProvider.family
    .autoDispose<VendorOrder, String>(
      (ref, id) => ref.read(orderRepositoryProvider).detail(id),
    );
final orderTimelineProvider = FutureProvider.family
    .autoDispose<List<TimelineEvent>, String>(
      (ref, id) => ref.read(orderRepositoryProvider).timeline(id),
    );

/// Latest 5 orders for the dashboard (one small request, refreshed when orders change).
final recentOrdersProvider = FutureProvider.autoDispose<List<VendorOrder>>((
  ref,
) async {
  ref.watch(ordersTickProvider);
  return (await ref.read(orderRepositoryProvider).list(1, limit: 5)).items;
});
