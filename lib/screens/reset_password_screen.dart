import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_repository.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';
import 'email_login_screen.dart' show passwordFieldError;

/// Shown by the app's recovery gate, never by a reset-link request itself.
/// The caller owns session guards, clearing recovery and subsequent navigation.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.recoveryResolver,
    required this.onCompleted,
  });

  final EmailRecoveryRepository? Function() recoveryResolver;
  final Future<void> Function() onCompleted;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _submitting = false;
  bool _passwordUpdated = false;
  bool _completed = false;
  String? _passwordError;
  String? _confirmError;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _completed) return;
    FocusScope.of(context).unfocus();
    final password = _passwordCtrl.text;
    if (!_passwordUpdated) {
      final passwordError = passwordFieldError(password, creating: true);
      final confirmError = _confirmCtrl.text != password
          ? 'The passwords do not match.'
          : null;
      if (passwordError != null || confirmError != null) {
        setState(() {
          _passwordError = passwordError;
          _confirmError = confirmError;
          _error = null;
        });
        return;
      }
    }

    setState(() {
      _submitting = true;
      _passwordError = null;
      _confirmError = null;
      _error = null;
    });
    try {
      final recovery = widget.recoveryResolver();
      if (recovery == null) {
        throw const AuthFailure(
          AuthFailureCode.providerUnavailable,
          'Email recovery is unavailable. Open a new password reset link when it is available.',
        );
      }
      if (!_passwordUpdated) {
        await recovery.updatePassword(password);
        if (!mounted) return;
        _passwordUpdated = true;
        // Only transient field values exist; do not save a password or token.
        _passwordCtrl.clear();
        _confirmCtrl.clear();
      }
      if (!mounted) return;
      await widget.onCompleted();
      if (!mounted) return;
      setState(() => _completed = true);
    } catch (error) {
      if (!mounted) return;
      final failure = AuthFailure.from(error);
      setState(
        () => _error = _passwordUpdated
            ? 'Your password was updated, but recovery could not finish. Try again.'
            : failure.code == AuthFailureCode.unknown
            ? 'Your password could not be updated. Please try again.'
            : failure.message,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fieldsEnabled = !_submitting && !_passwordUpdated;
    return PopScope(
      canPop: false,
      child: SbAuthScaffold(
        children: [
          const SizedBox(height: 12),
          const SbBrandLockup(logoSize: 52),
          const SizedBox(height: 26),
          const SbAuthHeader(
            title: 'Reset your password',
            subtitle: 'Choose a new password with at least 8 characters.',
          ),
          const SizedBox(height: 24),
          SbAuthField(
            label: 'New password',
            controller: _passwordCtrl,
            icon: Icons.lock_outline,
            errorText: _passwordError,
            obscureText: true,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            enabled: fieldsEnabled,
            onChanged: (_) {
              if (_passwordError != null) {
                setState(() => _passwordError = null);
              }
            },
          ),
          const SizedBox(height: 12),
          SbAuthField(
            label: 'Confirm password',
            controller: _confirmCtrl,
            icon: Icons.lock_outline,
            errorText: _confirmError,
            obscureText: true,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            enabled: fieldsEnabled,
            onChanged: (_) {
              if (_confirmError != null) setState(() => _confirmError = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 18),
          if (_completed)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Your password has been updated.',
                style: TextStyle(color: AppColors.success, fontSize: 12.5),
              ),
            ),
          SbAuthError(message: _error),
          SbPrimaryButton(
            label: _submitting
                ? (_passwordUpdated
                      ? 'Finishing recovery…'
                      : 'Updating password…')
                : _completed
                ? 'Password updated'
                : _passwordUpdated
                ? 'Continue'
                : 'Update password',
            onPressed: _submitting || _completed ? null : _submit,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
