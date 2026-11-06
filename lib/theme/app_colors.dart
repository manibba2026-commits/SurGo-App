import 'package:flutter/material.dart';

/// Colors lifted 1:1 from the SurGo design bible (:root CSS variables).
/// Note: the original doc names the primary accent "--orange" and the
/// secondary accent "--green", but both are actually shades of purple/violet.
/// We keep the same hex values, just with honest Dart names.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF0B0D0C);
  static const bg2 = Color(0xFF121513);
  static const panel = Color(0xFF181C19);
  static const panel2 = Color(0xFF1F2420);
  static const panel3 = Color(0xFF242A25);

  static const border = Color(0xFF272D29);
  static const borderLight = Color(0xFF333B35);

  static const text = Color(0xFFEEF2EE);
  static const muted = Color(0xFF9AA89F);
  static const muted2 = Color(0xFF6D7A73);

  // primary accent ("--orange")
  static const primary = Color(0xFF8B5CF6);
  static const primaryDark = Color(0xFF6D28D9);
  static const primaryLight = Color(0xFFC4B5FD);
  static const primarySoft = Color(0x1F8B5CF6);

  // secondary accent ("--green")
  static const secondary = Color(0xFFA78BFA);
  static const secondaryDark = Color(0xFF5B21B6);
  static const secondaryLight = Color(0xFFDDD6FE);
  static const secondarySoft = Color(0x1FA78BFA);

  static const danger = Color(0xFFEF4444);
  static const dangerSoft = Color(0x24EF4444);
  static const yellow = Color(0xFFF5C144);
  static const yellowSoft = Color(0x24F5C144);

  /// Available/confirmed states. The design bible has no green, so this is a
  /// desaturated one that sits with the violet accents instead of fighting
  /// them. Used only for small status pills and chips.
  static const success = Color(0xFF4ADE80);
  static const successSoft = Color(0x1F4ADE80);

  static const onAccent = Color(0xFF1E1033); // dark text on top of buttons
}
