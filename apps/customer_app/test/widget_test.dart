import 'package:customer_app/app/app.dart';
import 'package:customer_app/core/api/api_client.dart';
import 'package:customer_app/core/providers.dart';
import 'package:customer_app/features/checkout/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// Pumps the real app with a fake identity provider and a stubbed HTTP layer (no Supabase, no network).
Future<({FakeAuthService auth, StubAdapter http})> pumpApp(
  WidgetTester tester, {
  FakeAuthService? auth,
  Responder? responder,
}) async {
  final a = auth ?? FakeAuthService(token: null);
  final http = StubAdapter(
    responder ??
        (o) => switch (o.path) {
          '/auth/me' => jsonBody(meJson()),
          '/cart' => jsonBody({'id': 'c', 'items': [], 'summary': {}}),
          _ => jsonBody({
            'items': [],
            'total': 0,
            'page': 1,
            'limit': 20,
            'pages': 0,
          }),
        },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(a),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://x/api/v1',
            readToken: a.accessToken,
            dio: Dio()..httpClientAdapter = http,
          ),
        ),
      ],
      child: const CustomerApp(),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return (auth: a, http: http);
}

Finder field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('signed-out user sees the login screen', (tester) async {
    await pumpApp(tester);
    expect(field('E-mail'), findsOneWidget);
    expect(field('Password'), findsOneWidget);
  });

  testWidgets(
    'login validates input locally and does not call the identity provider',
    (tester) async {
      final r = await pumpApp(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      expect(r.auth.signInCalls, 0);
      expect(find.byType(FilledButton), findsWidgets);
      await tester.enterText(field('E-mail'), 'not-an-email');
      await tester.enterText(field('Password'), 'x');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      expect(r.auth.signInCalls, 0);
    },
  );

  testWidgets('double-tapping Sign in submits once', (tester) async {
    final r = await pumpApp(tester);
    await tester.enterText(field('E-mail'), 'asha@example.com');
    await tester.enterText(field('Password'), 'Secret123');
    final btn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.tap(btn);
    await tester.pump();
    final busyButton = tester.widget<FilledButton>(
      find.byType(FilledButton).first,
    );
    expect(
      busyButton.onPressed,
      isNull,
      reason: 'button is disabled while the request is in flight',
    );
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.signInCalls, 1);
  });

  testWidgets(
    'customer signs in → asks backend /auth/me with Bearer token → lands in the app shell',
    (tester) async {
      final r = await pumpApp(tester);
      await tester.enterText(field('E-mail'), 'asha@example.com');
      await tester.enterText(field('Password'), 'Secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final me = r.http.requests.firstWhere((o) => o.path == '/auth/me');
      expect(me.headers['Authorization'], 'Bearer tok-1');
      expect(
        find.text('Categories'),
        findsWidgets,
      ); // bottom navigation is visible
      expect(field('Password'), findsNothing);
    },
  );

  testWidgets(
    'a vendor account is refused in the customer app and signed out',
    (tester) async {
      final r = await pumpApp(
        tester,
        responder: (o) => o.path == '/auth/me'
            ? jsonBody(meJson(role: 'vendor'))
            : jsonBody({}),
      );
      await tester.enterText(field('E-mail'), 'v@example.com');
      await tester.enterText(field('Password'), 'Secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(r.auth.signedOut, isTrue);
      expect(find.textContaining('Vendor app'), findsOneWidget);
      expect(field('Password'), findsOneWidget);
    },
  );

  testWidgets('a suspended customer is refused', (tester) async {
    final r = await pumpApp(
      tester,
      responder: (o) => o.path == '/auth/me'
          ? jsonBody(meJson(status: 'suspended'))
          : jsonBody({}),
    );
    await tester.enterText(field('E-mail'), 'a@example.com');
    await tester.enterText(field('Password'), 'Secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.signedOut, isTrue);
    expect(find.textContaining('suspended'), findsOneWidget);
  });

  testWidgets(
    'wrong password shows the identity provider message and allows retry',
    (tester) async {
      final r = await pumpApp(
        tester,
        auth: FakeAuthService(
          token: null,
          failSignInWith: 'Invalid login credentials',
        ),
      );
      await tester.enterText(field('E-mail'), 'asha@example.com');
      await tester.enterText(field('Password'), 'Wrong12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Invalid login credentials'), findsOneWidget);
      expect(
        r.http.requests.where((o) => o.path == '/auth/me'),
        isEmpty,
        reason: 'backend is never called without a session',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(r.auth.signInCalls, 2);
    },
  );

  testWidgets(
    'existing session restores through /auth/me; backend outage does not log the user out',
    (tester) async {
      final r = await pumpApp(
        tester,
        auth: FakeAuthService(),
        responder: (o) => jsonBody({
          'error': {'code': 'internal_error', 'message': 'x'},
        }, 503),
      );
      expect(r.auth.signedOut, isFalse);
      expect(find.text('Try again'), findsOneWidget);
    },
  );

  test(
    'checkout payment-method logic: online only when the provider is configured',
    () {
      final off = CheckoutOptions.fromJson({
        'cod_enabled': true,
        'online_enabled': true,
        'online_provider_configured': false,
        'multi_vendor_allowed': true,
      });
      expect(off.codEnabled, isTrue);
      expect(
        off.onlineEnabled && off.onlineProviderConfigured,
        isFalse,
        reason: 'online payment must not be offered without a provider',
      );
      final none = CheckoutOptions.fromJson({
        'cod_enabled': false,
        'online_enabled': false,
        'online_provider_configured': false,
        'multi_vendor_allowed': false,
      });
      expect(none.anyPaymentMethod, isFalse);
    },
  );
}
