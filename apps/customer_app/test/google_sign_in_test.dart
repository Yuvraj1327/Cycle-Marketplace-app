import 'package:customer_app/core/auth/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'widget_test.dart' show field, pumpApp;

Finder get googleButton =>
    find.widgetWithText(OutlinedButton, 'Continue with Google');

void main() {
  testWidgets('login offers Continue with Google next to e-mail sign-in', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(googleButton, findsOneWidget);
    expect(field('E-mail'), findsOneWidget); // e-mail/password is untouched
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('register offers Sign up with Google', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.widgetWithText(OutlinedButton, 'Sign up with Google'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
  });

  testWidgets(
    'Google sign-in → /auth/me with the Supabase token → lands in the app',
    (tester) async {
      final r = await pumpApp(tester);
      await tester.tap(googleButton);
      await tester.pump(); // in flight
      expect(
        tester
            .widget<OutlinedButton>(find.byType(OutlinedButton).first)
            .onPressed,
        isNull,
        reason: 'disabled while the request is in flight',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(r.auth.googleCalls, 1);
      final me = r.http.requests.firstWhere((o) => o.path == '/auth/me');
      expect(me.headers['Authorization'], 'Bearer tok-1');
      expect(field('Password'), findsNothing);
      expect(find.text('Categories'), findsWidgets);
    },
  );

  testWidgets('cancelling the Google chooser is silent and retryable', (
    tester,
  ) async {
    final auth = FakeAuthService(token: null)
      ..googleOutcome = const AuthCancelled();
    final r = await pumpApp(tester, auth: auth);
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.info_outline), findsNothing, reason: 'no banner');
    expect(field('E-mail'), findsOneWidget);
    expect(r.http.requests.where((o) => o.path == '/auth/me'), isEmpty);
    auth.googleOutcome = null;
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.googleCalls, 2);
    expect(field('Password'), findsNothing);
  });

  testWidgets('a Google failure shows a readable message', (tester) async {
    final auth = FakeAuthService(token: null)
      ..googleOutcome = AuthFailure('Google sign-in failed. Please try again.');
    await pumpApp(tester, auth: auth);
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.text('Google sign-in failed. Please try again.'),
      findsOneWidget,
    );
    expect(field('E-mail'), findsOneWidget);
  });

  testWidgets(
    'role gate still applies: a vendor Google account is refused and signed out',
    (tester) async {
      final r = await pumpApp(
        tester,
        responder: (o) => o.path == '/auth/me'
            ? jsonBody(meJson(role: 'vendor'))
            : jsonBody({}),
      );
      await tester.tap(googleButton);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(r.auth.signedOut, isTrue);
      expect(find.textContaining('Vendor app'), findsOneWidget);
      expect(field('Password'), findsOneWidget);
    },
  );

  testWidgets('a suspended customer is refused after Google sign-in', (
    tester,
  ) async {
    final r = await pumpApp(
      tester,
      responder: (o) => o.path == '/auth/me'
          ? jsonBody(meJson(status: 'suspended'))
          : jsonBody({}),
    );
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.auth.signedOut, isTrue);
    expect(find.textContaining('suspended'), findsOneWidget);
  });

  testWidgets('an empty profile name is filled from the Google account', (
    tester,
  ) async {
    final me = meJson();
    (me['profile'] as Map<String, dynamic>)['full_name'] = '';
    final r = await pumpApp(
      tester,
      responder: (o) => switch (o.path) {
        '/auth/me' => jsonBody(me),
        '/profiles/me' => jsonBody({
          'id': 'user-1',
          'full_name': 'Gita Google',
          'role': 'customer',
          'status': 'active',
        }),
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
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final put = r.http.requests.singleWhere(
      (o) => o.path == '/profiles/me' && o.method == 'PUT',
    );
    expect(put.data, {'full_name': 'Gita Google'});
  });

  testWidgets('an existing profile name is never overwritten', (tester) async {
    final r = await pumpApp(tester);
    await tester.tap(googleButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(r.http.requests.where((o) => o.method == 'PUT'), isEmpty);
  });
}
