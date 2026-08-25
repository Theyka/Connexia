import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/db/database.dart';
import '../../core/shortcuts.dart';
class AppSettings {
  final String terminalTheme;
  final double fontSize;
  final int scrollback;
  final bool autoAcceptHostKeys;
  final int maxConcurrentConnects;

  /// Custom shortcut bindings keyed by action id (see [AppShortcut.id]).
  /// A missing key means the built-in default binding is used.
  final Map<String, String> customShortcuts;

  const AppSettings({
    this.terminalTheme = 'Connexia',
    this.fontSize = 14,
    this.scrollback = 5000,
    this.autoAcceptHostKeys = false,
    this.maxConcurrentConnects = 4,
    this.customShortcuts = const {},
  });

  AppSettings copyWith({
    String? terminalTheme,
    double? fontSize,
    int? scrollback,
    bool? autoAcceptHostKeys,
    int? maxConcurrentConnects,
    Map<String, String>? customShortcuts,
  }) {
    return AppSettings(
      terminalTheme: terminalTheme ?? this.terminalTheme,
      fontSize: fontSize ?? this.fontSize,
      scrollback: scrollback ?? this.scrollback,
      autoAcceptHostKeys: autoAcceptHostKeys ?? this.autoAcceptHostKeys,
      maxConcurrentConnects:
          maxConcurrentConnects ?? this.maxConcurrentConnects,
      customShortcuts: customShortcuts ?? this.customShortcuts,
    );
  }
}

class SettingsController extends ChangeNotifier {
  static const _themeKey = 'terminalTheme';
  static const _fontSizeKey = 'fontSize';
  static const _scrollbackKey = 'scrollback';
  static const autoAcceptHostKeysKey = 'autoAcceptHostKeys';
  static const maxConcurrentConnectsKey = 'maxConcurrentConnects';
  static const customShortcutsKey = 'customShortcuts';

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

    Map<String, String> customShortcuts = const {};
    final shortcutsRaw = await _db.getSetting(customShortcutsKey);
    if (shortcutsRaw != null && shortcutsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(shortcutsRaw);
        if (decoded is Map) {
          customShortcuts = {
            for (final entry in decoded.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          };
        }
      } catch (_) {
        customShortcuts = const {};
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
      customShortcuts: customShortcuts,
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
    if (!mapEquals(next.customShortcuts, _settings.customShortcuts)) {
      await _db.setSetting(
        customShortcutsKey,
        jsonEncode(next.customShortcuts),
      );
    }
    _settings = next;
    notifyListeners();
  }
}
