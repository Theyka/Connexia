import 'dart:io';

/// Appends diagnostic lines to `%TEMP%\connexia_debug.log` so that
/// theme/rendering issues can be diagnosed from a user's machine without a
/// console attached. Never throws - logging must not break the app.
void writeDebugLog(String message) {
  try {
    final dir = Directory.systemTemp;
    final file =
        File('${dir.path}${Platform.pathSeparator}connexia_debug.log');
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Ignore: logging must never break the app.
  }
}
