import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// Reusable building blocks for the three auth screens (sign in, sign up and
/// reset). They share one centered layout and one visual language so the
/// screens themselves only describe their fields and what the buttons do.

/// The SurGo logo tile: a rounded gradient square with the rickshaw glyph.
///
/// [glowAlpha] lets the splash breathe the glow without duplicating the tile.
class SbLogoMark extends StatelessWidget {
  final double size;
  final double iconSize;
  final double glowAlpha;
  final Offset glowOffset;
  const SbLogoMark({
    super.key,
    this.size = 64,
    this.iconSize = 30,
    this.glowAlpha = 0.35,
    this.glowOffset = const Offset(0, 14),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.29),
        gradient: SbGradients.brand,
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: glowAlpha),
            blurRadius: 40,
            spreadRadius: 2,
            offset: glowOffset,
          ),
        ],
      ),
      child: Icon(Icons.electric_rickshaw, color: AppColors.onAccent, size: iconSize),
    );
  }
}

/// The "SURGO" wordmark, optionally with the tagline beneath it.
class SbBrandWordmark extends StatelessWidget {
  final double fontSize;
  final bool showTagline;
  final double spacing;
  const SbBrandWordmark({
    super.key,
    this.fontSize = 23,
    this.showTagline = true,
    this.spacing = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
            children: const [
              TextSpan(text: 'SUR', style: TextStyle(color: AppColors.text)),
              TextSpan(text: 'GO', style: TextStyle(color: AppColors.secondary)),
            ],
          ),
        ),
        if (showTagline) ...[
          SizedBox(height: spacing),
          const Text(
            'Ride. Rent. Errand.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// The full centered brand lockup — logo tile over the wordmark.
class SbBrandLockup extends StatelessWidget {
  final double logoSize;
  final bool showTagline;
  final double gap;
  const SbBrandLockup({
    super.key,
    this.logoSize = 58,
    this.showTagline = true,
    this.gap = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SbLogoMark(size: logoSize, iconSize: logoSize * 0.44),
        SizedBox(height: gap),
        SbBrandWordmark(fontSize: 22, showTagline: showTagline),
      ],
    );
  }
}

/// Centered title + subtitle used at the top of each auth screen.
class SbAuthHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const SbAuthHeader({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted, fontSize: 13),
        ),
      ],
    );
  }
}

/// The shared auth background: the splash's radial glow with the content
/// centered and capped at a readable column width, scrolling when short on
/// space (a keyboard, a small phone).
class SbAuthScaffold extends StatelessWidget {
  final List<Widget> children;
  final Widget? leading;
  const SbAuthScaffold({super.key, required this.children, this.leading});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(gradient: SbGradients.aurora),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                constraints.maxWidth < 380 ? 18 : 24,
                24,
                constraints.maxWidth < 380 ? 18 : 24,
                32,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 56,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (leading != null) ...[
                          Align(alignment: Alignment.centerLeft, child: leading!),
                          const SizedBox(height: 8),
                        ],
                        ...children,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "— OR —" row that separates the form from the social buttons.
class SbOrDivider extends StatelessWidget {
  const SbOrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: AppColors.border)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text('OR', style: TextStyle(color: AppColors.muted2, fontSize: 11.5)),
        ),
        Expanded(child: Divider(color: AppColors.border)),
      ],
    );
  }
}

/// Full-width social sign-in button. [glow] gives it the purple halo (Google);
/// without it the button reads as a quieter secondary option (Facebook).
class SbSocialButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final bool glow;
  const SbSocialButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.45),
                  blurRadius: 22,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Material(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: glow
                    ? AppColors.primary.withValues(alpha: 0.6)
                    : AppColors.border,
                width: glow ? 1.4 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: AppColors.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular blue "f" standing in for the Facebook logo, matching [SbGoogleMark].
class SbFacebookMark extends StatelessWidget {
  final double size;
  const SbFacebookMark({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: Color(0xFF1877F2), shape: BoxShape.circle),
      child: Text(
        'f',
        style: TextStyle(
          fontSize: size * 0.72,
          fontWeight: FontWeight.w900,
          height: 1,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// A small centered "prefix + action" link, e.g. "No account? Sign up".
class SbAuthLink extends StatelessWidget {
  final String prefix;
  final String action;
  final VoidCallback? onPressed;
  const SbAuthLink({
    super.key,
    required this.prefix,
    required this.action,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(prefix, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              action,
              style: const TextStyle(
                color: AppColors.primaryLight,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Inline validation/refusal message shown above an auth button.
class SbAuthError extends StatelessWidget {
  final String? message;
  const SbAuthError({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 15, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message!,
              style: const TextStyle(color: AppColors.danger, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The auth-form text field: a full-width 64 px control whose label starts as
/// the placeholder and floats upward when the field is focused or filled.
///
/// Focus and error states animate over 200 ms, which is slow enough to read and
/// fast enough not to feel laggy. The field never rewrites its own text; phone
/// formatting happens on submit through `normalizePhoneNumber`.
class SbAuthField extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  final IconData? icon;
  final String? errorText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;
  final bool obscureText;
  final bool enabled;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const SbAuthField({
    super.key,
    required this.label,
    required this.controller,
    this.icon,
    this.errorText,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.autofillHints,
    this.obscureText = false,
    this.enabled = true,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  State<SbAuthField> createState() => _SbAuthFieldState();
}

class _SbAuthFieldState extends State<SbAuthField> {
  static const _duration = Duration(milliseconds: 200);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant SbAuthField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final accent =
        hasError ? AppColors.danger : focused ? AppColors.primary : AppColors.borderLight;
    const radius = BorderRadius.all(Radius.circular(14));

    OutlineInputBorder outline(Color color, double width) => OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: color, width: width),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedContainer(
          duration: _duration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: (hasError ? AppColors.danger : AppColors.primary)
                          .withValues(alpha: 0.24),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          // Material's notched outline keeps the label centered inside the
          // field until focus or content lifts it onto the top border.
          child: TextFormField(
            controller: widget.controller,
            focusNode: _focus,
            enabled: widget.enabled,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            inputFormatters: widget.inputFormatters,
            autofillHints: widget.autofillHints,
            obscureText: widget.obscureText,
            onChanged: widget.onChanged,
            onFieldSubmitted: widget.onSubmitted,
            cursorColor: AppColors.primaryLight,
            textAlignVertical: TextAlignVertical.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
            decoration: InputDecoration(
              labelText: widget.label,
              floatingLabelBehavior: FloatingLabelBehavior.auto,
              labelStyle: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: hasError ? AppColors.danger : AppColors.muted,
              ),
              floatingLabelStyle: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: hasError
                    ? AppColors.danger
                    : focused
                        ? AppColors.primaryLight
                        : AppColors.muted,
              ),
              prefixIcon: widget.icon == null
                  ? null
                  : Icon(
                      widget.icon,
                      size: 20,
                      color: focused ? AppColors.primaryLight : AppColors.muted,
                    ),
              suffixIcon: widget.suffix,
              suffixIconColor: AppColors.muted,
              filled: true,
              fillColor: widget.enabled ? AppColors.panel : AppColors.panel2,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              border: outline(AppColors.borderLight, 1),
              enabledBorder: outline(accent, focused || hasError ? 1.6 : 1),
              focusedBorder: outline(
                hasError ? AppColors.danger : AppColors.primary,
                1.6,
              ),
              disabledBorder: outline(AppColors.border, 1),
              errorBorder: outline(AppColors.danger, 1.4),
              focusedErrorBorder: outline(AppColors.danger, 1.6),
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.error_outline,
                    size: 13, color: AppColors.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: const TextStyle(
                        color: AppColors.danger, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The eye / eye-off toggle for a password field. The screen owns the boolean
/// and this only reports taps, so the field can be reused anywhere.
class SbPasswordToggle extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;
  const SbPasswordToggle({super.key, required this.visible, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 19,
          color: AppColors.muted,
        ),
      ),
    );
  }
}
