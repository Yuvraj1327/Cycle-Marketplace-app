import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/config.dart';
import '../features/authentication/repository.dart';
import '../features/business_profile/repository.dart';
import '../features/earnings/repository.dart';
import '../features/notifications/repository.dart';
import '../features/orders/repository.dart';
import '../features/pickup_dropoff/repository.dart';
import '../features/products/repository.dart';
import '../features/service_bookings/repository.dart';
import '../features/services/repository.dart';
import 'api/api_client.dart';
import 'auth/auth_controller.dart';
import 'auth/auth_service.dart';

/// Overridden in `main()` with the Supabase implementations (and with fakes in tests).
final authServiceProvider = Provider<AuthService>(
  (ref) => throw UnimplementedError('authServiceProvider must be overridden'),
);
final imageStorageProvider = Provider<ImageStorage>(
  (ref) => throw UnimplementedError('imageStorageProvider must be overridden'),
);
final apiBaseUrlProvider = Provider<String>((ref) => AppConfig.apiV1);

final apiClientProvider = Provider<ApiClient>((ref) {
  final auth = ref.watch(authServiceProvider);
  return ApiClient(
    baseUrl: ref.watch(apiBaseUrlProvider),
    readToken: auth.accessToken,
    refreshToken: auth.refreshAccessToken,
    onSessionExpired: () =>
        ref.read(authControllerProvider.notifier).sessionExpired(),
  );
});

final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.me?.id)),
);

final authRepositoryProvider = Provider(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);
final vendorProfileRepositoryProvider = Provider(
  (ref) => VendorProfileRepository(ref.watch(apiClientProvider)),
);
final dashboardRepositoryProvider = Provider(
  (ref) => DashboardRepository(ref.watch(apiClientProvider)),
);
final productRepositoryProvider = Provider(
  (ref) => ProductRepository(ref.watch(apiClientProvider)),
);
final orderRepositoryProvider = Provider(
  (ref) => OrderRepository(ref.watch(apiClientProvider)),
);
final serviceRepositoryProvider = Provider(
  (ref) => ServiceRepository(ref.watch(apiClientProvider)),
);
final serviceBookingRepositoryProvider = Provider(
  (ref) => ServiceBookingRepository(ref.watch(apiClientProvider)),
);
final pickupRepositoryProvider = Provider(
  (ref) => PickupDropoffRepository(ref.watch(apiClientProvider)),
);
final earningsRepositoryProvider = Provider(
  (ref) => EarningsRepository(ref.watch(apiClientProvider)),
);
final notificationRepositoryProvider = Provider(
  (ref) => NotificationRepository(ref.watch(apiClientProvider)),
);

/// Bumped after actions that change server-side lists so open list screens and the dashboard reload.
class RefreshTick extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final productsTickProvider = NotifierProvider<RefreshTick, int>(
  RefreshTick.new,
);
final ordersTickProvider = NotifierProvider<RefreshTick, int>(RefreshTick.new);
final servicesTickProvider = NotifierProvider<RefreshTick, int>(
  RefreshTick.new,
);
final bookingsTickProvider = NotifierProvider<RefreshTick, int>(
  RefreshTick.new,
);
final pickupsTickProvider = NotifierProvider<RefreshTick, int>(RefreshTick.new);

/// One aggregate request for the dashboard AND the earnings screen (shared, so they never disagree and are not fetched twice).
final dashboardProvider = FutureProvider.autoDispose((ref) async {
  ref.watch(ordersTickProvider);
  ref.watch(bookingsTickProvider);
  ref.watch(productsTickProvider);
  return ref.read(dashboardRepositoryProvider).summary();
});
