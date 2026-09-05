import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the Android process alive while tunnels are supposed to run by
/// holding a foreground service with a persistent notification.
///
/// Without it, aggressive ROMs (MIUI, EMUI, ...) suspend or kill the app
/// minutes after it is backgrounded: every SSH socket dies, and tunnels
/// keep reporting "running" while forwarded connections fail. With the
/// service held, the process keeps network + CPU access in the background.
class AndroidTunnelKeepAlive {
  static const _channel = MethodChannel('connexia/tunnels');

  static bool _active = false;

  static Future<void> activate() async {
    if (!Platform.isAndroid || _active) return;
    _active = true;
    try {
      await _channel.invokeMethod<void>('keepAliveStart');
    } catch (_) {
      // Never block tunnel operation on the keep-alive.
      _active = false;
    }
  }

  static Future<void> deactivate() async {
    if (!Platform.isAndroid || !_active) return;
    _active = false;
    try {
      await _channel.invokeMethod<void>('keepAliveStop');
    } catch (_) {}
  }
}
