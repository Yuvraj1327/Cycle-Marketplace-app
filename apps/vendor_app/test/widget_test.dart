import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendor_app/app/app.dart';
import 'package:vendor_app/core/api/api_client.dart';
import 'package:vendor_app/core/providers.dart';

import 'support/fakes.dart';

const emptyPage = {'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0};
const emptyDashboard = {
  'orders': {
    'total': 4,
    'by_status': {'pending': 2, 'delivered': 2},
    'sales_total': 5000.0,
    'commission_total': 500.0,
  },
  'products': {
    'total': 6,
    'active': 5,
    'pending_approval': 1,
    'rejected': 0,
    'out_of_stock': 0,
  },
  'bookings': {
    'total': 3,
    'by_status': {'pending': 1, 'completed': 2},
    'completed_value': 1200.0,
  },
  'settlements': {
    'ready': {
      'count': 2,
      'gross': 5000.0,
      'commission': 500.0,
      'deductions': 0.0,
      'net': 4500.0,
    },
  },
};

/// Pumps the real vendor app with a fake identity provider and a stubbed HTTP layer (no Supabase, no network).
Future<({FakeAuthService auth, StubAdapter http})> pumpApp(
  WidgetTester tester, {
  FakeAuthService? auth,
  required Responder responder,
}) async {
  final a = auth ?? FakeAuthService(token: null);
  final http = StubAdapter(responder);
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(a),
        imageStorageProvider.overrideWithValue(FakeImageStorage()),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://x/api/v1',
            readToken: a.accessToken,
            dio: Dio()..httpClientAdapter = http,
          ),
        ),
      ],
      child: const VendorApp(),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return (auth: a, http: http);
}

Responder backend({
  Map<String, dynamic>? me,
  Object? vendor,
  int vendorStatus = 200,
}) => (o) {
  switch (o.path) {
    case '/auth/me':
      return jsonBody(me ?? meJson());
    case '/vendors/me':
      return vendor == null
          ? jsonBody({
              'error': {
                'code': 'not_found',
                'message': 'No vendor application found.',
              },
            }, 404)
          : jsonBody(vendor, vendorStatus);
    case '/vendor/dashboard':
      return jsonBody(emptyDashboard);
    case '/notifications':
      return jsonBody({...emptyPage, 'unread_count': 0});
    default:
      return jsonBody(emptyPage);
  }
};

Finder field(String label) => find.widgetWithText(TextFormField, label);

Future<void> signIn(WidgetTester tester) async {
  await tester.enterText(field('E-mail'), 'owner@example.com');
  await tester.enterText(field('Password'), 'Secret123');
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('signed-out vendor sees the sign-in screen', (tester) async {
    await pumpApp(tester, responder: backend());
    expect(find.text('Sign in to your business'), findsOneWidget);
  });

  testWidgets('login validates locally and double-tap submits once', (
    tester,
  ) async {
    final r = await pumpApp(tester, responder: backend());
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(r.auth.signInCalls, 0);
    await tester.enterText(field('E-mail'), 'owner@example.com');
    await tester.enterText(field('Password'), 'Secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNull,
      reason: 'disabled while in flight',
    );
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.signInCalls, 1);
  });

  testWidgets('a customer account is refused in the vendor app', (
    tester,
  ) async {
    final r = await pumpApp(
      tester,
      responder: backend(me: meJson(role: 'customer')),
    );
    await signIn(tester);
    expect(r.auth.signedOut, isTrue);
    expect(find.textContaining('Customer app'), findsOneWidget);
  });

  testWidgets(
    'vendor without a business goes to onboarding and cannot reach the dashboard',
    (tester) async {
      await pumpApp(tester, responder: backend());
      await signIn(tester);
      expect(find.text('Business details'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Submit for verification'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Submit for verification'), findsOneWidget);
      expect(find.text('Dashboard'), findsNothing);
    },
  );

  testWidgets(
    'pending vendor sees the verification-pending screen, no business navigation',
    (tester) async {
      await pumpApp(
        tester,
        responder: backend(vendor: vendorJson(status: 'pending')),
      );
      await signIn(tester);
      expect(find.text('Verification pending'), findsOneWidget);
      expect(find.text('Check status'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets(
    'rejected vendor sees the administrator\'s reason and can update details',
    (tester) async {
      await pumpApp(
        tester,
        responder: backend(
          vendor: vendorJson(
            status: 'rejected',
            reason: 'Shop photos were unclear',
          ),
        ),
      );
      await signIn(tester);
      expect(find.text('Application not approved'), findsOneWidget);
      expect(find.textContaining('Shop photos were unclear'), findsOneWidget);
      expect(find.text('Update business details'), findsOneWidget);
    },
  );

  testWidgets('suspended vendor is restricted and has no edit action', (
    tester,
  ) async {
    await pumpApp(
      tester,
      responder: backend(vendor: vendorJson(status: 'suspended')),
    );
    await signIn(tester);
    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.text('Update business details'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'approved vendor: dashboard shows the backend aggregates and five-tab navigation',
    (tester) async {
      final r = await pumpApp(tester, responder: backend(vendor: vendorJson()));
      await signIn(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      for (final l in [
        'Dashboard',
        'Products',
        'Orders',
        'Services',
        'Account',
      ]) {
        expect(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(l),
          ),
          findsOneWidget,
        );
      }
      expect(find.text('Spoke & Co'), findsWidgets);
      expect(find.text('Total orders'), findsOneWidget);
      expect(find.text('Pending orders'), findsOneWidget);
      expect(
        find.textContaining('2 new orders and 1 new booking'),
        findsOneWidget,
      );
      expect(
        r.http.requests.where((o) => o.path == '/vendor/dashboard').length,
        1,
        reason: 'one aggregate request, not many',
      );
      expect(
        r.http.requests
            .firstWhere((o) => o.path == '/vendors/me')
            .headers['Authorization'],
        'Bearer tok-1',
      );
    },
  );

  testWidgets('backend outage at start does not log the vendor out', (
    tester,
  ) async {
    final r = await pumpApp(
      tester,
      auth: FakeAuthService(),
      responder: (o) => jsonBody({
        'error': {'code': 'internal_error', 'message': 'x'},
      }, 503),
    );
    expect(r.auth.signedOut, isFalse);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('empty states: products and orders show helpful empty screens', (
    tester,
  ) async {
    await pumpApp(tester, responder: backend(vendor: vendorJson()));
    await signIn(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Products'),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('No products yet'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Orders'),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('No orders yet'), findsOneWidget);
  });
}
