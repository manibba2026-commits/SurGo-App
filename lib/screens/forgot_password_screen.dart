import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Account recovery without a password.
///
/// SurGo accounts are passwordless, so recovery is the same verified phone
/// factor: request a code for the number on file and sign in with it. The route
/// name is kept so existing links and settings keep working.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final phoneCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    phoneCtrl.dispose();
    super.dispose();
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
    return SbAuthScaffold(
      leading: IconButton(
        onPressed: () => Navigator.maybePop(context),
        icon: const Icon(Icons.arrow_back, color: AppColors.text),
        tooltip: 'Back to log in',
      ),
      children: [
        const SizedBox(height: 12),
        const SbBrandLockup(logoSize: 52),
        const SizedBox(height: 26),
        const SbAuthHeader(
          title: 'Recover your account',
          subtitle:
              'Enter the phone number on your account and we will text you a code to sign in.',
        ),
        const SizedBox(height: 24),
        SbEditableField(
          label: 'Phone number',
          controller: phoneCtrl,
          leading: const Icon(Icons.phone, size: 18, color: AppColors.text),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          hintText: '+63 9XX XXX XXXX',
        ),
        const SizedBox(height: 18),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Sending code…' : 'Send code',
          onPressed: _submitting ? null : _submit,
        ),
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
