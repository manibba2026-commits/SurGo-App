import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'common.dart';

class SbFlowScaffold extends StatelessWidget {
  const SbFlowScaffold({
    super.key,
    required this.title,
    required this.map,
    required this.sheet,
    required this.stateKey,
    this.onBack,
    this.actions = const [],
    this.sheetFraction = 0.54,
  });

  final String title;
  final Widget map;
  final Widget sheet;
  final Object stateKey;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final double sheetFraction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned.fill(child: map),
            Positioned(
              top: 10,
              left: 12,
              right: 12,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    SbIconButton(
                      icon: Icons.arrow_back,
                      onTap: onBack ?? () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.panel.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    if (actions.isNotEmpty) ...[const Spacer(), ...actions],
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: TweenAnimationBuilder<double>(
                key: ValueKey(stateKey),
                tween: Tween(begin: 0, end: 1),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 450),
                curve: const Cubic(0.2, 0.9, 0.3, 1),
                builder: (context, value, child) => Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 40 * (1 - value)),
                    child: child,
                  ),
                ),
                child: Container(
                  height: constraints.maxHeight * sheetFraction,
                  width: double.infinity,
                  clipBehavior: Clip.antiAlias,
                  decoration: const BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(22),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x80000000),
                        blurRadius: 30,
                        offset: Offset(0, -10),
                      ),
                    ],
                  ),
                  child: SafeArea(top: false, child: sheet),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SbFlowStepper extends StatelessWidget {
  const SbFlowStepper({
    super.key,
    required this.labels,
    required this.activeStep,
  });

  final List<String> labels;
  final int activeStep;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Semantics(
              label: '${labels[i]}${i == activeStep ? ", current step" : ""}',
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i <= activeStep
                          ? AppColors.primary
                          : AppColors.border,
                      boxShadow: i == activeStep
                          ? [
                              BoxShadow(
                                color: AppColors.primary.withValues(
                                  alpha: 0.33,
                                ),
                                spreadRadius: 4,
                              ),
                            ]
                          : const [],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: i <= activeStep ? AppColors.text : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class SbSearchRadar extends StatefulWidget {
  const SbSearchRadar({super.key, this.size = 150, this.showIcon = true});
  final double size;
  final bool showIcon;

  @override
  State<SbSearchRadar> createState() => _SbSearchRadarState();
}

class _SbSearchRadarState extends State<SbSearchRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            for (var i = 0; i < 3; i++)
              Transform.scale(
                scale: 0.1 + 0.9 * ((_controller.value + i / 3) % 1),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.primary.withValues(
                        alpha: 0.8 * (1 - ((_controller.value + i / 3) % 1)),
                      ),
                      width: 2,
                    ),
                  ),
                ),
              ),
            if (widget.showIcon)
              const Icon(
                Icons.near_me_rounded,
                color: AppColors.primaryLight,
                size: 30,
              ),
          ],
        ),
      ),
    );
  }
}