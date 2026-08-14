import 'package:flutter/foundation.dart';

import '../../core/db/database.dart';
class AppSettings {
  final String terminalTheme;
  final double fontSize;
  final int scrollback;
  final bool autoAcceptHostKeys;
  final int maxConcurrentConnects;

  const AppSettings({
    this.terminalTheme = 'Connexia',
    this.fontSize = 14,
    this.scrollback = 5000,
    this.autoAcceptHostKeys = false,
    this.maxConcurrentConnects = 4,
  });

  AppSettings copyWith({
    String? terminalTheme,
    double? fontSize,
    int? scrollback,
    bool? autoAcceptHostKeys,
    int? maxConcurrentConnects,
  }) {
    return AppSettings(
      terminalTheme: terminalTheme ?? this.terminalTheme,
      fontSize: fontSize ?? this.fontSize,
      scrollback: scrollback ?? this.scrollback,
      autoAcceptHostKeys: autoAcceptHostKeys ?? this.autoAcceptHostKeys,
      maxConcurrentConnects:
          maxConcurrentConnects ?? this.maxConcurrentConnects,
    );
  }
}

class SettingsController extends ChangeNotifier {
  static const _themeKey = 'terminalTheme';
  static const _fontSizeKey = 'fontSize';
  static const _scrollbackKey = 'scrollback';
  static const autoAcceptHostKeysKey = 'autoAcceptHostKeys';
  static const maxConcurrentConnectsKey = 'maxConcurrentConnects';

  static const int maxConcurrentConnectsMin = 1;
  static const int maxConcurrentConnectsMax = 100;

  final AppDatabase _db;
  AppSettings _settings;

  SettingsController(this._db, [AppSettings? initial])
      : _settings = initial ?? const AppSettings();

  AppSettings get settings => _settings;

  Future<void> load() async {
    String? theme;
    double? fontSize;
    int? scrollback;
    bool? autoAcceptHostKeys;
    int? maxConcurrentConnects;

    final themeRaw = await _db.getSetting(_themeKey);
    if (themeRaw != null && themeRaw != 'Default') theme = themeRaw;

    final fontSizeRaw = await _db.getSetting(_fontSizeKey);
    if (fontSizeRaw != null) fontSize = double.tryParse(fontSizeRaw);

    final scrollbackRaw = await _db.getSetting(_scrollbackKey);
    if (scrollbackRaw != null) scrollback = int.tryParse(scrollbackRaw);

    final autoAcceptRaw = await _db.getSetting(autoAcceptHostKeysKey);
    if (autoAcceptRaw != null) autoAcceptHostKeys = autoAcceptRaw == 'true';

    final maxConnRaw = await _db.getSetting(maxConcurrentConnectsKey);
    if (maxConnRaw != null) {
      final parsed = int.tryParse(maxConnRaw);
      if (parsed != null) {
        maxConcurrentConnects = parsed.clamp(
          maxConcurrentConnectsMin,
          maxConcurrentConnectsMax,
        );
      }
    }

    _settings = AppSettings(
      terminalTheme: theme ?? _settings.terminalTheme,
      fontSize: fontSize ?? _settings.fontSize,
      scrollback: scrollback ?? _settings.scrollback,
      autoAcceptHostKeys:
          autoAcceptHostKeys ?? _settings.autoAcceptHostKeys,
      maxConcurrentConnects:
          maxConcurrentConnects ?? _settings.maxConcurrentConnects,
    );
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    if (next.terminalTheme != _settings.terminalTheme) {
      await _db.setSetting(_themeKey, next.terminalTheme);
    }
    if (next.fontSize != _settings.fontSize) {
      await _db.setSetting(_fontSizeKey, next.fontSize.toString());
    }
    if (next.scrollback != _settings.scrollback) {
      await _db.setSetting(_scrollbackKey, next.scrollback.toString());
    }
    if (next.autoAcceptHostKeys != _settings.autoAcceptHostKeys) {
      await _db.setSetting(
        autoAcceptHostKeysKey,
        next.autoAcceptHostKeys.toString(),
      );
    }
    if (next.maxConcurrentConnects != _settings.maxConcurrentConnects) {
      await _db.setSetting(
        maxConcurrentConnectsKey,
        next.maxConcurrentConnects.toString(),
      );
    }
    _settings = next;
    notifyListeners();
  }
}
