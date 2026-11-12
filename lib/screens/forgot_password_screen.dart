import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../auth/auth_repository.dart';
import '../auth/phone_input.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';
import 'email_login_screen.dart' show emailFieldError;

/// Phone recovery stays the default. Email recovery is offered only when the
/// caller resolves the optional hosted capability; requesting a link does not
/// sign in or change a password locally.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.recoveryResolver});

  final EmailRecoveryRepository? Function()? recoveryResolver;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  static const _emailNotice =
      'If an account exists for that email address, '
      'check your email for a password reset link.';

  final phoneCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  bool _emailMode = false;
  bool _submitting = false;
  String? _error;
  String? _phoneError;
  String? _emailError;
  String? _notice;

  EmailRecoveryRepository? _resolveRecovery() {
    try {
      return widget.recoveryResolver?.call();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    phoneCtrl.dispose();
    emailCtrl.dispose();
    super.dispose();
  }

  void _toggleMode() {
    if (_submitting || (!_emailMode && _resolveRecovery() == null)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _emailMode = !_emailMode;
      _error = null;
      _phoneError = null;
      _emailError = null;
      _notice = null;
    });
  }

  Future<void> _submitEmail() async {
    final email = emailCtrl.text.trim();
    final emailError = emailFieldError(email);
    if (emailError != null) {
      setState(() {
        _emailError = emailError;
        _error = null;
        _notice = null;
      });
      return;
    }

    setState(() {
      _submitting = true;
      _emailError = null;
      _error = null;
      _notice = null;
    });
    try {
      final recovery = _resolveRecovery();
      if (recovery == null) {
        throw const AuthFailure(
          AuthFailureCode.providerUnavailable,
          'Email recovery is unavailable right now. Please try again later.',
        );
      }
      await recovery.requestPasswordReset(email);
      if (!mounted) return;
      setState(() => _notice = _emailNotice);
    } catch (error) {
      if (!mounted) return;
      final failure = AuthFailure.from(error);
      // Account-specific failures must not reveal whether an email is on file.
      switch (failure.code) {
        case AuthFailureCode.noAccount:
        case AuthFailureCode.accountUnavailable:
        case AuthFailureCode.emailInUse:
        case AuthFailureCode.emailNotConfirmed:
        case AuthFailureCode.invalidCredentials:
          setState(() => _notice = _emailNotice);
        default:
          setState(
            () => _error = failure.code == AuthFailureCode.unknown
                ? 'Password recovery could not be requested. Please try again.'
                : failure.message,
          );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    if (_emailMode) {
      await _submitEmail();
      return;
    }

    final phoneError = phoneFieldError(phoneCtrl.text);
    if (phoneError != null) {
      setState(() {
        _phoneError = phoneError;
        _error = null;
      });
      return;
    }
    final phone = normalizePhoneNumber(phoneCtrl.text)!;

    setState(() {
      _submitting = true;
      _phoneError = null;
      _error = null;
    });

    final state = AppState.instance;
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
      arguments: {'phone': phone, 'mode': 'recovery'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final emailAvailable = _resolveRecovery() != null;
    return SbAuthScaffold(
      leading: IconButton(
        onPressed: _submitting ? null : () => Navigator.maybePop(context),
        icon: const Icon(Icons.arrow_back, color: AppColors.text),
        tooltip: 'Back to log in',
      ),
      children: [
        const SizedBox(height: 12),
        const SbBrandLockup(logoSize: 52),
        const SizedBox(height: 26),
        SbAuthHeader(
          title: 'Recover your account',
          subtitle: _emailMode
              ? 'Enter your account email to request a password reset link.'
              : 'Enter the phone number on your account and we will text you a code to sign in.',
        ),
        const SizedBox(height: 24),
        if (_emailMode)
          SbAuthField(
            key: const ValueKey('recovery-email'),
            label: 'Email address',
            controller: emailCtrl,
            icon: Icons.mail_outline,
            errorText: _emailError,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.done,
            enabled: !_submitting,
            onChanged: (_) {
              if (_emailError != null || _notice != null) {
                setState(() {
                  _emailError = null;
                  _notice = null;
                });
              }
            },
            onSubmitted: (_) => _submit(),
          )
        else
          SbAuthField(
            key: const ValueKey('recovery-phone'),
            label: 'Phone number',
            controller: phoneCtrl,
            icon: Icons.phone_outlined,
            errorText: _phoneError,
            keyboardType: TextInputType.phone,
            inputFormatters: [phPhoneInputFormatter],
            autofillHints: const [AutofillHints.telephoneNumber],
            textInputAction: TextInputAction.done,
            enabled: !_submitting,
            onChanged: (_) {
              if (_phoneError != null) setState(() => _phoneError = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        const SizedBox(height: 18),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _notice!,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _emailMode
              ? (_submitting ? 'Requesting link…' : 'Send reset link')
              : (_submitting ? 'Sending code…' : 'Send code'),
          onPressed: _submitting ? null : _submit,
        ),
        if (emailAvailable || _emailMode) ...[
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: _submitting ? null : _toggleMode,
              child: Text(
                _emailMode ? 'Use phone instead' : 'Use email instead',
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        SbAuthLink(
          prefix: 'Remembered it?',
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
