import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_service.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/common.dart';
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

class AccountSettingsScreen extends ConsumerWidget {
  const AccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).me;
    final p = me?.profile;
    final mode = ref.watch(themeModeProvider);
    final name = p?.fullName ?? '';
    final phone = (p?.phone ?? me?.phone ?? '');

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
                        name: name,
                        path: p?.avatarPath,
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
                      onTap: () => context.push('/profile/edit'),
                    ),
                    detail(Icons.badge_outlined, 'Name', name),
                    detail(Icons.mail_outline, 'E-mail', me.email ?? ''),
                    detail(Icons.phone_outlined, 'Mobile', phone),
                    detail(
                      Icons.verified_user_outlined,
                      'Account type',
                      'Customer',
                    ),
                    detail(
                      Icons.check_circle_outline,
                      'Status',
                      humanize(me.status),
                    ),
                  ],
                ),
                RadioGroup<ThemeMode>(
                  groupValue: mode,
                  onChanged: (v) {
                    if (v != null) ref.read(themeModeProvider.notifier).set(v);
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
                              'You will need to sign in again to see your orders and bookings.',
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
                const SizedBox(height: 32),
              ],
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
