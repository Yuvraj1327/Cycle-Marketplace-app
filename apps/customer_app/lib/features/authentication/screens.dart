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

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.pedal_bike,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 20),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(subtitle, style: TextStyle(color: context.palette.muted)),
                const SizedBox(height: 24),
                child,
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
                  Icon(Icons.pedal_bike, color: Colors.white, size: 72),
                  SizedBox(height: 16),
                  Text(
                    'Cycle Marketplace',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
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

class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: EmptyState(
      icon: Icons.settings_suggest_outlined,
      title: 'App not configured',
      message:
          'SUPABASE_URL and SUPABASE_ANON_KEY were not provided at build time.\nRun with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... --dart-define=API_BASE_URL=...',
    ),
  );
}

String? _required(String? v, [String what = 'This field']) =>
    (v == null || v.trim().isEmpty) ? '$what is required' : null;
String? validateEmail(String? v) {
  if (v == null || v.trim().isEmpty) return 'E-mail is required';
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())
      ? null
      : 'Enter a valid e-mail address';
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _phone = TextEditingController(),
      _code = TextEditingController();
  bool _busy = false, _hide = true, _usePhone = false, _codeSent = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_email, _password, _phone, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return; // prevents double submission
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
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

  Future<void> _google() =>
      _run(() => ref.read(authControllerProvider.notifier).signInWithGoogle());

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_usePhone) {
      return _run(
        () => ref
            .read(authControllerProvider.notifier)
            .signIn(_email.text, _password.text),
      );
    }
    if (!_codeSent) {
      return _run(() async {
        await ref.read(authServiceProvider).sendPhoneOtp(_phone.text);
        setState(() => _codeSent = true);
      });
    }
    return _run(
      () => ref
          .read(authControllerProvider.notifier)
          .signInWithPhoneCode(_phone.text, _code.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notice = ref.watch(authControllerProvider).message;
    return _AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to buy cycles, parts and book servicing.',
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (notice != null) _Banner(notice, AppColors.warning),
            if (_error != null) _Banner(_error!, AppColors.danger),
            if (AppConfig.phoneAuthEnabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('E-mail'),
                      icon: Icon(Icons.mail_outline),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Mobile'),
                      icon: Icon(Icons.phone_android),
                    ),
                  ],
                  selected: {_usePhone},
                  onSelectionChanged: (s) => setState(() {
                    _usePhone = s.first;
                    _codeSent = false;
                    _error = null;
                  }),
                ),
              ),
            if (!_usePhone) ...[
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
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
                validator: (v) => _required(v, 'Password'),
                onFieldSubmitted: (_) => _submit(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.push('/forgot-password'),
                  child: const Text('Forgot password?'),
                ),
              ),
            ] else ...[
              TextFormField(
                controller: _phone,
                enabled: !_codeSent,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Mobile number (with country code)',
                  hintText: '+919876543210',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                validator: (v) =>
                    RegExp(r'^\+[0-9]{8,15}$').hasMatch((v ?? '').trim())
                    ? null
                    : 'Use international format, e.g. +919876543210',
              ),
              if (_codeSent) ...[
                const SizedBox(height: 14),
                TextFormField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'SMS code',
                    prefixIcon: Icon(Icons.sms_outlined),
                  ),
                  validator: (v) => _required(v, 'The code'),
                ),
              ],
              const SizedBox(height: 12),
            ],
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
                  : Text(
                      _usePhone
                          ? (_codeSent ? 'Verify & sign in' : 'Send code')
                          : 'Sign in',
                    ),
            ),
            if (AppConfig.googleSignInSupported) ...[
              const OrDivider(),
              GoogleSignInButton(onPressed: _busy ? null : _google),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('New here?'),
                TextButton(
                  onPressed: () => context.push('/register'),
                  child: const Text('Create an account'),
                ),
              ],
            ),
          ],
        ),
      ),
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
            phone: _phone.text.trim(),
          );
      if (!mounted) return;
      if (!signedIn) {
        showSnack(
          context,
          'Account created. Please confirm your e-mail, then sign in.',
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

  /// Google creates the account on first use and signs in on later uses, so "sign up" and "sign in" are the same call.
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
  Widget build(BuildContext context) => _AuthScaffold(
    title: 'Create your account',
    subtitle: 'It takes a minute. You can add delivery addresses later.',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) _Banner(_error!, AppColors.danger),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Full name',
              prefixIcon: Icon(Icons.person_outline),
            ),
            validator: (v) =>
                (v ?? '').trim().length < 2 ? 'Enter your full name' : null,
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
                : 'Enter digits only, 7-15 long',
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _password,
            obscureText: _hide,
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: 'At least 8 characters',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
            validator: (v) =>
                (v ?? '').length < 8 ? 'Use at least 8 characters' : null,
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
                v != _password.text ? 'Passwords do not match' : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
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
                : const Text('Create account'),
          ),
          if (AppConfig.googleSignInSupported) ...[
            const OrDivider(),
            GoogleSignInButton(
              label: 'Sign up with Google',
              onPressed: _busy ? null : _google,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Already registered?'),
              TextButton(
                onPressed: () => context.go('/login'),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ],
      ),
    ),
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

  Future<void> _submit() async {
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: _sent
        ? EmptyState(
            icon: Icons.mark_email_read_outlined,
            title: 'Check your inbox',
            message:
                'If ${_email.text.trim()} has an account, a reset link is on its way.',
            actionLabel: 'Back to sign in',
            onAction: () => context.go('/login'),
          )
        : Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Reset password',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your e-mail and we will send you a reset link.',
                    style: TextStyle(color: context.palette.muted),
                  ),
                  const SizedBox(height: 20),
                  if (_error != null) _Banner(_error!, AppColors.danger),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'E-mail',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                    validator: validateEmail,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('Send reset link'),
                  ),
                ],
              ),
            ),
          ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .4)),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
