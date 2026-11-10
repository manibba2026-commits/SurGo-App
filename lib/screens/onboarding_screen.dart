import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/phone_input.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// First-run registration for an authenticated Google account.
///
/// Google only proves the email. SurGo needs a name and a Philippine mobile
/// number before the account can book, drive or rent, so a provider account
/// without a phone identity lands here instead of on a dashboard.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final TextEditingController nameCtrl;
  final phoneCtrl = TextEditingController();
  bool _submitting = false;
  String? _nameError;
  String? _phoneError;
  String? _error;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    nameCtrl = TextEditingController(
      text: state.identity?.fullName ?? state.currentAccount?.name ?? '',
    );
    nameCtrl.addListener(_clearNameError);
    phoneCtrl.addListener(_clearPhoneError);
  }

  @override
  void dispose() {
    nameCtrl.removeListener(_clearNameError);
    phoneCtrl.removeListener(_clearPhoneError);
    nameCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  void _clearNameError() {
    if (_nameError != null) setState(() => _nameError = null);
  }

  void _clearPhoneError() {
    if (_phoneError != null) setState(() => _phoneError = null);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final name = nameCtrl.text.trim();
    final nameError = name.isEmpty ? 'Enter your full name.' : null;
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

    final failure =
        await state.completeOnboarding(fullName: name, phone: phone);
    if (!mounted) return;

    if (failure != null) {
      setState(() {
        _submitting = false;
        _error = failure.message;
      });
      return;
    }

    setState(() => _submitting = false);
    if (state.requiresOnboarding) {
      setState(() => _error =
          'Your account still needs a mobile number. Check the number and try again.');
      return;
    }
    Navigator.pushNamedAndRemoveUntil(
      context,
      state.requiresPin ? '/pin' : state.homeRoute,
      (r) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SbAuthScaffold(
      children: [
        const SizedBox(height: 12),
        const SbBrandLockup(logoSize: 52),
        const SizedBox(height: 26),
        const SbAuthHeader(
          title: 'Finish your account',
          subtitle:
              'Add your name and mobile number. Google verified your email; SurGo still needs a number for rides and deliveries.',
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
          enabled: !_submitting,
        ),
        const SizedBox(height: 14),
        SbAuthField(
          label: 'Mobile number',
          controller: phoneCtrl,
          icon: Icons.phone_outlined,
          errorText: _phoneError,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          inputFormatters: [phPhoneInputFormatter],
          autofillHints: const [AutofillHints.telephoneNumber],
          enabled: !_submitting,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 18),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Saving…' : 'Continue',
          onPressed: _submitting ? null : _submit,
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: _submitting
              ? null
              : () async {
                  await state.logout();
                  if (!context.mounted) return;
                  Navigator.pushNamedAndRemoveUntil(
                      context, '/login', (r) => false);
                },
          style: TextButton.styleFrom(
            foregroundColor: AppColors.muted,
            textStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          child: const Text('Use a different account'),
        ),
      ],
    );
  }
}
