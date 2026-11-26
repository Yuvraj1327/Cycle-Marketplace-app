import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/push/push_controller.dart';
import 'router.dart';
import 'theme.dart';

class VendorApp extends ConsumerWidget {
  const VendorApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      pushControllerProvider,
    ); // keeps device registration and notification taps alive for the whole session
    return MaterialApp.router(
      title: 'My Cycle Clinic',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      scaffoldMessengerKey: pushMessengerKey,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
