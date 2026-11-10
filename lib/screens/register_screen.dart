import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../auth/phone_input.dart';
import '../state/app_state.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Creates a Supabase account from a phone one-time code or Google.
///
/// New accounts start as passengers; earner and vehicle-owner roles are added
/// later by the verification flow.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  bool _submitting = false;
  bool _googleLoading = false;
  bool _navigated = false;
  String? _error;
  String? _nameError;
  String? _phoneError;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    state.addListener(_onAuthStateChanged);
  }

  @override
  void dispose() {
    state.removeListener(_onAuthStateChanged);
    nameCtrl.dispose();
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
    Navigator.pushNamedAndRemoveUntil(
      context,
      state.requiresOnboarding
          ? '/onboarding'
          : state.requiresPin
              ? '/pin'
              : state.homeRoute,
      (r) => false,
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final name = nameCtrl.text.trim();
    final nameError = name.isEmpty ? 'Please enter your full name.' : null;
    final phoneError = phoneFieldError(phoneCtrl.text);
    if (nameError != null || phoneError != null) {
      setState(() {
        _nameError = nameError;
        _phoneError = phoneError;
        _error = null;
      });
      return;
    }
    final phone = normalizePhoneNumber(phoneCtrl.text)!;

    setState(() {
      _submitting = true;
      _nameError = null;
      _phoneError = null;
      _error = null;
    });

    if (!state.ready) await state.init();
    final failure = await state.sendPhoneOtp(
      phone: phone,
      fullName: name,
      createUser: true,
    );
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
      arguments: {'phone': phone, 'mode': 'register', 'name': name},
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
        const SizedBox(height: 12),
        const SbBrandLockup(logoSize: 52),
        const SizedBox(height: 26),
        const SbAuthHeader(
          title: 'Create your account',
          subtitle: 'Sign up with your phone number. We will text a code.',
        ),
        const SizedBox(height: 24),
        SbAuthField(
          label: 'Full name',
          controller: nameCtrl,
          icon: Icons.badge_outlined,
          errorText: _nameError,
          keyboardType: TextInputType.name,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.name],
          enabled: !busy,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
        ),
        const SizedBox(height: 14),
        SbAuthField(
          label: 'Phone number',
          controller: phoneCtrl,
          icon: Icons.phone_outlined,
          errorText: _phoneError,
          keyboardType: TextInputType.phone,
          inputFormatters: [phPhoneInputFormatter],
          autofillHints: const [AutofillHints.telephoneNumber],
          textInputAction: TextInputAction.done,
          enabled: !busy,
          onChanged: (_) {
            if (_phoneError != null) setState(() => _phoneError = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 18),
        if (!state.authAvailable)
          const SbAuthError(
            message:
                'Sign-in is unavailable right now. Check your connection and restart SurGo.',
          ),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Sending code…' : 'Sign up',
          onPressed: busy ? null : _submit,
        ),
        const SizedBox(height: 22),
        const SbOrDivider(),
        const SizedBox(height: 22),
        SbSocialButton(
          icon: const SbGoogleMark(),
          label: _googleLoading ? 'Opening Google…' : 'Sign up with Google',
          glow: true,
          onPressed: busy ? null : _google,
        ),
        const SizedBox(height: 24),
        SbAuthLink(
          prefix: 'Already have an account?',
          action: 'Log in',
          onPressed: busy
              ? null
              : () => Navigator.pushReplacementNamed(context, '/login'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
