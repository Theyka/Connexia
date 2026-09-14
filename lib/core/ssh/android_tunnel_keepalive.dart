import 'dart:io';

import 'package:flutter/services.dart';

const _androidChannel = MethodChannel('connexia/tunnels');
const _iosChannel = MethodChannel('connexia/ios_keepalive');

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
