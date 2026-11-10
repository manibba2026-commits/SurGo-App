import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../auth/demo_auth.dart';
import '../auth/phone_input.dart';
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

  Widget _demoAccountsCard() {
    final accounts = state.demoLoginAccounts;
    if (accounts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'DEMO ACCOUNTS',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 2),
            for (final account in accounts)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _submitting
                    ? null
                    : () => setState(() {
                          phoneCtrl.text = account.id;
                          _error = null;
                          _phoneError = null;
                        }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Text(
                        account.id,
                        style: const TextStyle(
                          color: AppColors.primaryLight,
                          fontWeight: FontWeight.w800,
                          fontSize: 11.5,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          account.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        demoAccountRefFor(account.id)?.roleLabel ?? '',
                        style: const TextStyle(
                          color: AppColors.muted2,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
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
        SbAuthField(
          label:
              state.demoAuthEnabled ? 'Phone or account number' : 'Phone number',
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
        if (state.demoAuthEnabled) _demoAccountsCard(),
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
