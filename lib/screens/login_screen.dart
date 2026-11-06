import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Sign-in through Supabase Auth: a phone one-time code or Google.
///
/// The screen never sees a password. A successful phone request continues on
/// the OTP screen; Google completes through the provider's deep link and is
/// applied by [AppState]'s auth-state listener.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final phoneCtrl = TextEditingController();
  bool _submitting = false;
  bool _googleLoading = false;
  bool _navigated = false;
  String? _error;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    state.addListener(_onAuthStateChanged);
  }

  @override
  void dispose() {
    state.removeListener(_onAuthStateChanged);
    phoneCtrl.dispose();
    super.dispose();
  }

  void _onAuthStateChanged() {
    if (!mounted || _navigated || !state.isSignedIn) return;
    _finishSignedIn();
  }

  void _finishSignedIn() {
    if (_navigated) return;
    _navigated = true;
    Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final phone = normalizePhoneNumber(phoneCtrl.text);
    if (phone == null) {
      setState(() => _error =
          'Enter a valid phone number, for example 0917 512 4809.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    if (!state.ready) await state.init();
    final failure = await state.sendPhoneOtp(phone: phone);
    if (!mounted) return;

    if (failure != null) {
      setState(() {
        _submitting = false;
        _error = failure.message;
      });
      return;
    }

    setState(() => _submitting = false);
    Navigator.pushNamed(
      context,
      '/otp',
      arguments: {'phone': phone, 'mode': 'login'},
    );
  }

  Future<void> _google() async {
    if (_googleLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _googleLoading = true;
      _error = null;
    });

    if (!state.ready) await state.init();
    final failure = await state.signInWithGoogle();
    if (!mounted) return;

    setState(() {
      _googleLoading = false;
      _error = failure?.message;
    });
    if (state.isSignedIn) _finishSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _submitting || _googleLoading;
    return SbAuthScaffold(
      children: [
        const SizedBox(height: 22),
        const SbBrandLockup(),
        const SizedBox(height: 30),
        const SbAuthHeader(
          title: 'Welcome back',
          subtitle: 'We will text you a one-time code. No password needed.',
        ),
        const SizedBox(height: 26),
        SbEditableField(
          label: 'Phone number',
          controller: phoneCtrl,
          leading: const Icon(Icons.phone, size: 18, color: AppColors.text),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          hintText: '+63 9XX XXX XXXX',
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: busy
                ? null
                : () => Navigator.pushNamed(context, '/forgot-password'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primaryLight,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              textStyle:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
            child: const Text('Trouble signing in?'),
          ),
        ),
        const SizedBox(height: 6),
        if (!state.authAvailable)
          const SbAuthError(
            message:
                'Sign-in is unavailable right now. Check your connection and restart SurGo.',
          ),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Sending code…' : 'Send code',
          onPressed: busy ? null : _submit,
        ),
        const SizedBox(height: 22),
        const SbOrDivider(),
        const SizedBox(height: 22),
        SbSocialButton(
          icon: const SbGoogleMark(),
          label: _googleLoading ? 'Opening Google…' : 'Continue with Google',
          glow: true,
          onPressed: busy ? null : _google,
        ),
        const SizedBox(height: 24),
        SbAuthLink(
          prefix: 'No account?',
          action: 'Sign up',
          onPressed:
              busy ? null : () => Navigator.pushReplacementNamed(context, '/register'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
