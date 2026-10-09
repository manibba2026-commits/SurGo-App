import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Sign-in for an existing account, checked against the local seed in
/// [AppState]. Phone or email is accepted as the identifier.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final identifierCtrl = TextEditingController();
  final passwordCtrl = TextEditingController();
  bool _showPassword = false;
  bool _submitting = false;
  String? _socialLoading;
  String? _error;

  @override
  void dispose() {
    identifierCtrl.dispose();
    passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });

    final state = AppState.instance;
    if (!state.ready) await state.init();
    final result = state.login(identifierCtrl.text, passwordCtrl.text);
    if (!mounted) return;

    if (result != AuthResult.ok) {
      setState(() {
        _submitting = false;
        _error = result.message;
      });
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
  }

  /// Visual-only social sign-in: it signs the demo's primary account in through
  /// the normal path, so the rest of the app sees a real session.
  Future<void> _social(String provider) async {
    if (_socialLoading != null) return;
    setState(() {
      _socialLoading = provider;
      _error = null;
    });

    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    final state = AppState.instance;
    if (!state.ready) await state.init();
    if (state.db.accounts.isEmpty) {
      setState(() {
        _socialLoading = null;
        _error = 'No local accounts are available.';
      });
      return;
    }
    final demo = state.db.accounts.first;
    state.login(demo.phone, demo.password);
    if (!mounted) return;

    setState(() => _socialLoading = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Signed in with $provider as ${demo.name} (simulated)')),
    );
    Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return SbAuthScaffold(
      children: [
        const SizedBox(height: 22),
        const SbBrandLockup(),
        const SizedBox(height: 30),
        const SbAuthHeader(
          title: 'Welcome back',
          subtitle: 'Log in to book, ride, or rent today.',
        ),
        const SizedBox(height: 26),
        SbEditableField(
          label: 'Phone or email',
          controller: identifierCtrl,
          leading: const Icon(Icons.person_outline, size: 18, color: AppColors.text),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          hintText: '+63 9XX XXX XXXX or you@email.com',
        ),
        const SizedBox(height: 14),
        SbEditableField(
          label: 'Password',
          controller: passwordCtrl,
          leading: const Icon(Icons.lock_outline, size: 18, color: AppColors.text),
          obscureText: !_showPassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          hintText: 'Your password',
          suffix: SbPasswordToggle(
            visible: _showPassword,
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _submitting
                ? null
                : () => Navigator.pushNamed(context, '/forgot-password'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primaryLight,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
            child: const Text('Forgot password?'),
          ),
        ),
        const SizedBox(height: 6),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Logging in…' : 'Log in',
          onPressed: _submitting ? null : _submit,
        ),
        const SizedBox(height: 22),
        const SbOrDivider(),
        const SizedBox(height: 22),
        SbSocialButton(
          icon: const SbGoogleMark(),
          label: 'Continue with Google',
          glow: true,
          onPressed: _socialLoading == null ? () => _social('Google') : null,
        ),
        const SizedBox(height: 12),
        SbSocialButton(
          icon: const SbFacebookMark(),
          label: 'Continue with Facebook',
          onPressed: _socialLoading == null ? () => _social('Facebook') : null,
        ),
        const SizedBox(height: 24),
        SbAuthLink(
          prefix: 'No account?',
          action: 'Sign up',
          onPressed: _submitting
              ? null
              : () => Navigator.pushReplacementNamed(context, '/register'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
