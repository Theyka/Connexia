import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Builds the Connexia dark theme (Inter UI font, muted teal accent).
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: const Color(0xFF0B1220),
    secondary: AppColors.accent,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    error: AppColors.danger,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: AppColors.background,
  );

  final textTheme = base.textTheme.apply(
    fontFamily: 'Inter',
    bodyColor: AppColors.textPrimary,
    displayColor: AppColors.textPrimary,
  );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: AppColors.border),
  );

  return base.copyWith(
    textTheme: textTheme,
    dividerColor: AppColors.border,
    dividerTheme: DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    canvasColor: AppColors.surface,
    cardColor: AppColors.card,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceAlt,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: TextStyle(color: AppColors.textFaint, fontSize: 13),
      labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 13),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: AppColors.accent),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: AppColors.textPrimary,
      iconColor: AppColors.textSecondary,
      selectedColor: AppColors.accent,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        color: AppColors.textSecondary,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.elevated,
      surfaceTintColor: Colors.transparent,
      textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.elevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border),
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 13.5,
        color: AppColors.textSecondary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: const Color(0xFF0B1220),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        side: BorderSide(color: AppColors.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        disabledForegroundColor: AppColors.textFaint,
        iconSize: 20,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.elevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderStrong),
      ),
      textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.elevated,
      contentTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        color: AppColors.textPrimary,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.borderStrong),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(
        AppColors.borderStrong.withValues(alpha: 0.8),
      ),
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(4),
    ),
  );
}
