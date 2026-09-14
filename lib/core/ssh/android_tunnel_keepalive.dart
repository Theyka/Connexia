import 'dart:io';

import 'package:flutter/services.dart';

const _androidChannel = MethodChannel('connexia/tunnels');
const _iosChannel = MethodChannel('connexia/ios_keepalive');

/// Keeps the app's network stack alive while tunnels are supposed to run.
///
/// Android: holds a foreground service with a persistent notification.
/// Without it, aggressive ROMs (MIUI, EMUI, ...) suspend or kill the app
/// minutes after it is backgrounded: every SSH socket dies, and tunnels
/// keep reporting "running" while forwarded connections fail. With the
/// service held, the process keeps network + CPU access in the background.
///
/// iOS: requests a background task (~30 s of guaranteed runtime) when the
/// app leaves the foreground. iOS suspends the process within seconds
/// otherwise, which is exactly the "switch to Chrome and load the URL"
/// scenario; the background task covers short switches. Longer than that
/// requires a Network Extension (paid Apple account) — a local notification
/// then tells the user to reopen the app.
class AndroidTunnelKeepAlive {
  static bool _active = false;

  static Future<void> activate() async {
    if (_active) return;
    _active = true;
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<void>('keepAliveStart');
      } else if (Platform.isIOS) {
        await _iosChannel.invokeMethod<void>('keepAliveStart');
      }
    } catch (_) {
      // Never block tunnel operation on the keep-alive.
      _active = false;
    }
  }

  static Future<void> deactivate() async {
    if (!_active) return;
    _active = false;
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<void>('keepAliveStop');
      } else if (Platform.isIOS) {
        await _iosChannel.invokeMethod<void>('keepAliveStop');
      }
    } catch (_) {}
  }
}
