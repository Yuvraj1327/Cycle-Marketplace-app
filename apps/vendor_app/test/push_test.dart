import 'dart:async';

import 'package:vendor_app/app/app.dart';
import 'package:vendor_app/app/router.dart';
import 'package:vendor_app/core/api/api_client.dart';
import 'package:vendor_app/core/auth/auth_controller.dart';
import 'package:vendor_app/core/providers.dart';
import 'package:vendor_app/core/push/notification_route.dart';
import 'package:vendor_app/core/push/push_controller.dart';
import 'package:vendor_app/core/push/push_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show Size, SnackBarAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// A scripted push service: lets a test play the part of Firebase (tokens, permission, foreground messages, taps). The real FirebasePushService needs a live
/// Firebase project and is NOT exercised here.
class FakePush implements PushService {
  FakePush({this.available = true, this.permission = PushPermission.granted, this.tokenValue = 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa'});
  final bool available;
  final PushPermission permission;
  String? tokenValue;
  int deleted = 0, permissionAsked = 0;
  final refreshes = StreamController<String>.broadcast();
  final foreground = StreamController<PushPayload>.broadcast();
  final taps = StreamController<PushPayload>.broadcast();
  PushPayload? launch;

  @override
  bool get isAvailable => available;
  @override
  Future<PushPermission> requestPermission() async {
    permissionAsked++;
    return permission;
  }

  @override
  Future<String?> token() async => tokenValue;
  @override
  Stream<String> get tokenRefreshes => refreshes.stream;
  @override
  Stream<PushPayload> get foregroundMessages => foreground.stream;
  @override
  Stream<PushPayload> get opened => taps.stream;
  @override
  Future<PushPayload?> initialMessage() async => launch;
  @override
  Future<void> deleteToken() async => deleted++;
}

const orderId = '6f1c2b0e-8a41-4a53-9b7e-2d3c4e5f6a7b';
const bookingId = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
const productId = '7c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f';

class Harness {
  Harness(this.tester, this.auth, this.http, this.push, this.container);
  final WidgetTester tester;
  final FakeAuthService auth;
  final StubAdapter http;
  final FakePush push;
  final ProviderContainer container;
  /// The top-most screen: pushed routes are imperative matches, so the router's `uri` stays at the base location.
  String get location => container.read(routerProvider).routerDelegate.currentConfiguration.last.matchedLocation;
  List<RequestOptions> calls(String method, String path) => http.requests.where((r) => r.method == method && r.path == path).toList();
}

Future<Harness> pump(WidgetTester tester, {FakePush? push, bool signedIn = true, Responder? responder}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final p = push ?? FakePush();
  final a = FakeAuthService(token: signedIn ? 'tok-1' : null);
  final http = StubAdapter(
    responder ??
        (o) => switch (o.path) {
          '/auth/me' => jsonBody(meJson()),
          '/vendors/me' => jsonBody(vendorJson()),
          '/vendor/dashboard' => jsonBody({'orders': {'total': 0, 'by_status': {}, 'sales_total': 0, 'commission_total': 0}, 'products': {'total': 0, 'active': 0, 'pending_approval': 0, 'rejected': 0, 'out_of_stock': 0}, 'bookings': {'total': 0, 'by_status': {}, 'completed_value': 0}, 'settlements': {}}),
          '/devices' || '/devices/unregister' || '/auth/logout' => jsonBody({}),
          '/notifications' => jsonBody({'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0, 'unread_count': 3}),
          _ => jsonBody({'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0}),
        },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(a),
        pushServiceProvider.overrideWithValue(p),
        apiClientProvider.overrideWith((ref) => ApiClient(baseUrl: 'http://x/api/v1', readToken: a.accessToken, dio: Dio()..httpClientAdapter = http)),
      ],
      child: const VendorApp(),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return Harness(tester, a, http, p, ProviderScope.containerOf(tester.element(find.byType(VendorApp))));
}

PushPayload payload({String? type = 'order', String? relatedType = 'vendor_order', String? relatedId = orderId, String title = 'New order', String body = 'New order ORD-1 is waiting for your response.'}) =>
    PushPayload(notificationId: 'n-1', type: type, relatedType: relatedType, relatedId: relatedId, title: title, body: body);

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  group('notification routes', () {
    test('maps records to this app\'s screens and refuses anything that is not a real id', () {
      expect(routeForNotification(relatedType: 'vendor_order', relatedId: orderId), '/orders/$orderId');
      expect(routeForNotification(relatedType: 'service_booking', relatedId: bookingId), '/bookings/$bookingId');
      expect(routeForNotification(relatedType: 'product', relatedId: productId), '/products/$productId');
      expect(routeForNotification(relatedType: 'vendor_service', relatedId: productId), '/services/$productId');
      expect(routeForNotification(relatedType: 'vendor_application', relatedId: productId), '/status');
      expect(routeForNotification(relatedType: 'vendor_application'), '/status');
      expect(routeForNotification(relatedType: 'payment', relatedId: orderId), isNull);
      expect(routeForNotification(relatedType: 'vendor_order', relatedId: '../../etc/passwd'), isNull);
      expect(routeForNotification(relatedType: 'vendor_order', relatedId: '1; DROP'), isNull);
      expect(routeForNotification(relatedType: 'vendor_order'), isNull);
      expect(routeForNotification(), isNull);
      expect(pushAppName, 'vendor');
    });
  });

  group('device registration', () {
    testWidgets('without Firebase configured nothing is requested or registered and the app works as before', (tester) async {
      final h = await pump(tester, push: FakePush(available: false));
      expect(h.location, '/dashboard');
      expect(h.push.permissionAsked, 0);
      expect(h.calls('PUT', '/devices'), isEmpty);
    });

    testWidgets('after sign-in the device token is registered with the backend, with the Bearer token and the app type', (tester) async {
      final h = await pump(tester, signedIn: false);
      expect(h.calls('PUT', '/devices'), isEmpty, reason: 'nothing is registered while signed out');
      final f = h.container.read(authControllerProvider.notifier).signIn('owner@example.com', 'Secret123');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await f;
      expect(h.push.permissionAsked, 1);
      final put = h.calls('PUT', '/devices').single;
      expect(put.data, {'token': 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa', 'platform': 'android', 'app': 'vendor'});
      expect(put.headers['Authorization'], 'Bearer tok-1');
    });

    testWidgets('an already signed-in session registers on start-up, and a refreshed token is registered again', (tester) async {
      final h = await pump(tester);
      expect(h.calls('PUT', '/devices'), hasLength(1));
      h.push.refreshes.add('fcm-token-bbbbbbbbbbbbbbbbbbbbbbbb');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.calls('PUT', '/devices').map((r) => r.data['token']), ['fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa', 'fcm-token-bbbbbbbbbbbbbbbbbbbbbbbb']);
    });

    testWidgets('declining the permission registers nothing and does not disturb the app', (tester) async {
      final h = await pump(tester, push: FakePush(permission: PushPermission.denied));
      expect(h.location, '/dashboard');
      expect(h.calls('PUT', '/devices'), isEmpty);
      expect(h.container.read(pushControllerProvider).lastPermission, PushPermission.denied);
    });

    testWidgets('a backend failure while registering is swallowed (the app keeps working)', (tester) async {
      final h = await pump(tester, responder: (o) => switch (o.path) {
        '/auth/me' => jsonBody(meJson()),
        '/vendors/me' => jsonBody(vendorJson()),
        '/devices' => jsonBody({'error': {'code': 'internal_error', 'message': 'x'}}, 500),
        _ => jsonBody({'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0, 'unread_count': 0}),
      });
      expect(h.location, '/dashboard');
      expect(h.container.read(pushControllerProvider).isRegistered, isFalse);
    });

    testWidgets('a device without a token (e.g. no Google Play services) simply stays unregistered', (tester) async {
      final h = await pump(tester, push: FakePush(tokenValue: null));
      expect(h.calls('PUT', '/devices'), isEmpty);
      expect(h.location, '/dashboard');
    });
  });

  group('signing out', () {
    testWidgets('explicit sign-out unregisters the token BEFORE the session is discarded, then invalidates it on the device', (tester) async {
      final h = await pump(tester);
      final f = h.container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await f;
      await tester.pump();
      final order = h.http.requests.map((r) => '${r.method} ${r.path}').toList();
      expect(order.indexOf('POST /devices/unregister'), greaterThanOrEqualTo(0));
      expect(order.indexOf('POST /devices/unregister'), lessThan(order.indexOf('POST /auth/logout')));
      expect(h.calls('POST', '/devices/unregister').single.data, {'token': 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa'});
      expect(h.calls('POST', '/devices/unregister').single.headers['Authorization'], 'Bearer tok-1');
      expect(h.auth.signedOut, isTrue);
      expect(h.push.deleted, 1);
      expect(h.location, '/login');
    });

    testWidgets('an expired session cannot call the backend, but the device token is still invalidated', (tester) async {
      final h = await pump(tester);
      h.container.read(authControllerProvider.notifier).sessionExpired();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.calls('POST', '/devices/unregister'), isEmpty);
      expect(h.push.deleted, 1);
      expect(h.location, '/login');
    });

    testWidgets('a slow or failing unregister never blocks signing out', (tester) async {
      final h = await pump(tester, responder: (o) => switch (o.path) {
        '/auth/me' => jsonBody(meJson()),
        '/vendors/me' => jsonBody(vendorJson()),
        '/devices/unregister' => jsonBody({'error': {'code': 'internal_error', 'message': 'x'}}, 500),
        _ => jsonBody({'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0, 'unread_count': 0}),
      });
      final f = h.container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await f;
      expect(h.auth.signedOut, isTrue);
      expect(h.location, '/login');
    });
  });

  group('receiving and opening notifications', () {
    testWidgets('a foreground message refreshes the unread badge and shows a banner that opens the order', (tester) async {
      final h = await pump(tester);
      final before = h.calls('GET', '/notifications').length;
      h.push.foreground.add(payload());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800)); // let the banner finish sliding in
      expect(find.textContaining('New order: New order ORD-1 is waiting for your response.'), findsOneWidget);
      expect(h.calls('GET', '/notifications').length, greaterThan(before), reason: 'the badge is re-read from the backend');
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed(); // the banner's "View" action
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/orders/$orderId');
    });

    testWidgets('tapping a notification while the app is in the background opens that booking', (tester) async {
      final h = await pump(tester);
      h.push.taps.add(payload(type: 'service_booking', relatedType: 'service_booking', relatedId: bookingId));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/bookings/$bookingId');
    });

    testWidgets('a notification without a record (an announcement) opens the notification list; a crafted id never builds a path', (tester) async {
      final h = await pump(tester);
      h.push.taps.add(payload(type: 'announcement', relatedType: null, relatedId: null));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/notifications');
      h.container.read(routerProvider).pop();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      h.push.taps.add(payload(relatedId: '../../admin'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/notifications');
    });

    testWidgets('a product approval opens the product', (tester) async {
      final h = await pump(tester);
      h.push.taps.add(payload(type: 'system', relatedType: 'product', relatedId: productId, title: 'Product approved'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/products/$productId');
    });

    testWidgets('a vendor whose application is still pending is kept on the status screen whatever the notification points at', (tester) async {
      final h = await pump(tester, responder: (o) => switch (o.path) {
        '/auth/me' => jsonBody(meJson()),
        '/vendors/me' => jsonBody(vendorJson(status: 'pending')),
        _ => jsonBody({'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0, 'unread_count': 0}),
      });
      expect(h.location, '/status');
      h.push.taps.add(payload());
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/status', reason: 'the router never lets an unapproved vendor reach order screens');
    });

    testWidgets('launching the app from a tap (terminated state) goes to the record once the user is signed in', (tester) async {
      final push = FakePush()..launch = payload();
      final h = await pump(tester, push: push);
      expect(h.location, '/orders/$orderId');
    });

    testWidgets('a tap while signed out is remembered and followed after sign-in', (tester) async {
      final h = await pump(tester, signedIn: false);
      h.push.taps.add(payload());
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/login', reason: 'a private record is never opened for a signed-out user');
      final f = h.container.read(authControllerProvider.notifier).signIn('owner@example.com', 'Secret123');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await f;
      expect(h.location, '/orders/$orderId');
    });

    testWidgets('a record that is not the user\'s (backend 404) shows the screen\'s error state, not a crash', (tester) async {
      final h = await pump(tester, responder: (o) => switch (o.path) {
        '/auth/me' => jsonBody(meJson()),
        '/vendors/me' => jsonBody(vendorJson()),
        '/devices' => jsonBody({}),
        '/vendor/orders/$orderId' => jsonBody({'error': {'code': 'not_found', 'message': 'Order not found.'}}, 404),
        _ => jsonBody({'items': [], 'total': 0, 'page': 1, 'limit': 20, 'pages': 0, 'unread_count': 0}),
      });
      h.push.taps.add(payload());
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(h.location, '/orders/$orderId');
      expect(find.textContaining('not found', findRichText: true), findsWidgets);
    });
  });
}
