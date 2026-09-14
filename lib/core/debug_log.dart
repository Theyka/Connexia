import 'dart:async';
import 'dart:io';

void writeDebugLog(String message) {
  try {
    final dir = Directory.systemTemp;
    final file = File('${dir.path}${Platform.pathSeparator}connexia_debug.log');
    final line = '${DateTime.now().toIso8601String()} $message\n';
    unawaited(() async {
      try {
        await file.writeAsString(line, mode: FileMode.append);
      } catch (_) {}
    }());
  } catch (_) {}
}
