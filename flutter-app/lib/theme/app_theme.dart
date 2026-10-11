import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Brand Colors
  static const Color primary = Color(0xFFFEA900); // Primary Accent
  static const Color secondary = Color(0xFF1A53FF); // Secondary Accent
  
  // Light Mode Colors
  static const Color background = Color(0xFFF7F4F1);
  static const Color surface = Color(0xFFFFFEFD);
  static const Color error = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
  static const Color success = Color(0xFF10B981);
  static const Color info = Color(0xFF3B82F6);
  static const Color border = Color(0xFFE5E7EB);
  static const Color textPrimary = Colors.black;
  static const Color textSecondary = Color(0xFF4B5563);

  // Dark Mode Colors
  static const Color darkBackground = Color(0xFF0A0A0A);
  static const Color darkSurface = Color(0xFF0f0f0f); // Slightly lighter than bg for cards
  static const Color darkBorder = Color(0xFF334155);
  static const Color darkTextPrimary = Colors.white;
  static const Color darkTextSecondary = Color(0xFF9CA3AF);

  static TextTheme _buildTextTheme(TextTheme base, Color primaryColor, Color secondaryColor) {
    return base.copyWith(
      displayLarge: GoogleFonts.urbanist(
        textStyle: base.displayLarge,
        color: primaryColor,
        fontWeight: FontWeight.bold,
      ),
      displayMedium: GoogleFonts.urbanist(
        textStyle: base.displayMedium,
        color: primaryColor,
        fontWeight: FontWeight.bold,
      ),
      displaySmall: GoogleFonts.urbanist(
        textStyle: base.displaySmall,
        color: primaryColor,
        fontWeight: FontWeight.bold,
      ),
      headlineMedium: GoogleFonts.urbanist(
        textStyle: base.headlineMedium,
        color: primaryColor,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: GoogleFonts.urbanist(
        textStyle: base.headlineSmall,
        color: primaryColor,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: GoogleFonts.urbanist(
        textStyle: base.titleLarge,
        color: primaryColor,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: GoogleFonts.urbanist(
        textStyle: base.titleMedium,
        color: primaryColor,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: GoogleFonts.manrope(
        textStyle: base.titleSmall,
        color: secondaryColor,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: GoogleFonts.manrope(
        textStyle: base.bodyLarge,
        color: primaryColor,
      ),
      bodyMedium: GoogleFonts.manrope(
        textStyle: base.bodyMedium,
        color: primaryColor,
      ),
      bodySmall: GoogleFonts.manrope(
        textStyle: base.bodySmall,
        color: secondaryColor,
      ),
      labelLarge: GoogleFonts.manrope(
        textStyle: base.labelLarge,
        color: primaryColor,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      primaryColor: primary,
      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        secondary: secondary,
        surface: surface,
        error: error,
        background: background,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background, // Match scaffold bg for seamless look
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.urbanist(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: GoogleFonts.manrope(color: textSecondary),
        hintStyle: GoogleFonts.manrope(color: textSecondary.withOpacity(0.7)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.black, // Black text on yellow primary
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.bold, fontSize: 16),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: secondary, // Use secondary blue for text buttons
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: primary.withOpacity(0.2),
        side: const BorderSide(color: border),
        labelStyle: GoogleFonts.manrope(color: textPrimary),
        secondaryLabelStyle: GoogleFonts.manrope(color: primary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      textTheme: _buildTextTheme(base.textTheme, textPrimary, textSecondary),
    );
  }

  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: darkBackground,
      primaryColor: primary,
      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        secondary: secondary,
        surface: darkSurface,
        error: error,
        background: darkBackground,
        brightness: Brightness.dark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkTextPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.urbanist(
          color: darkTextPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: GoogleFonts.manrope(color: darkTextSecondary),
        hintStyle: GoogleFonts.manrope(color: darkTextSecondary.withOpacity(0.7)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.bold, fontSize: 16),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary, // Use primary yellow for dark mode text buttons
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: darkBorder, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: darkSurface,
        selectedColor: primary.withOpacity(0.2),
        side: const BorderSide(color: darkBorder),
        labelStyle: GoogleFonts.manrope(color: darkTextPrimary),
        secondaryLabelStyle: GoogleFonts.manrope(color: primary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      textTheme: _buildTextTheme(base.textTheme, darkTextPrimary, darkTextSecondary),
    );
  }
}
