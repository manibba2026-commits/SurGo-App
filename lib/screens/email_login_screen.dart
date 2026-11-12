import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Email/password sign-in and sign-up for the hosted Supabase project.
///
/// SurGo's phone flow stays passwordless. Email is the one credential type the
/// existing admin account already has, so this screen offers both an existing
/// account sign-in and a new account sign-up. When the project requires email
/// confirmation the screen explains that instead of pretending a session
/// exists.
class EmailLoginScreen extends StatefulWidget {
  const EmailLoginScreen({super.key});

  @override
  State<EmailLoginScreen> createState() => _EmailLoginScreenState();
}

class _EmailLoginScreenState extends State<EmailLoginScreen> {
  final emailCtrl = TextEditingController();
  final passwordCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  final nameCtrl = TextEditingController();

  bool _creating = false;
  bool _submitting = false;
  bool _obscure = true;
  bool _navigated = false;
  String? _error;
  String? _notice;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;
  String? _nameError;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    state.addListener(_onAuthStateChanged);
  }

  @override
  void dispose() {
    state.removeListener(_onAuthStateChanged);
    emailCtrl.dispose();
    passwordCtrl.dispose();
    confirmCtrl.dispose();
    nameCtrl.dispose();
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

  void _setCreating(bool value) {
    if (_submitting) return;
    setState(() {
      _creating = value;
      _error = null;
      _notice = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
      _nameError = null;
      passwordCtrl.clear();
      confirmCtrl.clear();
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final email = emailCtrl.text.trim();
    final password = passwordCtrl.text;
    final name = nameCtrl.text.trim();
    final emailError = emailFieldError(email);
    final passwordError = passwordFieldError(password, creating: _creating);
    final nameError =
        _creating && name.isEmpty ? 'Enter your full name.' : null;
    final confirmError = _creating && confirmCtrl.text != password
        ? 'The passwords do not match.'
        : null;

    if (emailError != null ||
        passwordError != null ||
        nameError != null ||
        confirmError != null) {
      setState(() {
        _emailError = emailError;
        _passwordError = passwordError;
        _nameError = nameError;
        _confirmError = confirmError;
        _error = null;
        _notice = null;
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
      _nameError = null;
    });

    if (!state.ready) await state.init();
    final failure = _creating
        ? await state.signUpWithEmail(
            email: email,
            password: password,
            fullName: name,
          )
        : await state.signInWithEmail(email: email, password: password);
    if (!mounted) return;

    setState(() {
      _submitting = false;
      _error = failure?.message;
      if (_creating && failure == null && !state.isSignedIn) {
        _notice = 'Check $email for the confirmation link, then return to '
            'SurGo and sign in.';
      }
    });
    if (failure == null && state.isSignedIn) _finishSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _submitting;
    return SbAuthScaffold(
      leading: IconButton(
        onPressed: busy ? null : () => Navigator.maybePop(context),
        icon: const Icon(Icons.arrow_back, color: AppColors.text),
        tooltip: 'Back',
      ),
      children: [
        const SizedBox(height: 8),
        const SbBrandLockup(logoSize: 52),
        const SizedBox(height: 24),
        SbAuthHeader(
          title: _creating ? 'Create with email' : 'Sign in with email',
          subtitle: _creating
              ? 'Use an email and password. We will ask for a phone number next.'
              : 'Use the email and password for your SurGo account.',
        ),
        const SizedBox(height: 24),
        if (_creating) ...[
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
          const SizedBox(height: 12),
        ],
        SbAuthField(
          label: 'Email address',
          controller: emailCtrl,
          icon: Icons.mail_outline,
          errorText: _emailError,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          enabled: !busy,
          onChanged: (_) {
            if (_emailError != null) setState(() => _emailError = null);
          },
        ),
        const SizedBox(height: 12),
        SbAuthField(
          label: 'Password',
          controller: passwordCtrl,
          icon: Icons.lock_outline,
          errorText: _passwordError,
          obscureText: _obscure,
          textInputAction:
              _creating ? TextInputAction.next : TextInputAction.done,
          autofillHints: [
            _creating ? AutofillHints.newPassword : AutofillHints.password,
          ],
          enabled: !busy,
          suffix: IconButton(
            icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 18,
              color: AppColors.muted,
            ),
            onPressed: busy ? null : () => setState(() => _obscure = !_obscure),
            tooltip: _obscure ? 'Show password' : 'Hide password',
          ),
          onChanged: (_) {
            if (_passwordError != null) setState(() => _passwordError = null);
          },
          onSubmitted: _creating ? null : (_) => _submit(),
        ),
        if (_creating) ...[
          const SizedBox(height: 12),
          SbAuthField(
            label: 'Confirm password',
            controller: confirmCtrl,
            icon: Icons.lock_outline,
            errorText: _confirmError,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            enabled: !busy,
            onChanged: (_) {
              if (_confirmError != null) {
                setState(() => _confirmError = null);
              }
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.mark_email_read_outlined,
                size: 16,
                color: AppColors.success,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _notice!,
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting
              ? (_creating ? 'Creating account…' : 'Signing in…')
              : (_creating ? 'Create account' : 'Sign in'),
          onPressed: busy ? null : _submit,
        ),
        const SizedBox(height: 18),
        SbAuthLink(
          prefix: _creating ? 'Already have an account?' : 'New to SurGo?',
          action: _creating ? 'Sign in' : 'Create account',
          onPressed: busy ? null : () => _setCreating(!_creating),
        ),
        const SizedBox(height: 12),
        SbAuthLink(
          prefix: 'Prefer another method?',
          action: 'Go back',
          onPressed: busy ? null : () => Navigator.maybePop(context),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Validation shared by the email screen and its tests.
String? emailFieldError(String raw) {
  final email = raw.trim();
  if (email.isEmpty) return 'Enter your email address.';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? passwordFieldError(String raw, {bool creating = false}) {
  if (raw.isEmpty) return 'Enter your password.';
  if (creating && raw.length < 8) {
    return 'Use a password with at least 8 characters.';
  }
  return null;
}
