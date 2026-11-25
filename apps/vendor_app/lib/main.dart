import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/config.dart';
import 'app/theme.dart';
import 'core/auth/supabase_auth_service.dart';
import 'core/providers.dart';
import 'core/push/firebase_push_service.dart';
import 'core/push/push_controller.dart';
import 'core/push/push_service.dart';
import 'features/authentication/screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.supabaseConfigured) {
    // Never crash on a missing build configuration: say exactly what is missing.
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const ConfigErrorScreen(),
      ),
    );
    return;
  }
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
  // Firebase push: null (and therefore off) until the four FIREBASE_* values are supplied at build time.
  final PushService push =
      await FirebasePushService.create() ?? const NoopPushService();
  runApp(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(SupabaseAuthService()),
        imageStorageProvider.overrideWithValue(SupabaseImageStorage()),
        pushServiceProvider.overrideWithValue(push),
      ],
      child: const VendorApp(),
    ),
  );
}
