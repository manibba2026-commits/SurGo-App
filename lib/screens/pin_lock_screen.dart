import 'package:flutter/material.dart';

import '../auth/demo_auth.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';

/// Shown on a demo relaunch instead of the OTP screen: the persisted account
/// stays signed in, but its dashboard stays behind the device PIN.
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  static const int _length = DemoAuthConfig.pinLength;

  late final List<TextEditingController> controllers =
      List.generate(_length, (_) => TextEditingController());
  late final List<FocusNode> focusNodes =
      List.generate(_length, (_) => FocusNode());

  bool _submitting = false;
  bool _customPin = false;
  String? _error;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    _loadPinHint();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || state.isSignedIn) return;
      Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
    });
  }

  Future<void> _loadPinHint() async {
    final custom = await state.pinStore.hasCustomPin;
    if (mounted) setState(() => _customPin = custom);
  }

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final node in focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  bool get _isComplete =>
      controllers.every((controller) => controller.text.trim().isNotEmpty);

  String get _pin => controllers.map((controller) => controller.text.trim()).join();

  void _onChanged(int index, String value) {
    if (value.isNotEmpty && index < _length - 1) {
      focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      focusNodes[index - 1].requestFocus();
    }
    setState(() {});
    if (_isComplete) {
      Future.delayed(const Duration(milliseconds: 150), _unlock);
    }
  }

  void _clearPin() {
    for (final controller in controllers) {
      controller.clear();
    }
    focusNodes.first.requestFocus();
  }

  Future<void> _unlock() async {
    if (_submitting || !_isComplete) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });

    final result = await state.unlockWithPin(_pin);
    if (!mounted) return;

    if (result == PinUnlockResult.success) {
      Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
      return;
    }

    setState(() {
      _submitting = false;
      _error = 'That PIN is incorrect. Try again.';
    });
    _clearPin();
  }

  Future<void> _forgotPin() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    await state.forgotPin();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final account = state.currentAccount;
    final role = demoAccountRefFor(account?.id ?? '')?.roleLabel;
    final firstName = account?.name.split(' ').first;

    return SbAuthScaffold(
      children: [
        const SizedBox(height: 22),
        const SbBrandLockup(),
        const SizedBox(height: 30),
        SbAuthHeader(
          title: 'Welcome back${firstName == null ? '' : ', $firstName'}',
          subtitle: 'Enter your PIN to unlock your SurGo dashboard.',
        ),
        if (account != null && role != null) ...[
          const SizedBox(height: 8),
          Text(
            '${account.name} · $role',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted2, fontSize: 11.5),
          ),
        ],
        const SizedBox(height: 26),
        Row(
          children: List.generate(_length, (index) {
            final filled = controllers[index].text.isNotEmpty;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: index == _length - 1 ? 0 : 8),
                child: AspectRatio(
                  aspectRatio: 0.82,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.panel,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            filled ? AppColors.primary : AppColors.borderLight,
                        width: 1.5,
                      ),
                    ),
                    child: TextField(
                      controller: controllers[index],
                      focusNode: focusNodes[index],
                      enabled: !_submitting,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      obscuringCharacter: '●',
                      maxLength: 1,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                      decoration: const InputDecoration(
                        counterText: '',
                        border: InputBorder.none,
                      ),
                      onChanged: (value) => _onChanged(index, value),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 16),
        if (!_customPin)
          const Text(
            'Demo PIN: ${DemoAuthConfig.defaultPin}',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted2, fontSize: 11),
          ),
        const SizedBox(height: 12),
        SbAuthError(message: _error),
        SbPrimaryButton(
          label: _submitting ? 'Unlocking…' : 'Unlock',
          onPressed: _isComplete && !_submitting ? _unlock : null,
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: _submitting ? null : _forgotPin,
            child: const Text('Forgot PIN? Sign in again'),
          ),
        ),
      ],
    );
  }
}
