import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_service.dart';
import '../../core/providers.dart';
import '../../core/widgets/cards_export.dart';
import '../business_profile/screens.dart' show humanizeStatus;
import 'avatar.dart';
import 'theme_mode.dart';

/// "Use at least 8 characters" is the same rule as sign-up. The new password must differ from the current one.
String? validateNewPassword(String? value, {String? current}) {
  final v = value ?? '';
  if (v.isEmpty) return 'Enter a new password';
  if (v.length < 8) return 'Use at least 8 characters';
  if (current != null && current.isNotEmpty && v == current) {
    return 'Choose a password you have not used here before';
  }
  return null;
}

String? validateConfirmPassword(String? value, String newPassword) {
  if ((value ?? '').isEmpty) return 'Confirm your new password';
  return value != newPassword ? 'Passwords do not match' : null;
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: .6,
          ),
        ),
      ),
      Container(
        color: context.palette.surface,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 56),
              children[i],
            ],
          ],
        ),
      ),
    ],
  );
}

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
      leading: Icon(icon, color: context.palette.primary),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(route),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'),
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
                UserAvatar(
                  name: (auth.me?.fullName ?? '').isNotEmpty
                      ? auth.me!.fullName
                      : (v?.businessName ?? ''),
                  path: auth.me?.avatarPath,
                  radius: 28,
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
                        style: TextStyle(color: context.palette.muted),
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
            color: context.palette.surface,
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
            color: context.palette.surface,
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
            color: context.palette.surface,
            child: Column(
              children: [
                tile(
                  Icons.notifications_none,
                  'Notifications',
                  '/notifications',
                ),
                const Divider(height: 1, indent: 56),
                tile(
                  Icons.settings_outlined,
                  'Account settings',
                  '/settings',
                  subtitle: 'Profile, appearance, password',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            color: context.palette.surface,
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
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Cycle Marketplace · Vendor',
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The vendor's account settings: profile, business shortcut, appearance, security and support. Business details themselves are NOT
/// duplicated here; the existing business profile screens own them.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final me = auth.me;
    final v = auth.vendor;
    final mode = ref.watch(themeModeProvider);
    final name = me?.fullName ?? '';
    final phone = me?.profilePhone ?? me?.phone ?? '';
    final hasSupport =
        AppConfig.supportEmail.isNotEmpty || AppConfig.supportPhone.isNotEmpty;

    Widget detail(IconData icon, String label, String value) => ListTile(
      leading: Icon(icon, color: context.palette.primary),
      title: Text(label),
      trailing: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .55,
        ),
        child: Text(
          value.isEmpty ? '—' : value,
          textAlign: TextAlign.end,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.palette.muted),
        ),
      ),
    );

    Widget themeTile(ThemeMode m, IconData icon, String label) =>
        RadioListTile<ThemeMode>(
          value: m,
          secondary: Icon(icon, color: context.palette.primary),
          title: Text(label),
          activeColor: context.palette.primary,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Account settings')),
      body: me == null
          ? const LoadingView()
          : ListView(
              children: [
                Container(
                  color: context.palette.surface,
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    children: [
                      AvatarEditor(
                        userId: me.id,
                        name: name.isNotEmpty ? name : (v?.businessName ?? ''),
                        path: me.avatarPath,
                        onUploaded: (path) => saveAvatarPath(ref, path),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        name.isEmpty ? 'Your account' : name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if ((me.email ?? '').isNotEmpty)
                        Text(
                          me.email!,
                          style: TextStyle(color: context.palette.muted),
                        ),
                    ],
                  ),
                ),
                SettingsSection(
                  title: 'Profile',
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.person_outline,
                        color: context.palette.primary,
                      ),
                      title: const Text('Edit profile'),
                      subtitle: const Text('Name, mobile number, picture'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/settings/profile'),
                    ),
                    detail(Icons.badge_outlined, 'Name', name),
                    detail(Icons.mail_outline, 'E-mail', me.email ?? ''),
                    detail(Icons.phone_outlined, 'Mobile', phone),
                    detail(
                      Icons.verified_user_outlined,
                      'Account type',
                      'Vendor',
                    ),
                    detail(
                      Icons.fact_check_outlined,
                      'Verification',
                      humanizeStatus(v?.verificationStatus ?? 'not registered'),
                    ),
                  ],
                ),
                if (v != null)
                  SettingsSection(
                    title: 'Business',
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.storefront_outlined,
                          color: context.palette.primary,
                        ),
                        title: const Text('Business profile'),
                        subtitle: Text(
                          '${v.businessName} · name, contact, address, hours',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/business'),
                      ),
                    ],
                  ),
                RadioGroup<ThemeMode>(
                  groupValue: mode,
                  onChanged: (m) {
                    if (m != null) {
                      ref.read(themeModeProvider.notifier).set(m);
                    }
                  },
                  child: SettingsSection(
                    title: 'Appearance',
                    children: [
                      themeTile(
                        ThemeMode.system,
                        Icons.brightness_auto_outlined,
                        'System default',
                      ),
                      themeTile(
                        ThemeMode.light,
                        Icons.light_mode_outlined,
                        'Light',
                      ),
                      themeTile(
                        ThemeMode.dark,
                        Icons.dark_mode_outlined,
                        'Dark',
                      ),
                    ],
                  ),
                ),
                SettingsSection(
                  title: 'Security',
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.lock_outline,
                        color: context.palette.primary,
                      ),
                      title: const Text('Change password'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/settings/password'),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.logout,
                        color: AppColors.danger,
                      ),
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
                          await ref
                              .read(authControllerProvider.notifier)
                              .signOut();
                        }
                      },
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xl,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                  ),
                  child: Column(
                    children: [
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
                        child: hasSupport
                            ? Column(
                                children: [
                                  if (AppConfig.supportPhone.isNotEmpty)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: const Icon(Icons.phone_outlined),
                                      title: Text(AppConfig.supportPhone),
                                      onTap: () => launchUrl(
                                        Uri(
                                          scheme: 'tel',
                                          path: AppConfig.supportPhone,
                                        ),
                                      ),
                                    ),
                                  if (AppConfig.supportEmail.isNotEmpty)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: const Icon(Icons.mail_outline),
                                      title: Text(AppConfig.supportEmail),
                                      onTap: () => launchUrl(
                                        Uri(
                                          scheme: 'mailto',
                                          path: AppConfig.supportEmail,
                                        ),
                                      ),
                                    ),
                                ],
                              )
                            : Text(
                                'Support contact details have not been configured for this build.',
                                style: TextStyle(color: context.palette.muted),
                              ),
                      ),
                    ],
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
    final me = ref.read(authControllerProvider).me;
    _name = TextEditingController(text: me?.fullName ?? '');
    _phone = TextEditingController(text: me?.profilePhone ?? '');
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
            phone: newPhone != (me.profilePhone ?? '') && newPhone.isNotEmpty
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
                    name: me.fullName,
                    path: me.avatarPath,
                    onUploaded: (path) => saveAvatarPath(ref, path),
                  ),
                ),
              ),
            TextFormField(
              controller: _name,
              enabled: !_busy,
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
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                prefixIcon: Icon(Icons.phone_outlined),
                helperText:
                    'Your personal number. Business contact details are in Business profile.',
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

/// Saves a freshly uploaded picture on the profile (the backend checks it lives in the user's own folder) and refreshes the signed-in user.
Future<void> saveAvatarPath(WidgetRef ref, String path) async {
  await ref.read(profileRepositoryProvider).update(avatarPath: path);
  await ref.read(authControllerProvider.notifier).refreshMe();
}

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController(),
      _new = TextEditingController(),
      _confirm = TextEditingController();
  bool _showCurrent = false, _showNew = false, _showConfirm = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final email = ref.read(authControllerProvider).me?.email;
    if (email == null || email.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authServiceProvider)
          .changePassword(
            email: email,
            currentPassword: _current.text,
            newPassword: _new.text,
          );
      if (mounted) {
        showSnack(context, 'Password updated');
        context.pop();
      }
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not update your password. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required bool visible,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
    TextInputAction action = TextInputAction.next,
    VoidCallback? onSubmit,
  }) => TextFormField(
    controller: controller,
    obscureText: !visible,
    enabled: !_busy,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: action,
    onFieldSubmitted: onSubmit == null ? null : (_) => onSubmit(),
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Icons.lock_outline),
      suffixIcon: IconButton(
        tooltip: visible ? 'Hide password' : 'Show password',
        icon: Icon(visible ? Icons.visibility : Icons.visibility_off),
        onPressed: onToggle,
      ),
    ),
    validator: validator,
  );

  @override
  Widget build(BuildContext context) {
    final email = ref.watch(authControllerProvider).me?.email;
    final hasEmail = email != null && email.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: !hasEmail
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Text(
                'Your account signs in with a mobile number, so it has no password to change.',
              ),
            )
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  _field(
                    controller: _current,
                    label: 'Current password',
                    visible: _showCurrent,
                    onToggle: () =>
                        setState(() => _showCurrent = !_showCurrent),
                    validator: (v) => (v ?? '').isEmpty
                        ? 'Enter your current password'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  _field(
                    controller: _new,
                    label: 'New password',
                    visible: _showNew,
                    onToggle: () => setState(() => _showNew = !_showNew),
                    validator: (v) =>
                        validateNewPassword(v, current: _current.text),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                    child: Text(
                      'At least 8 characters.',
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _field(
                    controller: _confirm,
                    label: 'Confirm new password',
                    visible: _showConfirm,
                    onToggle: () =>
                        setState(() => _showConfirm = !_showConfirm),
                    validator: (v) => validateConfirmPassword(v, _new.text),
                    action: TextInputAction.done,
                    onSubmit: _submit,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Update password'),
                  ),
                ],
              ),
            ),
    );
  }
}
