import 'package:flutter/material.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController phoneCtrl =
      TextEditingController(text: MockData.phoneNumber);
  bool googleLoading = false;

  @override
  void dispose() {
    phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    setState(() => googleLoading = true);
    // Simulated OAuth round-trip — Google sign-in skips the OTP step
    // entirely since the phone number never needs to be verified this way.
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => googleLoading = false);
    await AppState.instance.init();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Signed in with Google as Jr Derigay (simulated)')),
    );
    Navigator.pushNamedAndRemoveUntil(context, '/home', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Let's get you started",
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text(
                'Enter your number to book, ride, or rent today.',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 26),
              SbEditableField(
                label: 'Phone Number',
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                hintText: '+63 9XX XXX XXXX',
                leading: const Icon(Icons.phone, size: 18, color: AppColors.text),
              ),
              const SizedBox(height: 22),
              SbPrimaryButton(
                label: 'Next',
                onPressed: () => Navigator.pushNamed(
                  context,
                  '/otp',
                  arguments: {'phone': phoneCtrl.text.trim()},
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: const [
                  Expanded(child: Divider(color: AppColors.border)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('OR',
                        style: TextStyle(color: AppColors.muted2, fontSize: 11.5)),
                  ),
                  Expanded(child: Divider(color: AppColors.border)),
                ],
              ),
              const SizedBox(height: 22),
              SbGlowButton(
                label: googleLoading ? 'Signing in…' : 'Continue with Google',
                icon: googleLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryLight),
                      )
                    : const SbGoogleMark(),
                onPressed: googleLoading ? null : _continueWithGoogle,
              ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(color: AppColors.muted2, fontSize: 11),
                    children: [
                      TextSpan(text: "By continuing you agree to SurGo's "),
                      TextSpan(
                        text: 'Terms',
                        style: TextStyle(color: AppColors.primaryLight),
                      ),
                      TextSpan(text: ' & '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: TextStyle(color: AppColors.primaryLight),
                      ),
                      TextSpan(text: '.'),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
