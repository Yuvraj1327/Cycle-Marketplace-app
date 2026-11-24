import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/widgets/cards_export.dart';
import '../business_profile/screens.dart' show humanizeStatus;

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final v = auth.vendor;
    Widget tile(
      IconData icon,
      String title,
      String route, {
      String? subtitle,
    }) => ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(route),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            color: AppColors.surface,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppColors.primary,
                  child: Text(
                    ((v?.businessName ?? '?').isEmpty
                            ? '?'
                            : v!.businessName[0])
                        .toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v?.businessName ?? 'Your business',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        auth.me?.email ?? '',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 4),
                      if (v != null)
                        StatusChip(
                          v.verificationStatus,
                          label:
                              'Verification: ${humanizeStatus(v.verificationStatus)}',
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: AppColors.surface,
            child: Column(
              children: [
                tile(
                  Icons.storefront_outlined,
                  'Business profile',
                  '/business',
                  subtitle: 'Details, hours, photos, service area',
                ),
                const Divider(height: 1, indent: 56),
                tile(Icons.inventory_2_outlined, 'Inventory', '/inventory'),
                const Divider(height: 1, indent: 56),
                tile(
                  Icons.local_shipping_outlined,
                  'Pickup & drop-off',
                  '/pickups',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: AppColors.surface,
            child: Column(
              children: [
                tile(
                  Icons.account_balance_wallet_outlined,
                  'Earnings & settlements',
                  '/earnings',
                ),
                const Divider(height: 1, indent: 56),
                tile(Icons.percent, 'Commission & deductions', '/commissions'),
                const Divider(height: 1, indent: 56),
                tile(
                  Icons.receipt_long_outlined,
                  'Transactions',
                  '/transactions',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: AppColors.surface,
            child: Column(
              children: [
                tile(
                  Icons.notifications_none,
                  'Notifications',
                  '/notifications',
                ),
                const Divider(height: 1, indent: 56),
                tile(Icons.settings_outlined, 'Settings', '/settings'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: AppColors.surface,
            child: ListTile(
              leading: const Icon(Icons.logout, color: AppColors.danger),
              title: const Text(
                'Log out',
                style: TextStyle(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () async {
                if (await confirmDialog(
                  context,
                  title: 'Log out?',
                  message:
                      'You will need to sign in again to manage your business.',
                  confirmLabel: 'Log out',
                  destructive: true,
                )) {
                  await ref.read(authControllerProvider.notifier).signOut();
                }
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Cycle Marketplace · Vendor',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final has =
        AppConfig.supportEmail.isNotEmpty || AppConfig.supportPhone.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          SectionCard(
            title: 'Account',
            child: Column(
              children: [
                InfoRow(
                  'Name',
                  auth.me?.fullName.isNotEmpty == true
                      ? auth.me!.fullName
                      : '—',
                ),
                InfoRow('E-mail', auth.me?.email ?? '—'),
                InfoRow('Account type', 'Vendor'),
                InfoRow(
                  'Verification',
                  humanizeStatus(
                    auth.vendor?.verificationStatus ?? 'not registered',
                  ),
                ),
                const Text(
                  'Your role and verification are managed by the platform and cannot be changed here.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const SectionCard(
            title: 'Notification preferences',
            child: Text(
              'In-app notifications are always on. Push notification preferences arrive with push delivery in a later step; the backend has no preference settings yet.',
              style: TextStyle(color: AppColors.muted),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Support',
            child: has
                ? Column(
                    children: [
                      if (AppConfig.supportPhone.isNotEmpty)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.phone_outlined),
                          title: Text(AppConfig.supportPhone),
                          onTap: () => launchUrl(
                            Uri(scheme: 'tel', path: AppConfig.supportPhone),
                          ),
                        ),
                      if (AppConfig.supportEmail.isNotEmpty)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.mail_outline),
                          title: Text(AppConfig.supportEmail),
                          onTap: () => launchUrl(
                            Uri(scheme: 'mailto', path: AppConfig.supportEmail),
                          ),
                        ),
                    ],
                  )
                : const Text(
                    'Support contact details have not been configured for this build.',
                    style: TextStyle(color: AppColors.muted),
                  ),
          ),
        ],
      ),
    );
  }
}
