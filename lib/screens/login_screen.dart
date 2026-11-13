import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../auth/auth_models.dart';
import '../auth/phone_input.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Sign-in through Supabase Auth.
///
/// Phone is the primary path: the field and Login button sit above the
/// alternative methods. A successful request continues on the six-digit OTP
/// screen. Email opens its own password screen, the social providers complete
/// through their deep link, and the demo option opens the server-verified PIN
/// form. The layout deliberately keeps the alternative methods below the
/// primary phone login.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final phoneCtrl = TextEditingController();
  final pinCtrl = TextEditingController();
  bool _pinMode = false;
  bool _obscure = true;
  bool _submitting = false;
  bool _googleLoading = false;
  bool _facebookLoading = false;
  bool _navigated = false;
  String? _error;
  String? _phoneError;
  String? _pinError;

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
    pinCtrl.dispose();
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

    if (!state.ready) await state.init();

    final raw = phoneCtrl.text.trim();
    late final String phone;
    if (state.demoAuthEnabled) {
      final account = state.demoAccountFor(raw);
      if (account == null) {
        setState(() => _phoneError =
            'Enter a demo account number (for example ACC003) or a registered phone number.');
        return;
      }
      phone = normalizePhoneNumber(account.phone) ?? account.phone;
    } else {
      final normalized = normalizePhoneNumber(raw);
      if (normalized == null) {
        setState(() => _phoneError =
            'Enter a valid phone number, for example 0917 512 4809.');
        return;
      }
      phone = normalized;
    }

    setState(() {
      _submitting = true;
      _phoneError = null;
      _error = null;
    });

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

  Future<void> _submitPin() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final normalized = normalizePhoneNumber(phoneCtrl.text.trim());
    final pin = pinCtrl.text.trim();
    final pinInvalid = !RegExp(r'^\d{6}$').hasMatch(pin);
    if (normalized == null || pinInvalid) {
      setState(() {
        _phoneError = normalized == null
            ? 'Enter a valid phone number, for example 0917 000 0001.'
            : null;
        _pinError =
            pinInvalid ? 'Enter the 6-digit PIN for this account.' : null;
        _error = null;
      });
      return;
    }

    setState(() {
      _submitting = true;
      _phoneError = null;
      _pinError = null;
      _error = null;
    });

    final failure = await state.signInWithDemoPin(phone: normalized, pin: pin);
    if (!mounted) return;

    setState(() {
      _submitting = false;
      _error = failure?.message;
    });
    if (failure == null && state.isSignedIn) _finishSignedIn();
  }

  void _setPinMode(bool value) {
    if (_submitting) return;
    if (value) {
      // The phone form accepts an account number, while the demo form needs a
      // phone. Resolve it on the way in so a presentation tap is not lost.
      final account = state.demoAccountFor(phoneCtrl.text.trim());
      if (account != null) phoneCtrl.text = account.phone;
    }
    setState(() {
      _pinMode = value;
      _error = null;
      _phoneError = null;
      _pinError = null;
    });
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

  Future<void> _facebook() async {
    if (_facebookLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _facebookLoading = true;
      _error = null;
    });

    if (!state.ready) await state.init();
    final failure = await state.signInWithFacebook();
    if (!mounted) return;

    setState(() {
      _facebookLoading = false;
      _error = failure?.message;
    });
    if (state.isSignedIn) _finishSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _submitting || _googleLoading || _facebookLoading;
    return SbAuthScaffold(
      children: [
        const SizedBox(height: 22),
        const SbBrandLockup(),
        const SizedBox(height: 30),
        SbAuthHeader(
          title: _pinMode ? 'Demo sign-in' : 'Welcome back',
          subtitle: _pinMode
              ? 'Use the phone number and PIN issued for this demo account.'
              : 'Enter your phone number. We will text you a six-digit code.',
        ),
        const SizedBox(height: 26),
        if (_pinMode) ...[
          SbAuthField(
            label: 'Demo phone number',
            controller: phoneCtrl,
            icon: Icons.phone_outlined,
            errorText: _phoneError,
            keyboardType: TextInputType.phone,
            inputFormatters: [phPhoneInputFormatter],
            textInputAction: TextInputAction.next,
            enabled: !busy,
            onChanged: (_) {
              if (_phoneError != null) setState(() => _phoneError = null);
            },
          ),
          const SizedBox(height: 12),
          SbAuthField(
            label: 'Demo PIN',
            controller: pinCtrl,
            icon: Icons.lock_outline,
            errorText: _pinError,
            obscureText: _obscure,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            textInputAction: TextInputAction.done,
            enabled: !busy,
            suffix: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
                color: AppColors.muted,
              ),
              onPressed:
                  busy ? null : () => setState(() => _obscure = !_obscure),
              tooltip: _obscure ? 'Show PIN' : 'Hide PIN',
            ),
            onChanged: (_) {
              if (_pinError != null) setState(() => _pinError = null);
            },
            onSubmitted: (_) => _submitPin(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: busy ? null : () => _setPinMode(false),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primaryLight,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                textStyle: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              child: const Text('Use a phone number instead'),
            ),
          ),
        ] else ...[
          SbAuthField(
            label: 'Phone Number',
            controller: phoneCtrl,
            icon: Icons.phone_outlined,
            errorText: _phoneError,
            keyboardType: state.demoAuthEnabled
                ? TextInputType.text
                : TextInputType.phone,
            inputFormatters:
                state.demoAuthEnabled ? null : [phPhoneInputFormatter],
            autofillHints: state.demoAuthEnabled
                ? null
                : const [AutofillHints.telephoneNumber],
            textInputAction: TextInputAction.done,
            enabled: !busy,
            onChanged: (_) {
              if (_phoneError != null) setState(() => _phoneError = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          Row(
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pushNamed(context, '/email-login'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryLight,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  textStyle: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                child: const Text('Login with Email'),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pushNamed(context, '/forgot-password'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryLight,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  textStyle: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                child: const Text('Trouble signing in?'),
              ),
            ],
          ),
        ],
        if (!state.authAvailable)
          const SbAuthError(
            message:
                'Sign-in is unavailable right now. Check your connection and restart SurGo.',
          ),
        SbAuthError(message: _error),
        const SizedBox(height: 6),
        SbPrimaryButton(
          label: _pinMode
              ? (_submitting ? 'Signing in…' : 'Sign in')
              : (_submitting ? 'Sending code…' : 'Login'),
          onPressed: busy ? null : (_pinMode ? _submitPin : _submit),
        ),
        const SizedBox(height: 22),
        const SbOrDivider(),
        const SizedBox(height: 18),
        SbSocialButton(
          icon: const SbGoogleMark(),
          label: _googleLoading ? 'Opening Google…' : 'Continue with Google',
          glow: true,
          onPressed: busy ? null : _google,
        ),
        const SizedBox(height: 12),
        SbSocialButton(
          icon: const SbFacebookMark(),
          label:
              _facebookLoading ? 'Opening Facebook…' : 'Continue with Facebook',
          onPressed: busy ? null : _facebook,
        ),
        if (!_pinMode) ...[
          const SizedBox(height: 12),
          SbSocialButton(
            icon: const Icon(
              Icons.badge_outlined,
              size: 18,
              color: AppColors.secondary,
            ),
            label: 'Continue with Demo',
            onPressed: busy ? null : () => _setPinMode(true),
          ),
        ],
        const SizedBox(height: 22),
        SbAuthLink(
          prefix: 'No account?',
          action: 'Sign up',
          onPressed: busy
              ? null
              : () => Navigator.pushReplacementNamed(context, '/register'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
