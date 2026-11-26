import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/addresses/screens.dart';
import '../features/authentication/screens.dart';
import '../features/bookings/screens.dart';
import '../features/cart/screens.dart';
import '../features/categories/screens.dart';
import '../features/checkout/screens.dart';
import '../features/home/screens.dart';
import '../features/notifications/screens.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/onboarding/onboarding_store.dart';
import '../features/orders/screens.dart';
import '../features/products/screens.dart';
import '../features/profile/screens.dart';
import '../features/services/screens.dart';
import '../features/settings/screens.dart';
import '../features/support/screens.dart';
import '../features/wishlist/screens.dart';
import 'shell.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Bridges Riverpod auth state to go_router's redirect re-evaluation.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen<AuthState>(authControllerProvider, (_, _) => notifyListeners());
    ref.listen<bool>(onboardingCompletedProvider, (_, _) => notifyListeners());
  }
}

const _publicPaths = {'/login', '/register', '/forgot-password'};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;
      switch (auth.status) {
        case AuthStatus.unknown:
        case AuthStatus.error:
          return loc == '/splash' ? null : '/splash';
        case AuthStatus.signedOut:
          // First launch on this device: onboarding comes before the auth screens.
          if (!ref.read(onboardingCompletedProvider)) {
            return loc == '/onboarding' ? null : '/onboarding';
          }
          return _publicPaths.contains(loc)
              ? null
              : '/login'; // every private screen requires a signed-in customer
        case AuthStatus.signedIn:
          return (loc == '/splash' ||
                  loc == '/onboarding' ||
                  _publicPaths.contains(loc))
              ? '/home'
              : null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(
        path: '/forgot-password',
        builder: (_, _) => const ForgotPasswordScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => MainShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/categories',
                builder: (_, _) => const CategoriesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/services',
                builder: (_, s) => ServicesScreen(
                  initialCategoryId: s.uri.queryParameters['categoryId'],
                  vendorId: s.uri.queryParameters['vendorId'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/wishlist',
                builder: (_, _) => const WishlistScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (_, _) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/search',
        builder: (_, _) =>
            const ProductListScreen(title: 'Search', autofocusSearch: true),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/products',
        builder: (_, s) => ProductListScreen(
          title: s.uri.queryParameters['title'] ?? 'Products',
          categoryId: s.uri.queryParameters['categoryId'],
          productType: s.uri.queryParameters['type'],
          condition: s.uri.queryParameters['condition'],
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/product/:id',
        builder: (_, s) => ProductDetailScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/cart',
        builder: (_, _) => const CartScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/checkout',
        builder: (_, _) => const CheckoutScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/order-confirmation/:id',
        builder: (_, s) =>
            OrderConfirmationScreen(orderId: s.pathParameters['id']!),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/orders',
        builder: (_, _) => const OrdersScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/orders/:id',
        builder: (_, s) => OrderDetailScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/service/:id',
        builder: (_, s) => ServiceDetailScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/book/:serviceId',
        builder: (_, s) =>
            BookingFlowScreen(serviceId: s.pathParameters['serviceId']!),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/bookings',
        builder: (_, _) => const BookingsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/bookings/:id',
        builder: (_, s) => BookingDetailScreen(
          id: s.pathParameters['id']!,
          justBooked: s.uri.queryParameters['new'] == '1',
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/addresses',
        builder: (_, s) =>
            AddressesScreen(selectMode: s.uri.queryParameters['select'] == '1'),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/address-form',
        builder: (_, s) =>
            AddressFormScreen(addressId: s.uri.queryParameters['id']),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/notifications',
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/profile/edit',
        builder: (_, _) => const EditProfileScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/settings',
        builder: (_, _) => const AccountSettingsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/settings/password',
        builder: (_, _) => const ChangePasswordScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/support',
        builder: (_, _) => const SupportScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/support/new',
        builder: (_, s) => NewTicketScreen(
          bookingId: s.uri.queryParameters['bookingId'],
          orderId: s.uri.queryParameters['orderId'],
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/support/:id',
        builder: (_, s) => TicketDetailScreen(id: s.pathParameters['id']!),
      ),
    ],
  );
});
