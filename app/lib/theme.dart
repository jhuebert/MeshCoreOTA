import 'package:flutter/material.dart';

/// MeshCoreOTA visual identity: deep slate with a signal-amber accent.
/// Deliberately quiet — this is a tools app, not a consumer product.
class OtaTheme {
  static const background = Color(0xFF0F1420);
  static const surface = Color(0xFF171E2E);
  static const surfaceHigh = Color(0xFF1F2937);
  static const accent = Color(0xFFF59E0B); // signal amber
  static const accentDim = Color(0xFF92600B);
  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFF87171);
  static const textMuted = Color(0xFF94A3B8);

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Color(0xFF1A1203),
      secondary: Color(0xFF38BDF8),
      surface: surface,
      onSurface: Color(0xFFE2E8F0),
      error: bad,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardTheme: const CardThemeData(
        color: surface,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: Color(0xFFE2E8F0),
        elevation: 0,
        centerTitle: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF1A1203),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          minimumSize: const Size.fromHeight(48),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFE2E8F0),
          minimumSize: const Size.fromHeight(48),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: Color(0xFFE2E8F0)),
      ),
    );
  }
}
