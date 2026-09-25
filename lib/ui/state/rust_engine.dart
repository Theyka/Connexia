import 'package:flutter/foundation.dart';

import '../../src/rust/api/rdp.dart' as rust;
import '../../src/rust/frb_generated.dart';

export '../../src/rust/api/rdp.dart';

/// Thin wrapper around the Rust bridge that owns global initialisation and
/// availability state. RDP sessions are only enabled once the native bridge is
/// up.
class RustEngine {
  RustEngine._();

  static bool _available = false;
  static Object? _error;

  static bool get available => _available;
  static Object? get error => _error;

  static Future<void> init() async {
    try {
      await RustLib.init();
      _available = true;
      _error = null;
    } catch (e) {
      _available = false;
      _error = e;
      debugPrint('Rust engine unavailable: $e');
    }
  }

  static void _ensureAvailable() {
    if (!_available) {
      throw StateError('RDP support is not available on this device');
    }
  }

  static Stream<rust.RdpEvent> startRdp({
    required String sessionId,
    required rust.RdpConnectOptions options,
  }) {
    _ensureAvailable();
    return rust.rdpStart(sessionId: sessionId, options: options);
  }

  static void sendKey({
    required String sessionId,
    required int scancode,
    required bool pressed,
    required bool extended,
  }) {
    if (!_available) return;
    rust.rdpSendKey(
      sessionId: sessionId,
      scancode: scancode,
      pressed: pressed,
      extended: extended,
    );
  }

  static void sendUnicode({
    required String sessionId,
    required int codepoint,
    required bool pressed,
  }) {
    if (!_available) return;
    rust.rdpSendUnicode(
      sessionId: sessionId,
      codepoint: codepoint,
      pressed: pressed,
    );
  }

  static void sendPointer({
    required String sessionId,
    required int x,
    required int y,
    required int buttons,
    required int wheel,
  }) {
    if (!_available) return;
    rust.rdpSendPointer(
      sessionId: sessionId,
      x: x,
      y: y,
      buttons: buttons,
      wheel: wheel,
    );
  }

  static void setVisible({required String sessionId, required bool visible}) {
    if (!_available) return;
    rust.rdpSetVisible(sessionId: sessionId, visible: visible).ignore();
  }

  static void cancelRdpClipboardTransfer({required String sessionId}) {
    if (!_available) return;
    rust.rdpCancelClipboardTransfer(sessionId: sessionId).ignore();
  }

  static void closeRdp({required String sessionId}) {
    if (!_available) return;
    rust.rdpClose(sessionId: sessionId);
  }
}
