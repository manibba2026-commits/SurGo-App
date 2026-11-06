import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// The four primary service tiles on Home. A service card owns its gradient,
/// icon chip, halo and copy hierarchy so the four read as one family.
class SbServiceCard extends StatelessWidget {
  final SbTone tone;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const SbServiceCard({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = tone.onGradient;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: tone.gradient,
        borderRadius: SbRadius.card,
        border: Border.all(color: fg.withValues(alpha: 0.12)),
        boxShadow: SbShadows.glow(tone.accent, alpha: 0.24, blur: 22),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: SbRadius.card,
          splashColor: fg.withValues(alpha: 0.12),
          highlightColor: fg.withValues(alpha: 0.06),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                top: -30,
                right: -22,
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fg.withValues(alpha: 0.08),
                  ),
                ),
              ),
              Positioned(
                bottom: -38,
                right: 34,
                child: Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fg.withValues(alpha: 0.05),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: fg.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(SbRadius.sm - 1),
                            border: Border.all(
                              color: fg.withValues(alpha: 0.14),
                            ),
                          ),
                          child: Icon(icon, size: 20, color: fg),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.arrow_outward_rounded,
                          size: 16,
                          color: fg.withValues(alpha: 0.75),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 13.5,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tone.onGradientMuted,
                        fontSize: 11,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quieter card washed in a semantic accent. Used for wallet, activity,
/// booking, rental, Pasuyo, vehicle, notification and status surfaces so they
/// stay visually related to their service without competing with the four
/// primary tiles.
class SbTintedCard extends StatelessWidget {
  final SbTone tone;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool elevated;
  final Color? borderColor;
  final bool wash;

  const SbTintedCard({
    super.key,
    required this.tone,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.elevated = false,
    this.borderColor,
    this.wash = true,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: wash ? null : AppColors.panel,
        gradient: wash
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tone.accent.withValues(alpha: 0.14),
                  AppColors.panel,
                ],
              )
            : null,
        borderRadius: SbRadius.card,
        border: Border.all(color: borderColor ?? tone.border),
        boxShadow: elevated ? SbShadows.soft : null,
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: SbRadius.card,
        onTap: onTap,
        splashColor: tone.accent.withValues(alpha: 0.10),
        highlightColor: tone.accent.withValues(alpha: 0.05),
        child: content,
      ),
    );
  }
}

/// The rounded icon plate used inside tinted cards and list rows.
class SbToneIcon extends StatelessWidget {
  final SbTone tone;
  final IconData icon;
  final double size;
  final double iconSize;

  const SbToneIcon({
    super.key,
    required this.tone,
    required this.icon,
    this.size = 38,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tone.soft,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: tone.accent.withValues(alpha: 0.22)),
      ),
      child: Icon(icon, size: iconSize, color: tone.accent),
    );
  }
}

/// Section title with an optional trailing action, used above card stacks.
class SbSectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SbSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: SbTextStyles.cardTitle.copyWith(fontSize: 13.5)),
        if (actionLabel != null)
          InkWell(
            onTap: onAction,
            borderRadius: SbRadius.pill,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                actionLabel!,
                style: const TextStyle(
                  color: AppColors.primaryLight,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A full-width information/status strip: confirmation, warning, info or an
/// error. The tint makes the intent obvious before the copy is read.
class SbStatusBanner extends StatelessWidget {
  final SbTone tone;
  final IconData icon;
  final String title;
  final String? message;
  final Widget? trailing;

  const SbStatusBanner({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    this.message,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: SbGradients.tint(tone.accent, top: 0.18),
        borderRadius: SbRadius.card,
        border: Border.all(color: tone.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SbToneIcon(tone: tone, icon: icon, size: 34, iconSize: 17),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: tone.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}
