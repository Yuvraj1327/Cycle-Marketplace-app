import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'models.dart';

final orderDetailProvider = FutureProvider.family
    .autoDispose<OrderDetail, String>(
      (ref, id) => ref.read(orderRepositoryProvider).detail(id),
    );
final orderTrackingProvider = FutureProvider.family
    .autoDispose<OrderTracking, String>(
      (ref, id) => ref.read(orderRepositoryProvider).tracking(id),
    );
final orderPaymentsProvider = FutureProvider.family
    .autoDispose<List<Payment>, String>(
      (ref, id) => ref.read(orderRepositoryProvider).payments(id),
    );
