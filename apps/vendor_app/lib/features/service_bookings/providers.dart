import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../orders/models.dart' show TimelineEvent;
import 'models.dart';

final bookingDetailProvider = FutureProvider.family
    .autoDispose<VendorBooking, String>(
      (ref, id) => ref.read(serviceBookingRepositoryProvider).detail(id),
    );
final bookingTimelineProvider = FutureProvider.family
    .autoDispose<List<TimelineEvent>, String>(
      (ref, id) => ref.read(serviceBookingRepositoryProvider).timeline(id),
    );

final recentBookingsProvider = FutureProvider.autoDispose<List<VendorBooking>>((
  ref,
) async {
  ref.watch(bookingsTickProvider);
  return (await ref.read(serviceBookingRepositoryProvider).list(1, limit: 5))
      .items;
});
