import 'dart:async';
import 'dart:io';

/// Appends diagnostic lines to `%TEMP%\connexia_debug.log` so that
/// theme/rendering issues can be diagnosed from a user's machine without a
/// console attached. Never throws - logging must not break the app.
///
/// The write is fire-and-forget: this used to be a synchronous flushed
/// write on the calling thread, and it is called from widget build methods
/// (app build, terminal builds) - synchronous disk I/O on the UI thread
/// caused visible jank.
void writeDebugLog(String message) {
  try {
    final dir = Directory.systemTemp;
    final file =
        File('${dir.path}${Platform.pathSeparator}connexia_debug.log');
    final line = '${DateTime.now().toIso8601String()} $message\n';
    unawaited(() async {
      try {
        await file.writeAsString(line, mode: FileMode.append);
      } catch (_) {
        // Ignore: logging must never break the app.
      }
    }());
  } catch (_) {
    // Ignore: logging must never break the app.
  }
}
