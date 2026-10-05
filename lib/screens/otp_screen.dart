import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  static const _length = 6;
  late final List<TextEditingController> controllers =
      List.generate(_length, (_) => TextEditingController());
  late final List<FocusNode> focusNodes = List.generate(_length, (_) => FocusNode());

  int secondsLeft = 42;
  Timer? _timer;
  String? _phone;
  bool _argsRead = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    // Pre-fill the first two digits so the demo doesn't start on an empty
    // screen — mirrors the original mock's "4 1 _ _" starting state.
    controllers[0].text = '4';
    controllers[1].text = '1';
  }

  void _startTimer() {
    _timer?.cancel();
    secondsLeft = 42;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (secondsLeft == 0) {
        t.cancel();
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
    if (args is Map && args['phone'] is String && (args['phone'] as String).isNotEmpty) {
      _phone = args['phone'] as String;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in controllers) {
      c.dispose();
    }
    for (final f in focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  bool get _isComplete => controllers.every((c) => c.text.trim().isNotEmpty);

  void _onChanged(int index, String value) {
    if (value.isNotEmpty && index < _length - 1) {
      focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      focusNodes[index - 1].requestFocus();
    }
    setState(() {});
    if (_isComplete) {
      // Small delay so the last digit is visibly filled before we navigate.
      Future.delayed(const Duration(milliseconds: 150), _verify);
    }
  }

  void _verify() {
    if (!_isComplete) return;
    FocusScope.of(context).unfocus();
    AppState.instance.init();
    Navigator.pushNamedAndRemoveUntil(context, '/home', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final phoneLabel = _phone?.isNotEmpty == true ? _phone! : MockData.phoneNumber;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Verify your number',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                  children: [
                    const TextSpan(text: 'Enter the 6-digit code sent to '),
                    TextSpan(
                      text: phoneLabel,
                      style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Row(
                children: List.generate(_length, (i) {
                  final filled = controllers[i].text.isNotEmpty;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i == _length - 1 ? 0 : 8),
                      child: AspectRatio(
                        aspectRatio: 0.82,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.panel,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: filled ? AppColors.primary : AppColors.borderLight,
                              width: 1.5,
                            ),
                          ),
                          child: TextField(
                            controller: controllers[i],
                            focusNode: focusNodes[i],
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            maxLength: 1,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                            decoration: const InputDecoration(
                              counterText: '',
                              border: InputBorder.none,
                            ),
                            onChanged: (v) => _onChanged(i, v),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 18),
              Text.rich(
                TextSpan(
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                  children: [
                    const TextSpan(text: "Didn't get a code? "),
                    TextSpan(
                      text: secondsLeft > 0
                          ? 'Resend in 0:${secondsLeft.toString().padLeft(2, '0')}'
                          : 'Resend now',
                      style: const TextStyle(
                          color: AppColors.primaryLight, fontWeight: FontWeight.w700),
                      recognizer: secondsLeft == 0
                          ? (TapGestureRecognizer()..onTap = _startTimer)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              SbPrimaryButton(
                label: 'Verify Code',
                onPressed: _isComplete ? _verify : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
