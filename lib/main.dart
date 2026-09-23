import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;

import 'app.dart';
import 'ui/state/providers.dart';
import 'ui/state/rust_engine.dart';

File get _errorLogFile =>
    File(p.join(Directory.systemTemp.path, 'connexia_errors.log'));

void _setupErrorLogging() {
  final log = _errorLogFile;
  final sink = log.openWrite(mode: FileMode.append);
  var closed = false;

  void write(String kind, String message) {
    final line =
        '[${DateTime.now().toIso8601String()}] $kind\n$message\n'
        '----------------------------------------\n';
    // ignore: avoid_print
    print(line.trim());
    if (closed) return;
    sink.write(line);
    sink.flush();
  }

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    write('FlutterError', details.toString());
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    write('PlatformDispatcher', '$error\n$stack');
    return false;
  };

  Future<void> flush() async {
    if (closed) return;
    closed = true;
    await sink.flush();
    await sink.close();
  }

  WidgetsBinding.instance.addObserver(_AppLifecycleLogFlusher(flush));
}

class _AppLifecycleLogFlusher with WidgetsBindingObserver {
  final Future<void> Function() flush;

  _AppLifecycleLogFlusher(this.flush);

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.detached) {
      await flush();
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RustEngine.init();

  final container = ProviderContainer();

  _setupErrorLogging();

  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  if (isDesktop) {
    await windowManager.ensureInitialized();

    final db = container.read(appDatabaseProvider);
    final options = WindowOptions(
      size: const Size(1280, 800),
      minimumSize: const Size(940, 600),
      center: true,
      title: 'Connexia',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: const Color(0xFF0B0C10),
    );

    final sizeFuture = db.getSetting('windowSize');
    final positionFuture = db.getSetting('windowPosition');
    final maximizedFuture = db.getSetting('windowMaximized');

    windowManager.waitUntilReadyToShow(options, () async {
      Size? savedSize;
      Offset? savedPosition;
      var savedMaximized = false;
      try {
        final sizeRaw = await sizeFuture;
        final posRaw = await positionFuture;
        final maximizedRaw = await maximizedFuture;
        savedMaximized = maximizedRaw == 'true';
        if (sizeRaw != null) {
          final parts = sizeRaw.split('x');
          if (parts.length == 2) {
            final width = double.tryParse(parts[0]);
            final height = double.tryParse(parts[1]);
            if (width != null &&
                height != null &&
                width >= 940 &&
                height >= 600) {
              savedSize = Size(width, height);
            }
          }
        }
        if (posRaw != null) {
          final parts = posRaw.split(',');
          if (parts.length == 2) {
            final x = double.tryParse(parts[0]);
            final y = double.tryParse(parts[1]);
            if (x != null && y != null) {
              savedPosition = Offset(x, y);
            }
          }
        }
      } catch (_) {}

      if (savedSize != null) {
        await windowManager.setSize(savedSize);
      }
      if (savedPosition != null) {
        await windowManager.setPosition(savedPosition);
      }

      var shown = false;
      void showWindow() {
        if (shown) return;
        shown = true;
        windowManager.show();
        windowManager.focus();

        if (savedMaximized) {
          windowManager.maximize();
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        showWindow();
      });
      Timer(const Duration(milliseconds: 600), showWindow);
    });
  }

  runApp(
    UncontrolledProviderScope(container: container, child: const ConnexiaApp()),
  );
}
