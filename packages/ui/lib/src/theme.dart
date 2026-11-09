import 'package:flutter/material.dart';

/// Цвета приложений. У пассажира основной цвет индиго, у водителя — бирюзовый.
class AppColors {
  AppColors._();
  static const passenger = Color(0xFF4F46E5);
  static const driver = Color(0xFF0F766E);
  static const text = Color(0xFF0F172A);
  static const muted = Color(0xFF64748B);
  static const line = Color(0xFFE2E8F0);
  static const surface = Color(0xFFF6F7FB);
  static const from = Color(0xFF16A34A);
  static const to = Color(0xFFDC2626);
  static const ok = Color(0xFF15803D);
  static const danger = Color(0xFFDC2626);
  static const star = Color(0xFFF59E0B);
  static const traffic = Color(0xFFB45309);
}

ThemeData buildTheme(Color primary) {
  final scheme = ColorScheme.fromSeed(seedColor: primary, primary: primary, surface: Colors.white);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.white,
    textTheme: Typography.blackMountainView.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.line)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    chipTheme: const ChipThemeData(shape: StadiumBorder(), side: BorderSide(color: AppColors.line)),
    dividerColor: AppColors.line,
  );
}
