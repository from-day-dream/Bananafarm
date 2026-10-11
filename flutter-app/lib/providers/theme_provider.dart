import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import '../services/local_storage_service.dart';

enum ThemeMode { light, dark, system }

extension ThemeModeExtension on ThemeMode {
  String get value {
    switch (this) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static ThemeMode fromString(String value) {
    switch (value.toLowerCase()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.system;
    }
  }
}

/// Theme provider that manages light/dark mode
final themeProvider = rp.StateNotifierProvider<ThemeNotifier, ThemeMode>(
  (ref) {
    return ThemeNotifier();
  },
);

/// Provider to check if dark mode is enabled
final isDarkModeProvider = rp.Provider<bool>((ref) {
  final themeMode = ref.watch(themeProvider);
  return themeMode == ThemeMode.dark;
});

class ThemeNotifier extends rp.StateNotifier<ThemeMode> {
  late LocalStorageService _storageService;
  bool _initialized = false;

  ThemeNotifier() : super(ThemeMode.dark);

  /// Initialize theme from local storage
  Future<void> initialize(LocalStorageService storageService) async {
    if (_initialized) return;

    _storageService = storageService;
    final savedTheme = _storageService.getThemePreference();
    if (savedTheme != null) {
      state = ThemeModeExtension.fromString(savedTheme);
    } else {
      // Default to Dark if no preference saved
      state = ThemeMode.dark;
    }
    _initialized = true;
  }

  /// Set theme mode to light
  Future<void> setLight() async {
    state = ThemeMode.light;
    await _storageService.setThemePreference(ThemeMode.light.value);
  }

  /// Set theme mode to dark
  Future<void> setDark() async {
    state = ThemeMode.dark;
    await _storageService.setThemePreference(ThemeMode.dark.value);
  }

  /// Set theme mode to system default
  Future<void> setSystem() async {
    state = ThemeMode.system;
    await _storageService.setThemePreference(ThemeMode.system.value);
  }

  /// Get current theme mode
  ThemeMode getCurrentTheme() {
    return state;
  }

  /// Check if currently in dark mode
  bool isDarkMode() {
    if (state == ThemeMode.dark) return true;
    if (state == ThemeMode.light) return false;
    // For system mode, we would check MediaQueryData, but this requires BuildContext
    return false;
  }
}
