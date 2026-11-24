import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/config.dart';
import '../features/addresses/repository.dart';
import '../features/authentication/repository.dart';
import '../features/bookings/repository.dart';
import '../features/cart/repository.dart';
import '../features/checkout/repository.dart';
import '../features/notifications/repository.dart';
import '../features/orders/repository.dart';
import '../features/products/repository.dart';
import '../features/services/repository.dart';
import '../features/support/repository.dart';
import '../features/wishlist/repository.dart';
import 'api/api_client.dart';
import 'auth/auth_service.dart';
import 'auth/auth_controller.dart';

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

final authRepositoryProvider = Provider(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);
final profileRepositoryProvider = Provider(
  (ref) => ProfileRepository(ref.watch(apiClientProvider)),
);
final addressRepositoryProvider = Provider(
  (ref) => AddressRepository(ref.watch(apiClientProvider)),
);
final catalogRepositoryProvider = Provider(
  (ref) => CatalogRepository(ref.watch(apiClientProvider)),
);
final cartRepositoryProvider = Provider(
  (ref) => CartRepository(ref.watch(apiClientProvider)),
);
final wishlistRepositoryProvider = Provider(
  (ref) => WishlistRepository(ref.watch(apiClientProvider)),
);
final checkoutRepositoryProvider = Provider(
  (ref) => CheckoutRepository(ref.watch(apiClientProvider)),
);
final paymentRepositoryProvider = Provider(
  (ref) => PaymentRepository(ref.watch(apiClientProvider)),
);
final orderRepositoryProvider = Provider(
  (ref) => OrderRepository(ref.watch(apiClientProvider)),
);
final serviceRepositoryProvider = Provider(
  (ref) => ServiceRepository(ref.watch(apiClientProvider)),
);
final bookingRepositoryProvider = Provider(
  (ref) => BookingRepository(ref.watch(apiClientProvider)),
);
final notificationRepositoryProvider = Provider(
  (ref) => NotificationRepository(ref.watch(apiClientProvider)),
);
final supportRepositoryProvider = Provider(
  (ref) => SupportRepository(ref.watch(apiClientProvider)),
);

/// Bumped after actions that change server-side lists (order placed, booking made, cancelled...) so open list screens reload.
class RefreshTick extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final ordersTickProvider = NotifierProvider<RefreshTick, int>(RefreshTick.new);
final bookingsTickProvider = NotifierProvider<RefreshTick, int>(
  RefreshTick.new,
);
