import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class MatchingScreen extends StatefulWidget {
  const MatchingScreen({super.key});

  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/livetrip');
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 110,
              height: 110,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.panel2, width: 3),
                    ),
                  ),
                  RotationTransition(
                    turns: _controller,
                    child: SizedBox(
                      width: 110,
                      height: 110,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                        backgroundColor: Colors.transparent,
                        value: 0.25,
                      ),
                    ),
                  ),
                  const Icon(Icons.electric_rickshaw, size: 36, color: AppColors.primaryLight),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text('Finding you a ride…',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 6),
            const Text('Matching with nearby drivers',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
            const SizedBox(height: 30),
            SbOutlineButton(
              label: 'Cancel',
              block: false,
              onPressed: () => Navigator.popUntil(context, ModalRoute.withName('/home')),
            ),
          ],
        ),
      ),
    );
  }
}
