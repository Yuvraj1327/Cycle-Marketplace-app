import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/models/paged.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/common.dart';
import 'models.dart';
import 'providers.dart';

IconData _icon(String type) => switch (type) {
  'order' => Icons.receipt_long_outlined,
  'payment' => Icons.payments_outlined,
  'service_booking' => Icons.build_circle_outlined,
  'pickup_delivery' => Icons.local_shipping_outlined,
  'promotion' => Icons.local_offer_outlined,
  _ => Icons.campaign_outlined,
};

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  late final PagedController<AppNotification> _paged = PagedController((
    page,
  ) async {
    final res = await ref.read(notificationRepositoryProvider).list(page);
    return Paged<AppNotification>(
      items: res.items,
      total: 0,
      page: res.page,
      limit: 20,
      pages: res.pages,
    );
  });

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  Future<void> _open(AppNotification n, int index) async {
    if (!n.isRead) {
      try {
        await ref.read(notificationRepositoryProvider).markRead(n.id);
        _paged.replace(index, n.asRead());
        ref.invalidate(unreadCountProvider);
      } catch (_) {
        /* reading still navigates; the badge refreshes next time */
      }
    }
    if (!mounted || n.relatedId == null) return;
    switch (n.relatedType) {
      case 'order':
        context.push('/orders/${n.relatedId}');
      case 'service_booking':
        context.push('/bookings/${n.relatedId}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Notifications'),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await ref.read(notificationRepositoryProvider).markAllRead();
              ref.invalidate(unreadCountProvider);
              await _paged.refresh();
            } catch (e) {
              if (context.mounted) {
                showSnack(context, errorText(e), error: true);
              }
            }
          },
          child: const Text('Mark all read'),
        ),
      ],
    ),
    body: PagedListView<AppNotification>(
      controller: _paged,
      separator: 0,
      padding: EdgeInsets.zero,
      empty: const EmptyState(
        icon: Icons.notifications_none,
        title: 'No notifications yet',
        message: 'Order, payment and booking updates will appear here.',
      ),
      itemBuilder: (context, n) {
        final i = _paged.items.indexOf(n);
        return Container(
          color: n.isRead ? null : AppColors.primary.withValues(alpha: .06),
          child: ListTile(
            onTap: () => _open(n, i),
            leading: CircleAvatar(
              backgroundColor: AppColors.primary.withValues(alpha: .1),
              child: Icon(_icon(n.type), color: AppColors.primary),
            ),
            title: Text(
              n.title,
              style: TextStyle(
                fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w800,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.message),
                const SizedBox(height: 2),
                Text(
                  dateTime(n.createdAt),
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ],
            ),
            trailing: n.isRead
                ? null
                : const Icon(Icons.circle, size: 10, color: AppColors.primary),
          ),
        );
      },
    ),
  );
}
