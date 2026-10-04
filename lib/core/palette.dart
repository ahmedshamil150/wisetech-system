import 'package:flutter/material.dart';

/// The brand colour everything is seeded from.
const Color kBrandBlue = Color(0xFF1668A8);

/// Amber accent used for highlights and warnings on tinted cards.
const Color kAmber = Color(0xFFF2B01E);

/// Semantic colours that need a different value in dark mode.
///
/// Everything here should be read through `context.colors` so the right
/// variant lands on screen; the light values are exactly the palette the
/// app has always shipped.
class AppColors {
  const AppColors(this.brightness);

  final Brightness brightness;

  bool get isDark => brightness == Brightness.dark;

  /// Success / "in stock" green.
  Color get success => isDark ? const Color(0xFF57D08A) : const Color(0xFF1B7F4B);

  /// Warnings such as "with workshop" text.
  Color get warning => isDark ? const Color(0xFFE8A34A) : const Color(0xFF9A5A00);

  /// Soft blue tint behind avatars and quiet icons.
  Color get tintBlue => isDark ? const Color(0xFF1B2A38) : const Color(0xFFEAF3F8);

  /// Pale amber card background (the dashboard "needs attention" card).
  Color get warningContainer =>
      isDark ? const Color(0xFF3A2A10) : const Color(0xFFFFF6E5);

  /// Border of that amber card.
  Color get warningBorder =>
      isDark ? const Color(0xFF5A4318) : const Color(0xFFF2C94C);

  /// Soft red card background (the dashboard "missing name" card).
  Color get errorContainer =>
      isDark ? const Color(0xFF3A1B1B) : const Color(0xFFFDEEEC);

  /// Border of that red card.
  Color get errorBorder =>
      isDark ? const Color(0xFF6E2E2A) : const Color(0xFFF1D9D7);

  /// Fill for the demo-switch container when it is off.
  Color get quietFill => isDark ? const Color(0xFF1B2430) : const Color(0xFFF6F9FC);

  /// Primary-tinted fill (badges, soft buttons) that survives both modes.
  Color get primaryTint => isDark
      ? const Color(0xFF12314A)
      : const Color(0xFFE7F1FA);

  /// Border of that primary-tinted fill.
  Color get primaryBorder =>
      isDark ? const Color(0xFF1E4A6B) : const Color(0xFFD5E4F2);
}

extension AppColorsX on BuildContext {
  AppColors get colors => AppColors(Theme.of(this).brightness);
}
