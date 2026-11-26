import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import '../settings/avatar.dart';
import '../settings/screens.dart' show saveAvatarPath;

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).me;
    final p = me?.profile;
    Widget tile(
      IconData icon,
      String title,
      String route, {
      String? subtitle,
    }) => ListTile(
      leading: Icon(icon, color: context.palette.primary),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(route),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Account settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            color: context.palette.surface,
            child: Row(
              children: [
                UserAvatar(name: p?.fullName ?? '', path: p?.avatarPath),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p?.fullName.isNotEmpty == true
                            ? p!.fullName
                            : 'Your account',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if ((me?.email ?? '').isNotEmpty)
                        Text(
                          me!.email!,
                          style: TextStyle(color: context.palette.muted),
                        ),
                      if ((p?.phone ?? me?.phone ?? '').isNotEmpty)
                        Text(
                          p?.phone ?? me!.phone!,
                          style: TextStyle(color: context.palette.muted),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit profile',
                  onPressed: () => context.push('/profile/edit'),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: context.palette.surface,
            child: Column(
              children: [
                tile(Icons.receipt_long_outlined, 'My orders', '/orders'),
                const Divider(height: 1, indent: 56),
                tile(
                  Icons.event_note_outlined,
                  'My service bookings',
                  '/bookings',
                ),
                const Divider(height: 1, indent: 56),
                tile(
                  Icons.location_on_outlined,
                  'Saved addresses',
                  '/addresses',
                ),
                const Divider(height: 1, indent: 56),
                tile(
                  Icons.notifications_none,
                  'Notifications',
                  '/notifications',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: context.palette.surface,
            child: Column(
              children: [
                tile(
                  Icons.settings_outlined,
                  'Account settings',
                  '/settings',
                  subtitle: 'Profile, appearance, password',
                ),
                const Divider(height: 1, indent: 56),
                tile(Icons.support_agent, 'Help & support', '/support'),
                const Divider(height: 1, indent: 56),
                ListTile(
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
                          'You will need to sign in again to see your orders and bookings.',
                      confirmLabel: 'Log out',
                      destructive: true,
                    )) {
                      await ref.read(authControllerProvider.notifier).signOut();
                    }
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Cycle Marketplace',
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});
  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _phone;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = ref.read(authControllerProvider).me?.profile;
    _name = TextEditingController(text: p?.fullName ?? '');
    _phone = TextEditingController(text: p?.phone ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final me = ref.read(authControllerProvider).me!;
    setState(() => _busy = true);
    try {
      final newPhone = _phone.text.trim();
      // phone is only sent when it changed (a phone verified by sign-in cannot be edited here; the backend says so)
      await ref
          .read(profileRepositoryProvider)
          .update(
            fullName: _name.text.trim(),
            phone: newPhone != (me.profile.phone ?? '') && newPhone.isNotEmpty
                ? newPhone
                : null,
          );
      await ref.read(authControllerProvider.notifier).refreshMe();
      if (mounted) {
        showSnack(context, 'Profile updated');
        context.pop();
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).me;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (me != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                child: Center(
                  child: AvatarEditor(
                    userId: me.id,
                    name: me.profile.fullName,
                    path: me.profile.avatarPath,
                    onUploaded: (path) => saveAvatarPath(ref, path),
                  ),
                ),
              ),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Full name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (v) =>
                  (v ?? '').trim().length < 2 ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ||
                      RegExp(r'^\+?[0-9]{7,15}$').hasMatch(v!.trim())
                  ? null
                  : 'Enter 7-15 digits',
            ),
            const SizedBox(height: 14),
            TextFormField(
              initialValue: me?.email ?? '',
              enabled: false,
              decoration: const InputDecoration(
                labelText: 'E-mail',
                prefixIcon: Icon(Icons.mail_outline),
                helperText: 'Your sign-in e-mail cannot be changed here.',
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
