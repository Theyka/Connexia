import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../ui/theme/app_colors.dart';

class TerminalThemePreset {
  final String name;
  final TerminalTheme theme;

  const TerminalThemePreset(this.name, this.theme);
}

/// Terminal color schemes from https://terminalcolors.com (default variant
/// of each family), plus the built-in Connexia theme at the top.
final List<TerminalThemePreset> terminalThemePresets = [
  TerminalThemePreset('Connexia', _connexia),
  TerminalThemePreset('Apprentice', _apprentice),
  TerminalThemePreset('Ayu Dark', _ayuDark),
  TerminalThemePreset('Catppuccin Mocha', _catppuccinMocha),
  TerminalThemePreset('Cobalt2', _cobalt2),
  TerminalThemePreset('Deus', _deus),
  TerminalThemePreset('Dracula', _dracula),
  TerminalThemePreset('Everforest Dark', _everforestDark),
  TerminalThemePreset('GitHub Dark', _githubDark),
  TerminalThemePreset('Gotham', _gotham),
  TerminalThemePreset('Gruvbox Dark', _gruvboxDark),
  TerminalThemePreset('Iceberg Dark', _icebergDark),
  TerminalThemePreset('Jellybeans', _jellybeans),
  TerminalThemePreset('Kanagawa Wave', _kanagawaWave),
  TerminalThemePreset('Lucario', _lucario),
  TerminalThemePreset('Miasma', _miasma),
  TerminalThemePreset('Moonfly', _moonfly),
  TerminalThemePreset('Night Owl Dark', _nightOwlDark),
  TerminalThemePreset('Nightfly', _nightfly),
  TerminalThemePreset('Nightfox', _nightfox),
  TerminalThemePreset('Noctis', _noctis),
  TerminalThemePreset('Nord', _nord),
  TerminalThemePreset('Nordic', _nordic),
  TerminalThemePreset('One Dark', _oneDark),
  TerminalThemePreset('One Half Dark', _oneHalfDark),
  TerminalThemePreset('Panda', _panda),
  TerminalThemePreset('Posterpole', _posterpole),
  TerminalThemePreset('Rosé Pine', _rosePine),
  TerminalThemePreset('Seoul256 Dark', _seoul256Dark),
  TerminalThemePreset('Shades of Purple', _shadesOfPurple),
  TerminalThemePreset('Solarized Dark', _solarizedDark),
  TerminalThemePreset('Sonokai', _sonokai),
  TerminalThemePreset('Srcery', _srcery),
  TerminalThemePreset('Tender', _tender),
  TerminalThemePreset('Tokyo Night', _tokyoNight),
  TerminalThemePreset('Tomorrow Night', _tomorrowNight),
  TerminalThemePreset('Zenbones Zenwritten Dark', _zenbones),
];

/// Builds a theme from the standard 20-value ANSI palette (in the order
/// used by terminalcolors.com downloads): foreground, background, cursor,
/// selection, 8 normal colors, 8 bright colors. Search hits use the theme's
/// yellow/blue pair so they stay visible on any background.
TerminalTheme _tc(
  int fg, int bg, int cursor, int selection,
  int black, int red, int green, int yellow,
  int blue, int magenta, int cyan, int white,
  int bblack, int bred, int bgreen, int byellow,
  int bblue, int bmagenta, int bcyan, int bwhite,
) =>
    TerminalTheme(
      cursor: Color(cursor),
      selection: Color(selection),
      foreground: Color(fg),
      background: Color(bg),
      black: Color(black),
      red: Color(red),
      green: Color(green),
      yellow: Color(yellow),
      blue: Color(blue),
      magenta: Color(magenta),
      cyan: Color(cyan),
      white: Color(white),
      brightBlack: Color(bblack),
      brightRed: Color(bred),
      brightGreen: Color(bgreen),
      brightYellow: Color(byellow),
      brightBlue: Color(bblue),
      brightMagenta: Color(bmagenta),
      brightCyan: Color(bcyan),
      brightWhite: Color(bwhite),
      searchHitBackground: Color(yellow),
      searchHitBackgroundCurrent: Color(blue),
      searchHitForeground: Color(bg),
    );

/// The Connexia theme uses the app's own palette, so it stays in sync with
/// custom user palettes. Green/blue/yellow search hits match the app accent.
final TerminalTheme _connexia = TerminalTheme(
  cursor: AppColors.accent,
  selection: AppColors.accent.withValues(alpha: 0.25),
  foreground: AppColors.textPrimary,
  background: AppColors.background,
  black: AppColors.surfaceAlt,
  red: AppColors.danger,
  green: AppColors.accent,
  yellow: AppColors.warning,
  blue: AppColors.info,
  magenta: const Color(0xFFB48BF2),
  cyan: const Color(0xFF38C6D8),
  white: AppColors.textSecondary,
  brightBlack: AppColors.textFaint,
  brightRed: const Color(0xFFFF857C),
  brightGreen: const Color(0xFF5CE8A5),
  brightYellow: const Color(0xFFFFC95C),
  brightBlue: const Color(0xFF74A9FB),
  brightMagenta: const Color(0xFFC49DF6),
  brightCyan: const Color(0xFF4FD0E0),
  brightWhite: AppColors.textPrimary,
  searchHitBackground: AppColors.warning,
  searchHitBackgroundCurrent: AppColors.info,
  searchHitForeground: AppColors.background,
);

final TerminalTheme _apprentice = _tc(
  0xFFBCBCBC, 0xFF262626, 0xFFBCBCBC, 0xFF87AFD7,
  0xFF1C1C1C, 0xFFAF5F5F, 0xFF5F875F, 0xFF87875F,
  0xFF5F87AF, 0xFF5F5F87, 0xFF5F8787, 0xFF6C6C6C,
  0xFF444444, 0xFFFF8700, 0xFF87AF87, 0xFFFFFAAF,
  0xFF87AFD7, 0xFF8787AF, 0xFF5FAFAF, 0xFFFFFFFF,
);

final TerminalTheme _ayuDark = _tc(
  0xFFBFBDB6, 0xFF0B0E14, 0xFFBFBDB6, 0xFF1B3A5B,
  0xFF1E232B, 0xFFEA6C73, 0xFF7FD962, 0xFFF9AF4F,
  0xFF53BDFA, 0xFFCDA1FA, 0xFF90E1C6, 0xFFC7C7C7,
  0xFF686868, 0xFFF07178, 0xFFAAD94C, 0xFFFFB454,
  0xFF59C2FF, 0xFFD2A6FF, 0xFF95E6CB, 0xFFFFFFFF,
);

final TerminalTheme _catppuccinMocha = _tc(
  0xFFCDD6F4, 0xFF1E1E2E, 0xFFF5E0DC, 0xFF353748,
  0xFF45475A, 0xFFF38BA8, 0xFFA6E3A1, 0xFFF9E2AF,
  0xFF89B4FA, 0xFFF5C2E7, 0xFF94E2D5, 0xFFA6ADC8,
  0xFF585B70, 0xFFF37799, 0xFF89D88B, 0xFFEBD391,
  0xFF74A8FC, 0xFFF2AEDE, 0xFF6BD7CA, 0xFFBAC2DE,
);

final TerminalTheme _cobalt2 = _tc(
  0xFFFFFFFF, 0xFF122738, 0xFFFFFFFF, 0xFF0050A4,
  0xFF000000, 0xFFFF628C, 0xFF3AD900, 0xFFFFC600,
  0xFF0088FF, 0xFFFB94FF, 0xFF80FCFF, 0xFFFFFFFF,
  0xFF0050A4, 0xFFFF628C, 0xFF3AD900, 0xFFFFC600,
  0xFF0088FF, 0xFFFB94FF, 0xFF80FCFF, 0xFFFFFFFF,
);

final TerminalTheme _deus = _tc(
  0xFFEAEAEA, 0xFF2C323B, 0xFFEAEAEA, 0xFFEAEAEA,
  0xFF242A32, 0xFFD54E53, 0xFF98C379, 0xFFE5C07B,
  0xFF83A598, 0xFFC678DD, 0xFF70C0BA, 0xFFEAEAEA,
  0xFF666666, 0xFFEC3E45, 0xFF90C966, 0xFFEDBF69,
  0xFF73BA9F, 0xFFC858E9, 0xFF2BCEC2, 0xFFFFFFFF,
);

final TerminalTheme _dracula = _tc(
  0xFFF8F8F2, 0xFF282A36, 0xFFF8F8F2, 0xFF44475A,
  0xFF21222C, 0xFFFF5555, 0xFF50FA7B, 0xFFF1FA8C,
  0xFFBD93F9, 0xFFFF79C6, 0xFF8BE9FD, 0xFFF8F8F2,
  0xFF6272A4, 0xFFFF6E6E, 0xFF69FF94, 0xFFFFFAA5,
  0xFFD6ACFF, 0xFFFF92DF, 0xFFA4FFFF, 0xFFFFFFFF,
);

final TerminalTheme _everforestDark = _tc(
  0xFFD3C6AA, 0xFF2D353B, 0xFFD3C6AA, 0xFF414B51,
  0xFF343F44, 0xFFE67E80, 0xFFA7C080, 0xFFDBBC7F,
  0xFF7FBBB3, 0xFFD699B6, 0xFF83C092, 0xFFD3C6AA,
  0xFF859289, 0xFFE67E80, 0xFFA7C080, 0xFFDBBC7F,
  0xFF7FBBB3, 0xFFD699B6, 0xFF83C092, 0xFFD3C6AA,
);

final TerminalTheme _githubDark = _tc(
  0xFFE6EDF3, 0xFF010409, 0xFFE6EDF3, 0xFF264F78,
  0xFF484F58, 0xFFFF7B72, 0xFF3FB950, 0xFFD29922,
  0xFF58A6FF, 0xFFBC8CFF, 0xFF39C5CF, 0xFFB1BAC4,
  0xFF6E7681, 0xFFFFA198, 0xFF56D364, 0xFFE3B341,
  0xFF79C0FF, 0xFFD2A8FF, 0xFF56D4DD, 0xFFFFFFFF,
);

final TerminalTheme _gotham = _tc(
  0xFF99D1CE, 0xFF0C1014, 0xFF99D1CE, 0xFF0A3749,
  0xFF0C1014, 0xFFC23127, 0xFF2AA889, 0xFFEDB443,
  0xFF195466, 0xFF4E5166, 0xFF33859E, 0xFF99D1CE,
  0xFF0C1014, 0xFFC23127, 0xFF2AA889, 0xFFEDB443,
  0xFF195466, 0xFF4E5166, 0xFF33859E, 0xFF99D1CE,
);

final TerminalTheme _gruvboxDark = _tc(
  0xFFEBDBB2, 0xFF282828, 0xFFEBDBB2, 0xFFEBDBB2,
  0xFF282828, 0xFFCC241D, 0xFF98971A, 0xFFD79921,
  0xFF458588, 0xFFB16286, 0xFF689D6A, 0xFFA89984,
  0xFF928374, 0xFFFB4934, 0xFFB8BB26, 0xFFFABD2F,
  0xFF83A598, 0xFFD3869B, 0xFF8EC07C, 0xFFEBDBB2,
);

final TerminalTheme _icebergDark = _tc(
  0xFFC6C8D1, 0xFF161821, 0xFFC6C8D1, 0xFF272C42,
  0xFF1E2132, 0xFFE27878, 0xFFB4BE82, 0xFFE2A478,
  0xFF84A0C6, 0xFFA093C7, 0xFF89B8C2, 0xFFC6C8D1,
  0xFF6B7089, 0xFFE98989, 0xFFC0CA8E, 0xFFE9B189,
  0xFF91ACD1, 0xFFADA0D3, 0xFF95C4CE, 0xFFD2D4DE,
);

final TerminalTheme _jellybeans = _tc(
  0xFFDEDEDE, 0xFF121212, 0xFFFFA560, 0xFF474E91,
  0xFF929292, 0xFFE27373, 0xFF94B979, 0xFFFFBA7B,
  0xFF97BEDC, 0xFFE1C0FA, 0xFF00988E, 0xFFDEDEDE,
  0xFFBDBDBD, 0xFFFFA1A1, 0xFFBDDEAB, 0xFFFFDCA0,
  0xFFB1D8F6, 0xFFFBDAFF, 0xFF1AB2A8, 0xFFFFFFFF,
);

final TerminalTheme _kanagawaWave = _tc(
  0xFFDCD7BA, 0xFF1F1F28, 0xFFDCD7BA, 0xFF2D4F67,
  0xFF16161D, 0xFFC34043, 0xFF76946A, 0xFFC0A36E,
  0xFF7E9CD8, 0xFF957FB8, 0xFF6A9589, 0xFFC8C093,
  0xFF727169, 0xFFE82424, 0xFF98BB6C, 0xFFE6C384,
  0xFF7FB4CA, 0xFF938AA9, 0xFF7AA89F, 0xFFDCD7BA,
);

final TerminalTheme _lucario = _tc(
  0xFFF8F8F2, 0xFF2B3E50, 0xFFF8F8F2, 0xFFF8F8F2,
  0xFF19242F, 0xFFE94B35, 0xFF199C4B, 0xFFF0CC04,
  0xFF5C98CD, 0xFFCA94FF, 0xFF8BE0FD, 0xFFF8F8F2,
  0xFF2F3943, 0xFFFF6541, 0xFF72CC5A, 0xFFFFFAA5,
  0xFFD6ACFF, 0xFFD4A9FF, 0xFFB9ECFD, 0xFFFFFFFF,
);

final TerminalTheme _miasma = _tc(
  0xFFC2C2B0, 0xFF222222, 0xFFC7C7C7, 0xFFE5C47B,
  0xFF000000, 0xFF685742, 0xFF5F875F, 0xFFB36D43,
  0xFF78824B, 0xFFBB7744, 0xFFC9A554, 0xFFD7C483,
  0xFF666666, 0xFF685742, 0xFF5F875F, 0xFFB36D43,
  0xFF78824B, 0xFFBB7744, 0xFFC9A554, 0xFFD7C483,
);

final TerminalTheme _moonfly = _tc(
  0xFFBDBDBD, 0xFF080808, 0xFF9E9E9E, 0xFFB2CEEE,
  0xFF323437, 0xFFFF5454, 0xFF8CC85F, 0xFFE3C78A,
  0xFF80A0FF, 0xFFCF87E8, 0xFF79DAC8, 0xFFC6C6C6,
  0xFF949494, 0xFFFF5189, 0xFF36C692, 0xFFC6C684,
  0xFF74B2FF, 0xFFAE81FF, 0xFF85DC85, 0xFFE4E4E4,
);

final TerminalTheme _nightOwlDark = _tc(
  0xFFCCCCCC, 0xFF011627, 0xFFCCCCCC, 0xFF093B5E,
  0xFF011627, 0xFFEF5350, 0xFF22DA6E, 0xFFC5E478,
  0xFF82AAFF, 0xFFC792EA, 0xFF21C7A8, 0xFFFFFFFF,
  0xFF575656, 0xFFEF5350, 0xFF22DA6E, 0xFFFFEB95,
  0xFF82AAFF, 0xFFC792EA, 0xFF7FDBCA, 0xFFFFFFFF,
);

final TerminalTheme _nightfly = _tc(
  0xFFBDC1C6, 0xFF011627, 0xFF9CA1AA, 0xFFB2CEEE,
  0xFF1D3B53, 0xFFFC514E, 0xFFA1CD5E, 0xFFE7D37A,
  0xFF82AAFF, 0xFFC792EA, 0xFF7FDBCA, 0xFFA1AAB8,
  0xFF7C8F8F, 0xFFFF5874, 0xFF21C7A8, 0xFFECC48D,
  0xFF82AAFF, 0xFFAE81FF, 0xFF7FDBCA, 0xFFD6DEEB,
);

final TerminalTheme _nightfox = _tc(
  0xFFCDCECF, 0xFF192330, 0xFFCDCECF, 0xFF2B3B51,
  0xFF393B44, 0xFFC94F6D, 0xFF81B29A, 0xFFDBC074,
  0xFF719CD6, 0xFF9D79D6, 0xFF63CDCF, 0xFFDFDFE0,
  0xFF575860, 0xFFD16983, 0xFF8EBAA4, 0xFFE0C989,
  0xFF86ABDC, 0xFFBAA1E2, 0xFF7AD5D6, 0xFFE4E4E5,
);

final TerminalTheme _noctis = _tc(
  0xFFB2CACD, 0xFF03191B, 0xFFB2CACD, 0xFF083D44,
  0xFF324A4D, 0xFFE66533, 0xFF49E9A6, 0xFFE4B781,
  0xFF49ACE9, 0xFFDF769B, 0xFF49D6E9, 0xFFB2CACD,
  0xFF47686C, 0xFFE97749, 0xFF60EBB1, 0xFFE69533,
  0xFF60B6EB, 0xFFE798B3, 0xFF60DBEB, 0xFFC1D4D7,
);

final TerminalTheme _nord = _tc(
  0xFFD8DEE9, 0xFF2E3440, 0xFFD8DEE9, 0xFF3F4758,
  0xFF3B4252, 0xFFBF616A, 0xFFA3BE8C, 0xFFEBCB8B,
  0xFF81A1C1, 0xFFB48EAD, 0xFF88C0D0, 0xFFE5E9F0,
  0xFF4C566A, 0xFFBF616A, 0xFFA3BE8C, 0xFFEBCB8B,
  0xFF81A1C1, 0xFFB48EAD, 0xFF8FBCBB, 0xFFECEFF4,
);

final TerminalTheme _nordic = _tc(
  0xFFBBC3D4, 0xFF242933, 0xFFBBC3D4, 0xFF1B1F26,
  0xFF191D24, 0xFFBF616A, 0xFFA3BE8C, 0xFFEBCB8B,
  0xFF5E81AC, 0xFFB48EAD, 0xFF8FBCBB, 0xFFBBC3D4,
  0xFF3B4252, 0xFFC5727A, 0xFFB1C89D, 0xFFEFD49F,
  0xFF88C0D0, 0xFFBE9D88, 0xFF9FC6C5, 0xFFD8DEE9,
);

final TerminalTheme _oneDark = _tc(
  0xFFABB2BF, 0xFF282C34, 0xFFABB2BF, 0xFFABB2BF,
  0xFF1E2127, 0xFFE06C75, 0xFF98C379, 0xFFD19A66,
  0xFF61AFEF, 0xFFC678DD, 0xFF56B6C2, 0xFFABB2BF,
  0xFF5C6370, 0xFFE06C75, 0xFF98C379, 0xFFD19A66,
  0xFF61AFEF, 0xFFC678DD, 0xFF56B6C2, 0xFFFFFFFF,
);

final TerminalTheme _oneHalfDark = _tc(
  0xFFDCDFE4, 0xFF282C34, 0xFFA3B3CC, 0xFF474E5D,
  0xFF282C34, 0xFFE06C75, 0xFF98C379, 0xFFE5C07B,
  0xFF61AFEF, 0xFFC678DD, 0xFF56B6C2, 0xFFDCDFE4,
  0xFF282C34, 0xFFE06C75, 0xFF98C379, 0xFFE5C07B,
  0xFF61AFEF, 0xFFC678DD, 0xFF56B6C2, 0xFFDCDFE4,
);

final TerminalTheme _panda = _tc(
  0xFFCCCCCC, 0xFF292A2B, 0xFFCCCCCC, 0xFF5F4E3B,
  0xFF000000, 0xFFFF2C6D, 0xFF19F9D8, 0xFFFFB86C,
  0xFF45A9F9, 0xFFFF75B5, 0xFFB084EB, 0xFFCDCDCD,
  0xFF757575, 0xFFFF2C6D, 0xFF19F9D8, 0xFFFFCC95,
  0xFF6FC1FF, 0xFFFF9AC1, 0xFFBCAAFE, 0xFFE6E6E6,
);

final TerminalTheme _posterpole = _tc(
  0xFFC6C0B9, 0xFF25222A, 0xFFC6C0B9, 0xFF4D4D4D,
  0xFF2C2C30, 0xFFA97070, 0xFF778C73, 0xFFCC9166,
  0xFF6C7F93, 0xFFB894AF, 0xFF8EA4A2, 0xFFAFA79D,
  0xFFA5A59C, 0xFFBC8F8F, 0xFF92A38F, 0xFFD9AC8C,
  0xFF8A99A8, 0xFFCCB3C6, 0xFFAABBBA, 0xFFC6C0B9,
);

final TerminalTheme _rosePine = _tc(
  0xFFE0DEF4, 0xFF1F1D2E, 0xFFE0DEF4, 0xFF2F2C40,
  0xFF26233A, 0xFFEB6F92, 0xFF31748F, 0xFFF6C177,
  0xFF9CCFD8, 0xFFC4A7E7, 0xFFEBBCBA, 0xFFE0DEF4,
  0xFF908CAA, 0xFFEB6F92, 0xFF31748F, 0xFFF6C177,
  0xFF9CCFD8, 0xFFC4A7E7, 0xFFEBBCBA, 0xFFE0DEF4,
);

final TerminalTheme _seoul256Dark = _tc(
  0xFFD0D0D0, 0xFF3A3A3A, 0xFFD0D0D0, 0xFF005F5F,
  0xFF4E4E4E, 0xFFD68787, 0xFF5F865F, 0xFFD8AF5F,
  0xFF85ADD4, 0xFFD7AFAF, 0xFF87AFAF, 0xFFD0D0D0,
  0xFF626262, 0xFFD75F87, 0xFF87AF87, 0xFFFFD787,
  0xFFADD4FB, 0xFFFFAFAF, 0xFF87D7D7, 0xFFE4E4E4,
);

final TerminalTheme _shadesOfPurple = _tc(
  0xFFFFFFFF, 0xFF1E1E3F, 0xFFFFFFFF, 0xFF6D42A5,
  0xFF000000, 0xFFE43937, 0xFF3AD900, 0xFFFAD000,
  0xFF7857FE, 0xFFFF2C70, 0xFF80FCFF, 0xFFFFFFFF,
  0xFF5C5C61, 0xFFE43937, 0xFF3AD900, 0xFFFAD000,
  0xFF6943FF, 0xFFFB94FF, 0xFF80FCFF, 0xFFFFFFFF,
);

final TerminalTheme _solarizedDark = _tc(
  0xFF839496, 0xFF002B36, 0xFF839496, 0xFF073642,
  0xFF073642, 0xFFDC322F, 0xFF859900, 0xFFB58900,
  0xFF268BD2, 0xFFD33682, 0xFF2AA198, 0xFFEEE8D5,
  0xFF002B36, 0xFFCB4B16, 0xFF586E75, 0xFF657B83,
  0xFF839496, 0xFF6C71C4, 0xFF93A1A1, 0xFFFDF6E3,
);

final TerminalTheme _sonokai = _tc(
  0xFFE2E2E3, 0xFF2C2E34, 0xFFE2E2E3, 0xFF3B3E48,
  0xFF181819, 0xFFFC5D7C, 0xFF9ED072, 0xFFE7C664,
  0xFF76CCE0, 0xFFB39DF3, 0xFFF39660, 0xFFE2E2E3,
  0xFF7F8490, 0xFFFC5D7C, 0xFF9ED072, 0xFFE7C664,
  0xFF76CCE0, 0xFFB39DF3, 0xFFF39660, 0xFFE2E2E3,
);

final TerminalTheme _srcery = _tc(
  0xFFFCE8C3, 0xFF1C1B19, 0xFFFBB829, 0xFFFCE8C3,
  0xFF1C1B19, 0xFFEF2F27, 0xFF519F50, 0xFFFBB829,
  0xFF2C78BF, 0xFFE02C6D, 0xFF0AAEB3, 0xFFBAA67F,
  0xFF918175, 0xFFF75341, 0xFF98BC37, 0xFFFED06E,
  0xFF68A8E4, 0xFFFF5C8F, 0xFF2BE4D0, 0xFFFCE8C3,
);

final TerminalTheme _tender = _tc(
  0xFFEEEEEE, 0xFF282828, 0xFFEEEEEE, 0xFF293B44,
  0xFF282828, 0xFFF43753, 0xFFC9D05C, 0xFFFFC24B,
  0xFFB3DEEF, 0xFFD3B987, 0xFF73CEF4, 0xFFEEEEEE,
  0xFF1D1D1D, 0xFFF43753, 0xFFC9D05C, 0xFFFFC24B,
  0xFFB3DEEF, 0xFFD3B987, 0xFF73CEF4, 0xFFFFFFFF,
);

final TerminalTheme _tokyoNight = _tc(
  0xFFC0CAF5, 0xFF1A1B26, 0xFFC0CAF5, 0xFF283457,
  0xFF15161E, 0xFFF7768E, 0xFF9ECE6A, 0xFFE0AF68,
  0xFF7AA2F7, 0xFFBB9AF7, 0xFF7DCFFF, 0xFFA9B1D6,
  0xFF414868, 0xFFF7768E, 0xFF9ECE6A, 0xFFE0AF68,
  0xFF7AA2F7, 0xFFBB9AF7, 0xFF7DCFFF, 0xFFC0CAF5,
);

final TerminalTheme _tomorrowNight = _tc(
  0xFFC5C8C6, 0xFF1D1F21, 0xFFC5C8C6, 0xFF373B41,
  0xFF000000, 0xFFCC6666, 0xFFB5BD68, 0xFFF0C674,
  0xFF81A2BE, 0xFFB294BB, 0xFF8ABEB7, 0xFFFFFFFF,
  0xFF000000, 0xFFCC6666, 0xFFB5BD68, 0xFFF0C674,
  0xFF81A2BE, 0xFFB294BB, 0xFF8ABEB7, 0xFFFFFFFF,
);

final TerminalTheme _zenbones = _tc(
  0xFFBBBBBB, 0xFF191919, 0xFFC9C9C9, 0xFF404040,
  0xFF191919, 0xFFDE6E7C, 0xFF819B69, 0xFFB77E64,
  0xFF6099C0, 0xFFB279A7, 0xFF66A5AD, 0xFFBBBBBB,
  0xFF3D3839, 0xFFE8838F, 0xFF8BAE68, 0xFFD68C67,
  0xFF61ABDA, 0xFFCF86C1, 0xFF65B8C1, 0xFF8E8E8E,
);

TerminalThemePreset terminalThemeByName(String name) {
  for (final preset in terminalThemePresets) {
    if (preset.name == name) return preset;
  }
  return terminalThemePresets.first;
}
