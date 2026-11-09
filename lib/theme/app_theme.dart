import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const bg       = Color(0xFF0B1120);
  static const bgCard   = Color(0xFF111827);
  static const bgLight  = Color(0xFFF3F6FB);
  static const accent   = Color(0xFF00CFA8);
  static const accentDim= Color(0x1A00CFA8);
  static const fg       = Color(0xFFE2E8F0);
  static const fgMid    = Color(0xFF94A3B8);
  static const fgMuted  = Color(0xFF4B5563);
  static const danger   = Color(0xFFEF4444);
  static const warn     = Color(0xFFF59E0B);
  static const ok       = Color(0xFF22C55E);
  static const cardBd   = Color(0x14FFFFFF);
}

class AppTheme {
  AppTheme._();
  static ThemeData buildTheme() => _buildTheme();
}

ThemeData _buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final text  = GoogleFonts.dmSansTextTheme(base.textTheme).apply(
    bodyColor: AppColors.fg, displayColor: AppColors.fg,
  );

  return base.copyWith(
    colorScheme: const ColorScheme.dark(
      primary:   AppColors.accent,
      surface:   AppColors.bgCard,
      onSurface: AppColors.fg,
      error:     AppColors.danger,
    ),
    scaffoldBackgroundColor: AppColors.bg,
    textTheme: text,
    cardTheme: CardThemeData(
      color:        AppColors.bgCard,
      elevation:    0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.cardBd),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.fg,
      elevation: 0,
      titleTextStyle: GoogleFonts.syne(
        fontSize: 20, fontWeight: FontWeight.w800,
        color: AppColors.fg, letterSpacing: -0.5,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor:  AppColors.accent,
        foregroundColor:  AppColors.bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.dmSans(fontWeight: FontWeight.w600, fontSize: 15),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
  );
}
