import 'package:flutter/material.dart';

import 'palette.dart';

export 'palette.dart';

/// Builds the app theme for [brightness].
///
/// The light values are the palette the app has always shipped (white cards
/// on a pale blue-grey canvas, brand blue actions); dark mode is a true
/// black canvas with near-black surfaces stepping up from it.
ThemeData buildAppTheme([Brightness brightness = Brightness.light]) {
  final isDark = brightness == Brightness.dark;
  const brand = kBrandBlue;

  // canvas / surfaces
  const lightScaffold = Color(0xFFF5F8FB);
  const darkScaffold = Color(0xFF000000);
  const lightSurface = Colors.white;
  const darkSurface = Color(0xFF0B0B0B);
  const lightFill = Colors.white;
  const darkFill = Color(0xFF161616);
  const lightBorder = Color(0xFFE2E9F0);
  const darkBorder = Color(0xFF2C2C2C);
  const lightOutlineField = Color(0xFFD5DEE7);
  const darkOutlineField = Color(0xFF3D3D3D);

  // text
  const lightOnSurface = Color(0xFF1C2733);
  const darkOnSurface = Color(0xFFF2F2F2);
  const lightMuted = Color(0xFF5B6B7B); // the app's long-standing kMuted
  const darkMuted = Color(0xFFA6A6A6);
  const lightHint = Color(0xFF666F7A); // the app's long-standing kHint
  const darkHint = Color(0xFF8F8F8F);

  const lightError = Color(0xFFB3261E);
  const darkError = Color(0xFFFFB4AB);

  final scheme =
      ColorScheme.fromSeed(seedColor: brand, brightness: brightness).copyWith(
    primary: brand,
    onPrimary: Colors.white,
    primaryContainer: isDark ? const Color(0xFF0B4A78) : const Color(0xFFD6E7F5),
    onPrimaryContainer:
        isDark ? const Color(0xFFCBE5FA) : const Color(0xFF0B3553),
    surface: isDark ? darkSurface : lightSurface,
    onSurface: isDark ? darkOnSurface : lightOnSurface,
    onSurfaceVariant: isDark ? darkMuted : lightMuted,
    outline: isDark ? darkHint : lightHint,
    outlineVariant: isDark ? darkBorder : lightBorder,
    error: isDark ? darkError : lightError,
    errorContainer:
        isDark ? const Color(0xFF5C1512) : const Color(0xFFFDEEEC),
    onErrorContainer:
        isDark ? const Color(0xFFFFDAD6) : const Color(0xFF7A1710),
  );

  final textTheme = const TextTheme().copyWith(
        displayLarge: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
        headlineSmall: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        titleMedium: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        titleSmall: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        bodyLarge: const TextStyle(fontSize: 16),
        bodyMedium: const TextStyle(fontSize: 14),
        bodySmall: const TextStyle(fontSize: 12.5),
        labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        labelMedium: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        labelSmall: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
      ).apply(
        bodyColor: isDark ? darkOnSurface : lightOnSurface,
        displayColor: isDark ? darkOnSurface : lightOnSurface,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    textTheme: textTheme,
    scaffoldBackgroundColor: isDark ? darkScaffold : lightScaffold,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? darkScaffold : Colors.white,
      foregroundColor: isDark ? darkOnSurface : lightOnSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: isDark ? darkOnSurface : lightOnSurface,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: isDark ? darkSurface : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isDark ? darkBorder : lightBorder),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: isDark ? darkFill : Colors.white,
      side: BorderSide(color: isDark ? darkBorder : lightBorder),
      selectedColor: brand,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: isDark ? darkMuted : lightMuted,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? darkSurface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w800,
        color: isDark ? darkOnSurface : lightOnSurface,
      ),
      contentTextStyle: TextStyle(
        fontSize: 14,
        color: isDark ? darkMuted : lightMuted,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      contentTextStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: isDark ? darkOnSurface : lightOnSurface,
      unselectedLabelColor: isDark ? darkMuted : lightMuted,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      unselectedLabelStyle:
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      indicatorColor: brand,
      dividerColor: isDark ? darkBorder : lightBorder,
      indicatorSize: TabBarIndicatorSize.label,
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? darkBorder : lightBorder,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? darkFill : lightFill,
      hintStyle: TextStyle(color: isDark ? darkHint : lightHint, fontSize: 14),
      labelStyle: TextStyle(color: isDark ? darkMuted : lightMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
            color: isDark ? darkOutlineField : lightOutlineField),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
            color: isDark ? darkOutlineField : lightOutlineField),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: brand, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isDark ? darkSurface : Colors.white,
      indicatorColor: isDark ? const Color(0xFF0E2B42) : const Color(0xFFDCEBF7),
      elevation: 0,
      height: 62,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? darkSurface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: isDark ? darkSurface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: TextStyle(
          fontSize: 14, color: isDark ? darkOnSurface : lightOnSurface),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: isDark ? darkMuted : lightMuted,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: brand,
      selectionColor: brand.withValues(alpha: 0.30),
      selectionHandleColor: brand,
    ),
  );
}
