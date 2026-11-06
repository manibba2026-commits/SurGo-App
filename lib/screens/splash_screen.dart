import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..forward();

  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void initState() {
    super.initState();
    // Loop the logo pulse independently of the one-shot progress bar so it
    // keeps breathing even if loading finishes early.
    _pulseController.repeat(reverse: true);
    _bootstrap();
  }

  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  Future<void> _bootstrap() async {
    final state = AppState.instance;
    await Future.wait([
      state.init(),
      Future.delayed(const Duration(milliseconds: 1600)),
    ]);
    if (!mounted) return;
    // init() restores the persisted Supabase session before it completes, so a
    // returning user lands on their dashboard instead of signing in again.
    Navigator.pushReplacementNamed(
      context,
      state.isSignedIn ? state.homeRoute : '/login',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: SbGradients.aurora,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final scale = 0.94 + (_pulseController.value * 0.12);
                  final glow = 0.25 + (_pulseController.value * 0.25);
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        gradient: SbGradients.brand,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: glow),
                            blurRadius: 40,
                            spreadRadius: 2,
                            offset: const Offset(0, 14),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.electric_rickshaw, color: AppColors.onAccent, size: 34),
                    ),
                  );
                },
              ),
              const SizedBox(height: 18),
              RichText(
                text: const TextSpan(
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                  children: [
                    TextSpan(text: 'SUR', style: TextStyle(color: AppColors.text)),
                    TextSpan(text: 'GO', style: TextStyle(color: AppColors.secondary)),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Text('Ride. Rent. Errand.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              const SizedBox(height: 48),
              SizedBox(
                width: 120,
                height: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    color: AppColors.panel2,
                    alignment: Alignment.centerLeft,
                    child: AnimatedBuilder(
                      animation: _progress,
                      builder: (context, _) => FractionallySizedBox(
                        widthFactor: _progress.value.clamp(0.04, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: SbGradients.brand,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              AnimatedBuilder(
                animation: _progress,
                builder: (context, _) => Text(
                  _progress.value < 1.0 ? 'Loading your ride…' : 'Almost there…',
                  style: const TextStyle(color: AppColors.muted2, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
