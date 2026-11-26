import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_service.dart';
import '../../core/providers.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/google_button.dart';
import '../../core/widgets/vendor_widgets.dart';

String? validateEmail(String? v) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim())
    ? null
    : 'Enter a valid e-mail';
String? validatePassword(String? v) =>
    (v ?? '').length < 8 ? 'At least 8 characters' : null;

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title, subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.storefront, color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Cycle Vendor',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(color: context.palette.muted)),
                const SizedBox(height: 22),
                ...children,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: auth.status == AuthStatus.error
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.wifi_off_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      auth.message ?? 'Could not connect.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.primary,
                        minimumSize: const Size(160, 48),
                      ),
                      onPressed: () =>
                          ref.read(authControllerProvider.notifier).retry(),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              )
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.storefront, color: Colors.white, size: 72),
                  SizedBox(height: 16),
                  Text(
                    'Cycle Vendor',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text('Business app', style: TextStyle(color: Colors.white70)),
                  SizedBox(height: 28),
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 3,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Shown instead of crashing when the build has no Supabase configuration.
class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Padding(
      padding: EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.settings_suggest_outlined,
              size: 56,
              color: AppColors.warning,
            ),
            SizedBox(height: 14),
            Text(
              'App not configured',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 8),
            Text(
              'This build was made without SUPABASE_URL and SUPABASE_ANON_KEY.\nRebuild with --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=… (and API_BASE_URL).',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(), _password = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signIn(_email.text, _password.text);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Google signs in an existing account. The business role/approval gate is the same `/auth/me` check as a password sign-in.
  Future<void> _google() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).signInWithGoogle();
    } on AuthCancelled {
      // the user dismissed the Google chooser: not an error
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = ref.watch(authControllerProvider).message;
    return _AuthScaffold(
      title: 'Sign in to your business',
      subtitle: 'Manage products, orders and service bookings.',
      children: [
        if (notice != null) StatusBanner(notice),
        if (_error != null)
          StatusBanner(
            _error!,
            color: AppColors.danger,
            icon: Icons.error_outline,
          ),
        Form(
          key: _form,
          child: Column(
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'E-mail',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
                validator: validateEmail,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _password,
                obscureText: _hide,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
                validator: (v) =>
                    (v ?? '').isEmpty ? 'Enter your password' : null,
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => context.push('/forgot-password'),
            child: const Text('Forgot password?'),
          ),
        ),
        AppButton(label: 'Sign in', busy: _busy, onPressed: _submit),
        if (AppConfig.googleSignInSupported) ...[
          const OrDivider(),
          GoogleSignInButton(onPressed: _busy ? null : _google),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('New business?'),
            TextButton(
              onPressed: () => context.push('/register'),
              child: const Text('Create a vendor account'),
            ),
          ],
        ),
      ],
    );
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _email = TextEditingController(),
      _phone = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final signedIn = await ref
          .read(authControllerProvider.notifier)
          .signUp(
            email: _email.text,
            password: _password.text,
            fullName: _name.text,
            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          );
      if (!signedIn && mounted) {
        showSnack(
          context,
          'Account created. Confirm your e-mail, then sign in.',
        );
        context.go('/login');
      }
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: 'Create a vendor account',
    subtitle:
        'Step 1 of 2 — your login. Next you will submit your business details for verification.',
    children: [
      if (_error != null)
        StatusBanner(
          _error!,
          color: AppColors.danger,
          icon: Icons.error_outline,
        ),
      Form(
        key: _form,
        child: Column(
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your full name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (v) =>
                  (v ?? '').trim().length < 2 ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'E-mail',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: validateEmail,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number (optional)',
                hintText: '+919876543210',
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
              controller: _password,
              obscureText: _hide,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_hide ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _hide = !_hide),
                ),
              ),
              validator: validatePassword,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _confirm,
              obscureText: _hide,
              decoration: const InputDecoration(
                labelText: 'Confirm password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (v) =>
                  v == _password.text ? null : 'Passwords do not match',
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      AppButton(label: 'Create account', busy: _busy, onPressed: _submit),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Already registered?'),
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Sign in'),
          ),
        ],
      ),
    ],
  );
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _busy = false, _sent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).sendPasswordReset(_email.text);
      if (mounted) setState(() => _sent = true);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: 'Reset your password',
    subtitle: 'We will e-mail you a link to choose a new password.',
    children: [
      if (_sent)
        const StatusBanner(
          'If an account exists for that e-mail, a reset link is on its way.',
          color: AppColors.success,
          icon: Icons.mark_email_read_outlined,
        ),
      if (_error != null)
        StatusBanner(
          _error!,
          color: AppColors.danger,
          icon: Icons.error_outline,
        ),
      Form(
        key: _form,
        child: TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'E-mail',
            prefixIcon: Icon(Icons.mail_outline),
          ),
          validator: validateEmail,
        ),
      ),
      const SizedBox(height: 18),
      AppButton(label: 'Send reset link', busy: _busy, onPressed: _send),
      TextButton(
        onPressed: () => context.pop(),
        child: const Text('Back to sign in'),
      ),
    ],
  );
}

String get supportHint => AppConfig.supportEmail.isNotEmpty
    ? ' Contact ${AppConfig.supportEmail}.'
    : '';
