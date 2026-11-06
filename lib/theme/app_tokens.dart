import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Central design tokens for the branded surface language. Screens should read
/// radii, gradients and shadows from here instead of re-declaring literals, so
/// the four service cards and the tinted secondary surfaces stay coordinated.

class SbRadius {
  SbRadius._();

  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 26;

  static const BorderRadius card = BorderRadius.all(Radius.circular(md));
  static const BorderRadius button = BorderRadius.all(Radius.circular(14));
  static const BorderRadius field = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

class SbSpacing {
  SbSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class SbShadows {
  SbShadows._();

  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 8)),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x4D000000), blurRadius: 26, offset: Offset(0, 12)),
  ];

  /// A coloured halo under a service card or a primary action.
  static List<BoxShadow> glow(
    Color color, {
    double alpha = 0.22,
    double blur = 24,
    Offset offset = const Offset(0, 10),
  }) {
    return [
      BoxShadow(
        color: color.withValues(alpha: alpha),
        blurRadius: blur,
        offset: offset,
      ),
    ];
  }
}

/// The brand and service gradients. Every branded fill in the app comes from
/// this list; `SbTone.gradient` maps a semantic tone onto one of them.
class SbGradients {
  SbGradients._();

  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary, AppColors.primaryDark],
  );

  static const LinearGradient brandDeep = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primaryDark, AppColors.secondaryDark],
  );

  /// Good morning/evening backdrop behind the brand surfaces.
  static const RadialGradient aurora = RadialGradient(
    center: Alignment(0, -0.4),
    radius: 0.9,
    colors: [Color(0xFF221833), AppColors.bg],
  );

  static const LinearGradient ride = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8B5CF6), Color(0xFF4C1D95)],
  );

  static const LinearGradient rent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6366F1), Color(0xFF312E81)],
  );

  static const LinearGradient pasuyo = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF5C144), Color(0xFFD97706)],
  );

  static const LinearGradient assist = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0D9488), Color(0xFF134E4A)],
  );

  static const LinearGradient wallet = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6D28D9), Color(0xFF4C1D95)],
  );

  /// Neutral plate used behind avatars, thumbnails and vehicle glyphs.
  static const LinearGradient panel = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.panel3, AppColors.panel2],
  );

  /// The faint wash used behind secondary cards. Falls out of the tone's
  /// accent, so every tinted surface shares one recipe.
  static LinearGradient tint(Color accent, {double top = 0.16, double bottom = 0.03}) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        accent.withValues(alpha: top),
        accent.withValues(alpha: bottom),
      ],
    );
  }
}

/// Semantic colour roles used by tinted surfaces, service cards and status
/// banners. One tone owns both its accent and its gradient so a screen only
/// has to name the meaning ("pasuyo", "vehicle", "danger").
enum SbTone {
  brand(
    accent: Color(0xFFA78BFA),
    gradient: SbGradients.brandDeep,
  ),
  ride(
    accent: Color(0xFFA78BFA),
    gradient: SbGradients.ride,
  ),
  rent(
    accent: Color(0xFFA5B4FC),
    gradient: SbGradients.rent,
  ),
  pasuyo(
    accent: Color(0xFFF5C144),
    gradient: SbGradients.pasuyo,
    inkOnGradient: true,
  ),
  assist(
    accent: Color(0xFF5EEAD4),
    gradient: SbGradients.assist,
  ),
  wallet(
    accent: Color(0xFFC4B5FD),
    gradient: SbGradients.wallet,
  ),
  activity(
    accent: Color(0xFF93C5FD),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF3B82F6), Color(0xFF1E3A8A)],
    ),
  ),
  vehicle(
    accent: Color(0xFF6EE7B7),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF10B981), Color(0xFF065F46)],
    ),
  ),
  notification(
    accent: Color(0xFFF9A8D4),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFEC4899), Color(0xFF831843)],
    ),
  ),
  info(
    accent: Color(0xFF93C5FD),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF3B82F6), Color(0xFF1E40AF)],
    ),
  ),
  success(
    accent: AppColors.success,
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF22C55E), Color(0xFF15803D)],
    ),
  ),
  warning(
    accent: AppColors.yellow,
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFF59E0B), Color(0xFF92400E)],
    ),
  ),
  danger(
    accent: Color(0xFFF87171),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFEF4444), Color(0xFF991B1B)],
    ),
  ),
  neutral(
    accent: AppColors.muted,
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF4B5563), Color(0xFF1F2937)],
    ),
  );

  const SbTone({
    required this.accent,
    required this.gradient,
    this.inkOnGradient = false,
  });

  final Color accent;
  final LinearGradient gradient;
  final bool inkOnGradient;

  /// Text and icon colour that reads on [gradient].
  Color get onGradient => inkOnGradient ? AppColors.onAccent : Colors.white;

  /// The quieter copy on a service card.
  Color get onGradientMuted =>
      onGradient.withValues(alpha: inkOnGradient ? 0.7 : 0.78);

  Color get soft => accent.withValues(alpha: 0.13);
  Color get border => accent.withValues(alpha: 0.32);

  LinearGradient get tint => SbGradients.tint(accent);

  List<BoxShadow> get glow => SbShadows.glow(accent);
}

/// Shared type ramp for the refreshed surfaces.
class SbTextStyles {
  SbTextStyles._();

  static const display = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.4,
  );

  static const title = TextStyle(fontSize: 16, fontWeight: FontWeight.w800);
  static const cardTitle = TextStyle(fontSize: 13, fontWeight: FontWeight.w800);
  static const label = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700);
  static const body = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);
  static const caption = TextStyle(fontSize: 11, color: AppColors.muted);
  static const eyebrow = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.6,
    color: AppColors.muted2,
  );
}
