import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'models.dart';

final serviceDetailProvider = FutureProvider.family
    .autoDispose<ServiceItem, String>(
      (ref, id) => ref.read(serviceRepositoryProvider).service(id),
    );
final bookingOptionsProvider = FutureProvider.autoDispose<BookingOptions>(
  (ref) => ref.read(serviceRepositoryProvider).bookingOptions(),
);

/// (serviceId, 'yyyy-MM-dd') -> slots from the backend.
final availabilityProvider = FutureProvider.family
    .autoDispose<Availability, (String, String)>(
      (ref, key) =>
          ref.read(serviceRepositoryProvider).availability(key.$1, key.$2),
    );
