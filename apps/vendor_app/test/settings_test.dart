import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vendor_app/app/app.dart';
import 'package:vendor_app/app/theme.dart';
import 'package:vendor_app/core/api/api_client.dart';
import 'package:vendor_app/core/auth/auth_controller.dart';
import 'package:vendor_app/core/providers.dart';
import 'package:vendor_app/features/settings/avatar.dart';
import 'package:vendor_app/features/settings/screens.dart';
import 'package:vendor_app/features/settings/theme_mode.dart';

import 'support/fakes.dart';

class FakeAvatarStorage implements AvatarStorage {
  final uploads = <String>[];
  final removed = <String>[];
  @override
  Future<String> upload({
    required String userId,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    final p = '$userId/avatar-${uploads.length + 1}.$extension';
    uploads.add(p);
    return p;
  }

  @override
  Future<String?> signedUrl(String path) async => null;
  @override
  Future<void> remove(String path) async => removed.add(path);
}

class _ThrowingStore implements ThemeModeStore {
  @override
  ThemeMode load() => ThemeMode.system;
  @override
  Future<void> save(ThemeMode mode) => throw Exception('disk full');
}

/// A tiny stateful backend: /auth/me, /vendors/me and PUT /profiles/me share one account, like the real API.
class Backend {
  String name = 'Owner Name';
  String? phone;
  String? avatarPath;
  String? putError;
  final puts = <Map<String, dynamic>>[];

  ResponseBody respond(RequestOptions o) {
    switch (o.path) {
      case '/auth/me':
        return jsonBody({
          'id': 'user-1',
          'email': 'owner@example.com',
          'phone': null,
          'role': 'vendor',
          'status': 'active',
          'profile': {
            'id': 'user-1',
            'full_name': name,
            'phone': phone,
            'role': 'vendor',
            'status': 'active',
            'avatar_path': avatarPath,
          },
        });
      case '/vendors/me':
        return jsonBody(vendorJson());
      case '/profiles/me':
        if (o.method == 'PUT') {
          final body = o.data is String
              ? jsonDecode(o.data as String) as Map<String, dynamic>
              : Map<String, dynamic>.from(o.data as Map);
          puts.add(body);
          if (putError != null) {
            return jsonBody({
              'error': {'code': 'permission_denied', 'message': putError},
            }, 403);
          }
          name = (body['full_name'] as String?) ?? name;
          phone = (body['phone'] as String?) ?? phone;
          avatarPath = (body['avatar_path'] as String?) ?? avatarPath;
          return jsonBody({});
        }
    }
    return jsonBody({
      'items': [],
      'total': 0,
      'page': 1,
      'limit': 20,
      'pages': 0,
      'unread_count': 0,
      'orders': {
        'total': 0,
        'by_status': {},
        'sales_total': 0,
        'commission_total': 0,
      },
      'products': {
        'total': 0,
        'active': 0,
        'pending_approval': 0,
        'rejected': 0,
        'out_of_stock': 0,
      },
      'bookings': {'total': 0, 'by_status': {}, 'completed_value': 0},
      'settlements': {},
    });
  }
}

Future<
  ({
    FakeAuthService auth,
    Backend backend,
    FakeAvatarStorage avatars,
    ProviderContainer container,
  })
>
pumpSignedIn(
  WidgetTester tester, {
  ThemeModeStore? themeStore,
  PickedAvatar? pick,
}) async {
  final auth = FakeAuthService();
  final backend = Backend();
  final avatars = FakeAvatarStorage();
  final http = StubAdapter(backend.respond);
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        imageStorageProvider.overrideWithValue(FakeImageStorage()),
        themeModeStoreProvider.overrideWithValue(
          themeStore ?? MemoryThemeModeStore(),
        ),
        avatarStorageProvider.overrideWithValue(avatars),
        avatarPickerProvider.overrideWithValue(() async => pick),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://x/api/v1',
            readToken: auth.accessToken,
            dio: Dio()..httpClientAdapter = http,
          ),
        ),
      ],
      child: const VendorApp(),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  final container = ProviderScope.containerOf(
    tester.element(find.byType(VendorApp)),
  );
  return (auth: auth, backend: backend, avatars: avatars, container: container);
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Account').last);
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  await tester.tap(find.byTooltip('Account settings'));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

ThemeMode appThemeMode(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

void main() {
  group('theme persistence', () {
    test(
      'SharedPreferences store round-trips every mode; junk means system',
      () async {
        SharedPreferences.setMockInitialValues({});
        final first = await SharedPrefsThemeModeStore.create();
        expect(first.load(), ThemeMode.system);
        for (final m in ThemeMode.values) {
          await first.save(m);
          expect((await SharedPrefsThemeModeStore.create()).load(), m);
        }
        SharedPreferences.setMockInitialValues({'theme_mode': 'sepia'});
        expect(
          (await SharedPrefsThemeModeStore.create()).load(),
          ThemeMode.system,
        );
      },
    );

    test(
      'the controller applies the choice immediately and saves it',
      () async {
        final store = MemoryThemeModeStore(ThemeMode.light);
        final c = ProviderContainer(
          overrides: [themeModeStoreProvider.overrideWithValue(store)],
        );
        addTearDown(c.dispose);
        expect(c.read(themeModeProvider), ThemeMode.light);
        await c.read(themeModeProvider.notifier).set(ThemeMode.dark);
        expect(c.read(themeModeProvider), ThemeMode.dark);
        expect(store.load(), ThemeMode.dark);
      },
    );

    test('a failing disk write does not undo the choice', () async {
      final c = ProviderContainer(
        overrides: [themeModeStoreProvider.overrideWithValue(_ThrowingStore())],
      );
      addTearDown(c.dispose);
      await c.read(themeModeProvider.notifier).set(ThemeMode.dark);
      expect(c.read(themeModeProvider), ThemeMode.dark);
    });

    test('light and dark themes carry different palettes and brightness', () {
      final l = buildTheme(), d = buildDarkTheme();
      expect(l.brightness, Brightness.light);
      expect(d.brightness, Brightness.dark);
      expect(d.extension<AppPalette>()!.surface, AppPalette.dark.surface);
      expect(d.scaffoldBackgroundColor, AppPalette.dark.background);
    });
  });

  group('password validation', () {
    test('new password rules', () {
      expect(validateNewPassword(''), isNotNull);
      expect(validateNewPassword('short'), 'Use at least 8 characters');
      expect(validateNewPassword('Longenough1'), isNull);
      expect(
        validateNewPassword('SamePass123', current: 'SamePass123'),
        isNotNull,
      );
    });
    test('confirmation must match', () {
      expect(validateConfirmPassword('', 'abc12345'), isNotNull);
      expect(
        validateConfirmPassword('abc12346', 'abc12345'),
        'Passwords do not match',
      );
      expect(validateConfirmPassword('abc12345', 'abc12345'), isNull);
    });
  });

  group('account settings screen', () {
    testWidgets(
      'opens from the settings icon on Account; shows account details and the business shortcut',
      (tester) async {
        await pumpSignedIn(tester);
        await openSettings(tester);
        expect(find.text('Account settings'), findsOneWidget);
        expect(find.text('owner@example.com'), findsWidgets);
        expect(find.text('Vendor'), findsOneWidget);
        expect(find.text('Business profile'), findsOneWidget);
        expect(find.textContaining('Spoke & Co'), findsOneWidget);
        expect(find.text('System default'), findsOneWidget);
      },
    );

    testWidgets(
      'the business shortcut opens the EXISTING business profile screen',
      (tester) async {
        await pumpSignedIn(tester);
        await openSettings(tester);
        await tester.tap(find.text('Business profile'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(
          find.byTooltip('Edit'),
          findsOneWidget,
        ); // the existing screen's edit action
        expect(find.text('1 MG Road'), findsWidgets);
      },
    );

    testWidgets(
      'choosing Dark restyles the whole app, is saved, and survives a restart',
      (tester) async {
        final store = MemoryThemeModeStore();
        await pumpSignedIn(tester, themeStore: store);
        await openSettings(tester);
        expect(appThemeMode(tester), ThemeMode.system);
        await tester.tap(find.text('Dark'));
        await tester.pumpAndSettle();
        expect(appThemeMode(tester), ThemeMode.dark);
        expect(store.load(), ThemeMode.dark);
        expect(
          Theme.of(tester.element(find.byType(Scaffold).last)).brightness,
          Brightness.dark,
        );
        await tester.tap(find.text('Light'));
        await tester.pumpAndSettle();
        expect(appThemeMode(tester), ThemeMode.light);
        expect(store.load(), ThemeMode.light);

        await tester.pumpWidget(const SizedBox());
        await pumpSignedIn(tester, themeStore: store);
        expect(appThemeMode(tester), ThemeMode.light);
      },
    );

    testWidgets('Log out asks first, then signs out', (tester) async {
      final r = await pumpSignedIn(tester);
      await openSettings(tester);
      await tester.scrollUntilVisible(find.text('Log out'), 200);
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(r.auth.signedOut, isFalse);
      await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(r.auth.signedOut, isTrue);
      expect(find.text('Sign in to your business'), findsOneWidget);
    });

    testWidgets(
      'picking a picture uploads it to the user folder, saves avatar_path and removes the old file',
      (tester) async {
        final r = await pumpSignedIn(
          tester,
          pick: PickedAvatar('me.PNG', Uint8List.fromList([1, 2, 3])),
        );
        r.backend.avatarPath = 'user-1/old.jpg';
        await r.container.read(authControllerProvider.notifier).refreshMe();
        await openSettings(tester);
        await tester.tap(find.bySemanticsLabel('Change profile picture'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(r.avatars.uploads, ['user-1/avatar-1.png']);
        expect(r.backend.puts.single, {'avatar_path': 'user-1/avatar-1.png'});
        expect(r.avatars.removed, ['user-1/old.jpg']);
        expect(find.text('Profile picture updated'), findsOneWidget);
      },
    );

    testWidgets(
      'a failed profile save removes the orphaned upload and says so',
      (tester) async {
        final r = await pumpSignedIn(
          tester,
          pick: PickedAvatar('me.jpg', Uint8List.fromList([1])),
        );
        r.backend.putError = 'nope';
        await openSettings(tester);
        await tester.tap(find.bySemanticsLabel('Change profile picture'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(r.avatars.removed, ['user-1/avatar-1.jpg']);
        expect(find.text('nope'), findsOneWidget);
      },
    );

    testWidgets('cancelling the picker changes nothing', (tester) async {
      final r = await pumpSignedIn(tester);
      await openSettings(tester);
      await tester.tap(find.bySemanticsLabel('Change profile picture'));
      await tester.pumpAndSettle();
      expect(r.avatars.uploads, isEmpty);
      expect(r.backend.puts, isEmpty);
    });

    testWidgets('oversized pictures are refused before any upload', (
      tester,
    ) async {
      final r = await pumpSignedIn(
        tester,
        pick: PickedAvatar('big.jpg', Uint8List(PickedAvatar.maxBytes + 1)),
      );
      await openSettings(tester);
      await tester.tap(find.bySemanticsLabel('Change profile picture'));
      await tester.pumpAndSettle();
      expect(r.avatars.uploads, isEmpty);
      expect(find.textContaining('under 5 MB'), findsOneWidget);
    });
  });

  group('edit profile', () {
    Future<void> openEdit(WidgetTester tester) async {
      await openSettings(tester);
      await tester.tap(find.text('Edit profile'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    }

    testWidgets(
      'saving sends only name/phone (never role, status or e-mail) and refreshes the account',
      (tester) async {
        final r = await pumpSignedIn(tester);
        await openEdit(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Full name'),
          'Owner Q. Name',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Mobile number'),
          '+919876543210',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(r.backend.puts.single, {
          'full_name': 'Owner Q. Name',
          'phone': '+919876543210',
        });
        expect(find.text('Owner Q. Name'), findsWidgets);
      },
    );

    testWidgets('invalid input is stopped locally', (tester) async {
      final r = await pumpSignedIn(tester);
      await openEdit(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Full name'),
        'A',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Mobile number'),
        '12ab',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await tester.pump();
      expect(find.text('Enter your name'), findsOneWidget);
      expect(find.text('Enter 7-15 digits'), findsOneWidget);
      expect(r.backend.puts, isEmpty);
    });

    testWidgets('a backend refusal is shown and the form stays', (
      tester,
    ) async {
      final r = await pumpSignedIn(tester);
      r.backend.putError =
          'Your phone number is managed by your sign-in account.';
      await openEdit(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Mobile number'),
        '+919876543210',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.textContaining('managed by your sign-in'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    });

    testWidgets('e-mail is shown read-only', (tester) async {
      await pumpSignedIn(tester);
      await openEdit(tester);
      final email = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'E-mail'),
      );
      expect(email.enabled, isFalse);
    });
  });

  group('change password', () {
    Future<FakeAuthService> openPassword(WidgetTester tester) async {
      final r = await pumpSignedIn(tester);
      await openSettings(tester);
      await tester.scrollUntilVisible(find.text('Change password'), 200);
      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      return r.auth;
    }

    Finder f(String label) => find.widgetWithText(TextFormField, label);
    Future<void> fill(
      WidgetTester t,
      String cur,
      String nw,
      String conf,
    ) async {
      await t.enterText(f('Current password'), cur);
      await t.enterText(f('New password'), nw);
      await t.enterText(f('Confirm new password'), conf);
    }

    Future<void> submit(WidgetTester t) async {
      await t.tap(find.widgetWithText(FilledButton, 'Update password'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
    }

    testWidgets(
      'validates every field locally and never calls the identity provider',
      (tester) async {
        final auth = await openPassword(tester);
        await submit(tester);
        expect(find.text('Enter your current password'), findsOneWidget);
        expect(find.text('Enter a new password'), findsOneWidget);
        expect(find.text('Confirm your new password'), findsOneWidget);
        await fill(tester, 'OldPass123', 'short', 'short');
        await submit(tester);
        expect(find.text('Use at least 8 characters'), findsOneWidget);
        await fill(tester, 'OldPass123', 'OldPass123', 'OldPass123');
        await submit(tester);
        expect(find.textContaining('not used here before'), findsOneWidget);
        await fill(tester, 'OldPass123', 'NewPass456', 'NewPass789');
        await submit(tester);
        expect(find.text('Passwords do not match'), findsOneWidget);
        expect(auth.passwordChanges, isEmpty);
      },
    );

    testWidgets('a wrong current password is reported and the form stays', (
      tester,
    ) async {
      final auth = await openPassword(tester);
      await fill(tester, 'WrongPass1', 'NewPass456', 'NewPass456');
      await submit(tester);
      expect(find.text('Your current password is incorrect.'), findsOneWidget);
      expect(auth.passwordChanges, isEmpty);
      expect(
        find.widgetWithText(FilledButton, 'Update password'),
        findsOneWidget,
      );
    });

    testWidgets(
      'success updates the password, confirms, and returns to settings',
      (tester) async {
        final auth = await openPassword(tester);
        await fill(tester, 'OldPass123', 'NewPass456', 'NewPass456');
        await tester.tap(find.widgetWithText(FilledButton, 'Update password'));
        await tester.pump();
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(auth.passwordChanges, ['NewPass456']);
        expect(find.text('Password updated'), findsOneWidget);
        expect(find.text('Account settings'), findsOneWidget);
        expect(auth.signedOut, isFalse);
      },
    );

    testWidgets('a provider error (e.g. weak password) is shown as-is', (
      tester,
    ) async {
      final auth = await openPassword(tester);
      auth.failChangeWith = 'Password should be at least 6 characters.';
      await fill(tester, 'OldPass123', 'NewPass456', 'NewPass456');
      await submit(tester);
      expect(find.textContaining('at least 6 characters'), findsOneWidget);
    });

    testWidgets('each field has its own show / hide toggle', (tester) async {
      await openPassword(tester);
      bool obscured(String label) => tester
          .widget<TextField>(
            find.descendant(of: f(label), matching: find.byType(TextField)),
          )
          .obscureText;
      expect(obscured('Current password'), isTrue);
      expect(obscured('New password'), isTrue);
      expect(obscured('Confirm new password'), isTrue);
      await tester.tap(find.byTooltip('Show password').first);
      await tester.pump();
      expect(obscured('Current password'), isFalse);
      expect(obscured('New password'), isTrue);
      await tester.tap(find.byTooltip('Hide password'));
      await tester.pump();
      expect(obscured('Current password'), isTrue);
    });
  });
}
