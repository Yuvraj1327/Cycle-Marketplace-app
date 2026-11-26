import 'package:customer_app/app/app.dart';
import 'package:customer_app/core/api/api_client.dart';
import 'package:customer_app/core/providers.dart';
import 'package:customer_app/features/onboarding/onboarding_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

Future<void> pumpOnboarding(
  WidgetTester tester, {
  required OnboardingStore store,
  bool signedIn = false,
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  final a = FakeAuthService(token: signedIn ? 'tok-1' : null);
  final http = StubAdapter(
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
        onboardingStoreProvider.overrideWithValue(store),
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
}

const titles = [
  'Find Your Perfect Cycle',
  'Everything Your Cycle Needs',
  'Expert Cycle Servicing',
  'Service at Your Doorstep',
];

final primary = find.byKey(const Key('onboarding-primary'));
final skip = find.byKey(const Key('onboarding-skip'));
final loginField = find.widgetWithText(TextFormField, 'E-mail');

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('first launch shows page 1 with Skip and Next', (tester) async {
    await pumpOnboarding(tester, store: FakeOnboardingStore(completed: false));
    expect(find.text(titles[0]), findsOneWidget);
    expect(
      find.text('Discover new and pre-owned bicycles for every ride.'),
      findsOneWidget,
    );
    expect(skip, findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Get Started'), findsNothing);
    expect(find.byType(Image), findsWidgets);
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(Key('onboarding-dot-$i')), findsOneWidget);
    }
  });

  testWidgets('Next walks through all four pages, last shows Get Started', (
    tester,
  ) async {
    await pumpOnboarding(tester, store: FakeOnboardingStore(completed: false));
    for (var i = 1; i < 4; i++) {
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(find.text(titles[i]), findsOneWidget);
    }
    expect(find.text('Get Started'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    // Skip is hidden (and inert) on the last page.
    expect(
      tester
          .widget<IgnorePointer>(
            find.ancestor(of: skip, matching: find.byType(IgnorePointer)).first,
          )
          .ignoring,
      isTrue,
    );
  });

  testWidgets('swiping moves forward and back', (tester) async {
    await pumpOnboarding(tester, store: FakeOnboardingStore(completed: false));
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(titles[1]), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(titles[2]), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(titles[1]), findsOneWidget);
  });

  testWidgets('Skip goes to login and is remembered', (tester) async {
    final store = FakeOnboardingStore(completed: false);
    await pumpOnboarding(tester, store: store);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(loginField, findsOneWidget);
    expect(find.text(titles[0]), findsNothing);
    expect(store.isCompleted, isTrue);
  });

  testWidgets('Get Started goes to login and is remembered', (tester) async {
    final store = FakeOnboardingStore(completed: false);
    await pumpOnboarding(tester, store: store);
    for (var i = 0; i < 3; i++) {
      await tester.tap(primary);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(loginField, findsOneWidget);
    expect(store.isCompleted, isTrue);
  });

  testWidgets('returning signed-out user goes straight to login', (
    tester,
  ) async {
    await pumpOnboarding(tester, store: FakeOnboardingStore(completed: true));
    expect(loginField, findsOneWidget);
    expect(find.text(titles[0]), findsNothing);
  });

  testWidgets('signed-in user never sees onboarding', (tester) async {
    await pumpOnboarding(
      tester,
      store: FakeOnboardingStore(completed: false),
      signedIn: true,
    );
    expect(find.text(titles[0]), findsNothing);
    expect(loginField, findsNothing);
  });

  for (final size in const [
    Size(320, 568),
    Size(360, 640),
    Size(412, 915),
    Size(768, 1024),
  ]) {
    // Any RenderFlex overflow is reported by the framework and fails the test.
    testWidgets('lays out on every page at ${size.width}x${size.height}', (
      tester,
    ) async {
      await pumpOnboarding(
        tester,
        store: FakeOnboardingStore(completed: false),
        size: size,
      );
      for (var i = 0; i < 3; i++) {
        await tester.tap(primary);
        await tester.pumpAndSettle();
      }
      expect(find.text('Get Started'), findsOneWidget);
    });
  }

  group('SharedPrefsOnboardingStore', () {
    test('defaults to not completed, then persists across instances', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await SharedPrefsOnboardingStore.create();
      expect(first.isCompleted, isFalse);
      await first.markCompleted();
      final second = await SharedPrefsOnboardingStore.create();
      expect(second.isCompleted, isTrue);
    });
  });
}
