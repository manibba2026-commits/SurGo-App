import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Creates a new account against the local seed. Registration always starts as
/// a passenger; rider and owner roles are added later from the profile.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final passwordCtrl = TextEditingController();
  bool _showPassword = false;
  bool _submitting = false;
  String? _socialLoading;
  String? _error;

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
    passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final name = nameCtrl.text.trim();
    final phone = phoneCtrl.text.trim();
    final email = emailCtrl.text.trim();
    final password = passwordCtrl.text;

    final complaint = _validate(name, phone, email, password);
    if (complaint != null) {
      setState(() => _error = complaint);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final state = AppState.instance;
    if (!state.ready) await state.init();
    final result = state.register(
      name: name,
      phone: phone,
      email: email,
      password: password,
    );
    if (!mounted) return;

    if (result != RegisterResult.ok) {
      setState(() {
        _submitting = false;
        _error = result.message;
      });
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
  }

  /// Client-side shape check before the seed lookup: it catches an empty or
  /// obviously malformed entry and says which one, rather than surfacing a
  /// generic "already registered".
  String? _validate(String name, String phone, String email, String password) {
    if (name.isEmpty) return 'Please enter your full name.';
    if (phone.isEmpty) return 'Please enter your phone number.';
    if (email.isEmpty || !email.contains('@')) {
      return 'Please enter a valid email address.';
    }
    if (password.length < 6) {
      return 'Use a password with at least 6 characters.';
    }
    return null;
  }

  /// Visual-only social sign-up, mirroring the login screen's demo shortcut.
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
      SnackBar(content: Text('Signed up with $provider as ${demo.name} (simulated)')),
    );
    Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return SbAuthScaffold(
      children: [
        const SizedBox(height: 12),
        const SbBrandLockup(logoSize: 52),
        const SizedBox(height: 26),
        const SbAuthHeader(
          title: 'Create your account',
          subtitle: 'Sign up to book rides, run errands, or rent out vehicles.',
        ),
        const SizedBox(height: 24),
        SbEditableField(
          label: 'Full name',
          controller: nameCtrl,
          leading: const Icon(Icons.badge_outlined, size: 18, color: AppColors.text),
          keyboardType: TextInputType.name,
          textInputAction: TextInputAction.next,
          hintText: 'Juan Dela Cruz',
        ),
        const SizedBox(height: 14),
        SbEditableField(
          label: 'Phone number',
          controller: phoneCtrl,
          leading: const Icon(Icons.phone, size: 18, color: AppColors.text),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          hintText: '+63 9XX XXX XXXX',
        ),
        const SizedBox(height: 14),
        SbEditableField(
          label: 'Email',
          controller: emailCtrl,
          leading: const Icon(Icons.mail_outline, size: 18, color: AppColors.text),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          hintText: 'you@email.com',
        ),
        const SizedBox(height: 14),
        SbEditableField(
          label: 'Password',
          controller: passwordCtrl,
          leading: const Icon(Icons.lock_outline, size: 18, color: AppColors.text),
          obscureText: !_showPassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          hintText: 'At least 6 characters',
          suffix: SbPasswordToggle(
            visible: _showPassword,
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
        const SizedBox(height: 18),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Creating account…' : 'Sign up',
          onPressed: _submitting ? null : _submit,
        ),
        const SizedBox(height: 22),
        const SbOrDivider(),
        const SizedBox(height: 22),
        SbSocialButton(
          icon: const SbGoogleMark(),
          label: 'Sign up with Google',
          glow: true,
          onPressed: _socialLoading == null ? () => _social('Google') : null,
        ),
        const SizedBox(height: 12),
        SbSocialButton(
          icon: const SbFacebookMark(),
          label: 'Sign up with Facebook',
          onPressed: _socialLoading == null ? () => _social('Facebook') : null,
        ),
        const SizedBox(height: 24),
        SbAuthLink(
          prefix: 'Already have an account?',
          action: 'Log in',
          onPressed: _submitting
              ? null
              : () => Navigator.pushReplacementNamed(context, '/login'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
