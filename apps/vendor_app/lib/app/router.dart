import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/authentication/screens.dart';
import '../features/business_profile/screens.dart';
import '../features/dashboard/screens.dart';
import '../features/earnings/screens.dart';
import '../features/earnings/transactions_screen.dart';
import '../features/notifications/screens.dart';
import '../features/orders/screens.dart';
import '../features/pickup_dropoff/screens.dart';
import '../features/products/screens.dart';
import '../features/service_bookings/hub.dart';
import '../features/service_bookings/screens.dart';
import '../features/services/screens.dart';
import '../features/settings/screens.dart';
import 'shell.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Bridges Riverpod auth state to go_router's redirect re-evaluation.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen<AuthState>(authControllerProvider, (_, _) => notifyListeners());
  }
}

const _publicPaths = {'/login', '/register', '/forgot-password'};

/// The single place that decides which screens a vendor may see:
///   signed out            -> login / register / forgot password only
///   no business yet       -> /onboarding only
///   pending/suspended     -> /status only
///   rejected              -> /status and /business/edit (to correct details)
///   approved              -> the whole business app
/// The BACKEND enforces the same rules on every API call; this only avoids showing screens that could not work.
String? redirectFor(AuthState auth, String loc) {
  switch (auth.status) {
    case AuthStatus.unknown:
    case AuthStatus.error:
      return loc == '/splash' ? null : '/splash';
    case AuthStatus.signedOut:
      return _publicPaths.contains(loc) ? null : '/login';
    case AuthStatus.signedIn:
      switch (auth.stage) {
        case VendorStage.notRegistered:
          return loc == '/onboarding' ? null : '/onboarding';
        case VendorStage.pending:
        case VendorStage.suspended:
          return loc == '/status' ? null : '/status';
        case VendorStage.rejected:
          return (loc == '/status' || loc == '/business/edit')
              ? null
              : '/status';
        case VendorStage.approved:
          const gated = {
            '/splash',
            '/onboarding',
            '/status',
            '/login',
            '/register',
            '/forgot-password',
          };
          return gated.contains(loc) ? '/dashboard' : null;
      }
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  GoRoute full(String path, Widget Function(GoRouterState) b) => GoRoute(
    parentNavigatorKey: _rootKey,
    path: path,
    builder: (_, s) => b(s),
  );

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) =>
        redirectFor(ref.read(authControllerProvider), state.matchedLocation),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(
        path: '/forgot-password',
        builder: (_, _) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (_, _) => const BusinessFormScreen(editing: false),
      ),
      GoRoute(path: '/status', builder: (_, _) => const VendorStatusScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => MainShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (_, _) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/products',
                builder: (_, _) => const ProductsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/orders',
                builder: (_, s) => OrdersScreen(
                  initialStatus: s.uri.queryParameters['status'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/services',
                builder: (_, _) => const ServicesHubScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/account',
                builder: (_, _) => const AccountScreen(),
              ),
            ],
          ),
        ],
      ),
      full('/products/new', (_) => const ProductFormScreen()),
      full(
        '/products/:id',
        (s) => ProductFormScreen(productId: s.pathParameters['id']),
      ),
      full('/inventory', (_) => const InventoryScreen()),
      full(
        '/orders/:id',
        (s) => OrderDetailScreen(id: s.pathParameters['id']!),
      ),
      full('/services/new', (_) => const ServiceFormScreen()),
      full(
        '/services/:id',
        (s) => ServiceEditScreen(id: s.pathParameters['id']!),
      ),
      full(
        '/bookings/:id',
        (s) => BookingDetailScreen(id: s.pathParameters['id']!),
      ),
      full('/pickups', (_) => const PickupsScreen()),
      full(
        '/pickups/:id',
        (s) => PickupDetailScreen(id: s.pathParameters['id']!),
      ),
      full('/earnings', (_) => const EarningsScreen()),
      full('/settlements', (_) => const SettlementsScreen()),
      full(
        '/commissions',
        (_) => const SettlementsScreen(commissionView: true),
      ),
      full('/transactions', (_) => const TransactionsScreen()),
      full('/notifications', (_) => const NotificationsScreen()),
      full('/business', (_) => const BusinessProfileScreen()),
      full('/business/edit', (_) => const BusinessFormScreen(editing: true)),
      full('/settings', (_) => const SettingsScreen()),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: const Center(child: Text('That page does not exist.')),
    ),
  );
});
