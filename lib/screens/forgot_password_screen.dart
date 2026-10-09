import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Simulated password reset: it confirms the identifier exists in the local
/// seed and shows the "link sent" state. No email is actually sent.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final identifierCtrl = TextEditingController();
  String? _error;
  bool _sent = false;

  @override
  void dispose() {
    identifierCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final identifier = identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = 'Enter your phone number or email.');
      return;
    }

    final state = AppState.instance;
    if (!state.ready) await state.init();
    final exists = state.db.accounts.any((a) => a.matches(identifier));
    if (!exists) {
      setState(() => _error = 'We could not find an account with that phone or email.');
      return;
    }
    setState(() {
      _error = null;
      _sent = true;
    });
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
        if (_sent)
          ..._sentState()
        else
          ..._formState(),
      ],
    );
  }

  List<Widget> _formState() {
    return [
      const SizedBox(height: 12),
      const SbBrandLockup(logoSize: 52),
      const SizedBox(height: 26),
      const SbAuthHeader(
        title: 'Reset your password',
        subtitle: "Enter your phone or email and we'll send reset instructions.",
      ),
      const SizedBox(height: 24),
      SbEditableField(
        label: 'Phone or email',
        controller: identifierCtrl,
        leading: const Icon(Icons.person_outline, size: 18, color: AppColors.text),
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        hintText: '+63 9XX XXX XXXX or you@email.com',
      ),
      const SizedBox(height: 18),
      SbAuthError(message: _error),
      SbPrimaryButton(label: 'Send reset link', onPressed: _submit),
      const SizedBox(height: 20),
      SbAuthLink(
        prefix: 'Remembered it?',
        action: 'Log in',
        onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
      ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _sentState() {
    return [
      const SizedBox(height: 40),
      Center(
        child: Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.successSoft,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mark_email_read_outlined,
              size: 34, color: AppColors.success),
        ),
      ),
      const SizedBox(height: 24),
      const SbAuthHeader(
        title: 'Check your inbox',
        subtitle: 'If an account matches those details, a reset link is on its way.',
      ),
      const SizedBox(height: 14),
      Text(
        'Sent to ${identifierCtrl.text.trim()}',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.primaryLight, fontSize: 13, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'This is a simulation — no email is actually sent.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted2, fontSize: 11.5),
      ),
      const SizedBox(height: 30),
      SbPrimaryButton(
        label: 'Back to log in',
        onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
      ),
      const SizedBox(height: 8),
    ];
  }
}
