import 'dart:convert';

import 'package:flutter/material.dart';

class AppThemePalette {
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color card;
  final Color cardHover;
  final Color elevated;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;
  final Color accent;

  const AppThemePalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.card,
    required this.cardHover,
    required this.elevated,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.accent,
  });

  factory AppThemePalette.fromJson(Map<String, dynamic> json) {
    int parse(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    const defaults = defaultPalette;
    return AppThemePalette(
      background: Color(parse('background') | defaults.background.toARGB32()),
      surface: Color(parse('surface') | defaults.surface.toARGB32()),
      surfaceAlt: Color(parse('surfaceAlt') | defaults.surfaceAlt.toARGB32()),
      card: Color(parse('card') | defaults.card.toARGB32()),
      cardHover: Color(parse('cardHover') | defaults.cardHover.toARGB32()),
      elevated: Color(parse('elevated') | defaults.elevated.toARGB32()),
      border: Color(parse('border') | defaults.border.toARGB32()),
      borderStrong: Color(
        parse('borderStrong') | defaults.borderStrong.toARGB32(),
      ),
      textPrimary: Color(
        parse('textPrimary') | defaults.textPrimary.toARGB32(),
      ),
      textSecondary: Color(
        parse('textSecondary') | defaults.textSecondary.toARGB32(),
      ),
      textFaint: Color(parse('textFaint') | defaults.textFaint.toARGB32()),
      accent: Color(parse('accent') | defaults.accent.toARGB32()),
    );
  }

  Map<String, int> toJson() => {
    'background': background.toARGB32(),
    'surface': surface.toARGB32(),
    'surfaceAlt': surfaceAlt.toARGB32(),
    'card': card.toARGB32(),
    'cardHover': cardHover.toARGB32(),
    'elevated': elevated.toARGB32(),
    'border': border.toARGB32(),
    'borderStrong': borderStrong.toARGB32(),
    'textPrimary': textPrimary.toARGB32(),
    'textSecondary': textSecondary.toARGB32(),
    'textFaint': textFaint.toARGB32(),
    'accent': accent.toARGB32(),
  };

  String encode() => jsonEncode(toJson());

  AppThemePalette copyWith({Map<String, Color>? colors}) {
    return AppThemePalette(
      background: colors?['background'] ?? background,
      surface: colors?['surface'] ?? surface,
      surfaceAlt: colors?['surfaceAlt'] ?? surfaceAlt,
      card: colors?['card'] ?? card,
      cardHover: colors?['cardHover'] ?? cardHover,
      elevated: colors?['elevated'] ?? elevated,
      border: colors?['border'] ?? border,
      borderStrong: colors?['borderStrong'] ?? borderStrong,
      textPrimary: colors?['textPrimary'] ?? textPrimary,
      textSecondary: colors?['textSecondary'] ?? textSecondary,
      textFaint: colors?['textFaint'] ?? textFaint,
      accent: colors?['accent'] ?? accent,
    );
  }
}

const defaultPalette = AppThemePalette(
  background: Color(0xFF0B0C10),
  surface: Color(0xFF12141A),
  surfaceAlt: Color(0xFF161922),
  card: Color(0xFF151821),
  cardHover: Color(0xFF1A1E29),
  elevated: Color(0xFF1D212C),
  border: Color(0xFF242833),
  borderStrong: Color(0xFF333947),
  textPrimary: Color(0xFFECEEF2),
  textSecondary: Color(0xFFA6ACB8),
  textFaint: Color(0xFF6C7280),
  accent: Color(0xFF3DDC97),
);

abstract final class AppColors {
  static Color background = defaultPalette.background;
  static Color surface = defaultPalette.surface;
  static Color surfaceAlt = defaultPalette.surfaceAlt;
  static Color card = defaultPalette.card;
  static Color cardHover = defaultPalette.cardHover;
  static Color elevated = defaultPalette.elevated;

  static Color border = defaultPalette.border;
  static Color borderStrong = defaultPalette.borderStrong;

  static Color textPrimary = defaultPalette.textPrimary;
  static Color textSecondary = defaultPalette.textSecondary;
  static Color textFaint = defaultPalette.textFaint;

  static Color accent = defaultPalette.accent;
  static Color get accentHover => Color.lerp(accent, Colors.white, 0.12)!;
  static Color get accentMuted => accent.withValues(alpha: 0.18);
  static Color get accentBorder => accent.withValues(alpha: 0.34);

  static const Color success = Color(0xFF3DDC97);
  static const Color warning = Color(0xFFF5B841);
  static const Color danger = Color(0xFFF0645C);
  static const Color dangerMuted = Color(0x26F0645C);
  static const Color info = Color(0xFF5B9DF7);

  static const Color terminalBackground = Color(0xFF0D0E12);
  static const Color terminalChrome = Color(0xFF14161D);

  static void applyPalette(AppThemePalette palette) {
    background = palette.background;
    surface = palette.surface;
    surfaceAlt = palette.surfaceAlt;
    card = palette.card;
    cardHover = palette.cardHover;
    elevated = palette.elevated;
    border = palette.border;
    borderStrong = palette.borderStrong;
    textPrimary = palette.textPrimary;
    textSecondary = palette.textSecondary;
    textFaint = palette.textFaint;
    accent = palette.accent;
  }
}

const List<Color> hostColorOptions = [
  Color(0xFF3DDC97),
  Color(0xFF5B9DF7),
  Color(0xFFB48BF2),
  Color(0xFFF0645C),
  Color(0xFFF5B841),
  Color(0xFF38C6D8),
  Color(0xFFF07CB8),
  Color(0xFF8B93A5),
];
