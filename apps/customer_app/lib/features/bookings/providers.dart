import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'models.dart';

final bookingDetailProvider = FutureProvider.family
    .autoDispose<BookingDetail, String>(
      (ref, id) => ref.read(bookingRepositoryProvider).detail(id),
    );
final bookingTrackingProvider = FutureProvider.family
    .autoDispose<BookingTracking, String>(
      (ref, id) => ref.read(bookingRepositoryProvider).tracking(id),
    );
