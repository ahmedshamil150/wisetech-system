import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set in `main()` from the stored preference before the first frame.
ThemeMode initialThemeMode = ThemeMode.light;

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => initialThemeMode;

  void set(ThemeMode mode) {
    state = mode;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString('themeMode', mode.name));
  }

  void toggle() => set(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
