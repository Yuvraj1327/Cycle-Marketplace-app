import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Unread badge. Refresh with `ref.invalidate(unreadCountProvider)`.
final unreadCountProvider = FutureProvider<int>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return 0;
  try {
    return await ref.read(notificationRepositoryProvider).unreadCount();
  } catch (_) {
    return 0; // a failing badge must never break a screen
  }
});
