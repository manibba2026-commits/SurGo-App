import 'dart:async';
import 'package:flutter/material.dart';
import '../auth/mock_auth_repository.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/common.dart';
import '../widgets/surgo_notice.dart';

/// One-time-code entry for phone sign-in, registration and account linking.
///
/// Expected arguments: `{'phone': String, 'mode': 'login' | 'register' |
/// 'recovery' | 'linkPhone', 'name': String?}`. The code is verified by
/// Supabase; nothing is accepted locally.
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

enum _OtpMode { login, register, recovery, linkPhone }

class _OtpScreenState extends State<OtpScreen> {
  static const _length = 6;
  static const _resendSeconds = 42;

  late final List<TextEditingController> controllers =
      List.generate(_length, (_) => TextEditingController());
  late final List<FocusNode> focusNodes =
      List.generate(_length, (_) => FocusNode());

  int secondsLeft = _resendSeconds;
  Timer? _timer;
  String? _phone;
  String? _name;
  _OtpMode _mode = _OtpMode.login;
  bool _argsRead = false;
  bool _submitting = false;
  bool _resending = false;
  String? _error;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    secondsLeft = _resendSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (secondsLeft <= 1) {
        timer.cancel();
        setState(() => secondsLeft = 0);
        return;
      }
      setState(() => secondsLeft--);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final phone = args['phone'];
      if (phone is String && phone.isNotEmpty) _phone = phone;
      final name = args['name'];
      if (name is String && name.trim().isNotEmpty) _name = name.trim();
      _mode = switch (args['mode']) {
        'register' => _OtpMode.register,
        'recovery' => _OtpMode.recovery,
        'linkPhone' => _OtpMode.linkPhone,
        _ => _OtpMode.login,
      };
    }
    if (_phone == null) {
      _error = 'That phone number is missing. Go back and request a new code.';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
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

  String get _code =>
      controllers.map((controller) => controller.text.trim()).join();

  void _onChanged(int index, String value) {
    if (value.isNotEmpty && index < _length - 1) {
      focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      focusNodes[index - 1].requestFocus();
    }
    setState(() {});
    if (_isComplete) {
      // Let the last digit paint before verifying.
      Future.delayed(const Duration(milliseconds: 150), _verify);
    }
  }

  Future<void> _verify() async {
    if (_submitting || !_isComplete) return;
    final phone = _phone;
    if (phone == null) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _submitting = true;
      _error = null;
    });

    final failure = _mode == _OtpMode.linkPhone
        ? await state.verifyPhoneLink(phone: phone, token: _code)
        : await state.verifyPhoneOtp(phone: phone, token: _code);
    if (!mounted) return;

    if (failure != null) {
      setState(() {
        _submitting = false;
        _error = failure.message;
      });
      _clearCode();
      return;
    }

    setState(() => _submitting = false);
    if (_mode == _OtpMode.linkPhone) {
      Navigator.pop(context, true);
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, state.homeRoute, (r) => false);
  }

  void _clearCode() {
    for (final controller in controllers) {
      controller.clear();
    }
    focusNodes.first.requestFocus();
  }

  Future<void> _resend() async {
    if (_resending || _submitting || _phone == null) return;
    setState(() {
      _resending = true;
      _error = null;
    });

    final failure = await state.sendPhoneOtp(
      phone: _phone!,
      fullName: _name,
      createUser: _mode == _OtpMode.register,
    );
    if (!mounted) return;

    setState(() {
      _resending = false;
      _error = failure?.message;
    });
    if (failure == null) {
      _clearCode();
      _startTimer();
      SurgoNotice.show(
        context,
        'A new code is on its way.',
        tone: SbNoticeTone.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final phoneLabel = _phone ?? 'your phone';
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                onPressed: _submitting ? null : () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back, color: AppColors.text),
                tooltip: 'Back',
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              const SizedBox(height: 18),
              const Text(
                'Verify your number',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                  children: [
                    const TextSpan(text: 'Enter the 6-digit code sent to '),
                    TextSpan(
                      text: phoneLabel,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Row(
                children: List.generate(_length, (index) {
                  final filled = controllers[index].text.isNotEmpty;
                  return Expanded(
                    child: Padding(
                      padding:
                          EdgeInsets.only(right: index == _length - 1 ? 0 : 8),
                      child: AspectRatio(
                        aspectRatio: 0.82,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.panel,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: filled
                                  ? AppColors.primary
                                  : AppColors.borderLight,
                              width: 1.5,
                            ),
                          ),
                          child: TextField(
                            controller: controllers[index],
                            focusNode: focusNodes[index],
                            enabled: !_submitting,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            autofillHints: index == 0
                                ? const [AutofillHints.oneTimeCode]
                                : null,
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
              const SizedBox(height: 18),
              Row(
                children: [
                  const Text(
                    "Didn't get a code? ",
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                  if (_resending)
                    const Text(
                      'Sending…',
                      style: TextStyle(
                        color: AppColors.primaryLight,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    )
                  else if (secondsLeft > 0)
                    Text(
                      'Resend in 0:${secondsLeft.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: AppColors.muted2,
                        fontSize: 12,
                      ),
                    )
                  else
                    InkWell(
                      onTap: _submitting ? null : _resend,
                      borderRadius: BorderRadius.circular(4),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          'Resend code',
                          style: TextStyle(
                            color: AppColors.primaryLight,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (state.isMockAuth) ...[
                const SizedBox(height: 10),
                Text(
                  'Preview code: ${MockAuthRepository.defaultOtpCode}',
                  style: const TextStyle(color: AppColors.muted2, fontSize: 11),
                ),
              ],
              const SizedBox(height: 24),
              SbAuthError(message: _error),
              const SizedBox(height: 6),
              SbPrimaryButton(
                label: _submitting ? 'Verifying…' : 'Verify code',
                onPressed: _isComplete && !_submitting ? _verify : null,
              ),
              if (_mode == _OtpMode.linkPhone) ...[
                const SizedBox(height: 12),
                const Text(
                  'We will add this number to the account you are already signed into.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
