import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendor_app/core/auth/auth_service.dart';

import 'support/fakes.dart';
import 'widget_test.dart' show backend, field, pumpApp;

Finder get googleButton =>
    find.widgetWithText(OutlinedButton, 'Continue with Google');

void main() {
  testWidgets('sign-in offers Continue with Google and keeps e-mail sign-in', (
    tester,
  ) async {
    await pumpApp(tester, responder: backend());
    expect(googleButton, findsOneWidget);
    expect(field('E-mail'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets(
    'registration has no Google button: Google cannot create a vendor-role account',
    (tester) async {
      await pumpApp(tester, responder: backend());
      await tester.tap(find.text('Create a vendor account'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(
        find.byType(OutlinedButton).evaluate().where((e) {
          final w = e.widget as OutlinedButton;
          return w.child is Row;
        }),
        isEmpty,
      );
      expect(find.text('Create account'), findsWidgets);
    },
  );

  testWidgets('an approved vendor signs in with Google and reaches the app', (
    tester,
  ) async {
    final r = await pumpApp(
      tester,
      responder: backend(me: meJson(), vendor: vendorJson()),
    );
    await tester.tap(googleButton);
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(find.byType(OutlinedButton).first)
          .onPressed,
      isNull,
      reason: 'disabled while in flight',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.googleCalls, 1);
    final me = r.http.requests.firstWhere((o) => o.path == '/auth/me');
    expect(me.headers['Authorization'], 'Bearer tok-1');
    expect(field('Password'), findsNothing);
  });

  testWidgets('cancelling the Google chooser is silent and retryable', (
    tester,
  ) async {
    final auth = FakeAuthService(token: null)
      ..googleOutcome = const AuthCancelled();
    final r = await pumpApp(tester, auth: auth, responder: backend());
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(field('E-mail'), findsOneWidget);
    expect(r.http.requests.where((o) => o.path == '/auth/me'), isEmpty);
    auth.googleOutcome = null;
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.googleCalls, 2);
  });

  testWidgets('a Google failure shows a readable message', (tester) async {
    final auth = FakeAuthService(token: null)
      ..googleOutcome = AuthFailure('Google sign-in failed. Please try again.');
    await pumpApp(tester, auth: auth, responder: backend());
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.text('Google sign-in failed. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'role gate still applies: a customer Google account is refused in the vendor app',
    (tester) async {
      final r = await pumpApp(
        tester,
        responder: backend(me: meJson(role: 'customer')),
      );
      await tester.tap(googleButton);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(r.auth.signedOut, isTrue);
      expect(find.textContaining('Customer app'), findsOneWidget);
    },
  );

  testWidgets(
    'a vendor awaiting approval cannot operate after Google sign-in',
    (tester) async {
      await pumpApp(
        tester,
        responder: backend(
          me: meJson(),
          vendor: vendorJson(status: 'pending'),
        ),
      );
      await tester.tap(googleButton);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Dashboard'), findsNothing);
    },
  );
}
