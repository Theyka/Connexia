import 'package:flutter/services.dart';

/// A key event described in the forms needed by the remote protocols.
class RemoteKeyEvent {
  const RemoteKeyEvent({
    required this.keysym,
    required this.scancode,
    required this.extended,
    required this.unicode,
  });

  /// X11 keysym (VNC).
  final int? keysym;

  /// PC set 1 scancode (RDP).
  final int? scancode;

  /// Whether the RDP scancode is an extended (E0-prefixed) key.
  final bool extended;

  /// Unicode codepoint for characters without a scancode (RDP).
  final int? unicode;

  bool get isEmpty => keysym == null && scancode == null && unicode == null;
}

class _ScanCode {
  const _ScanCode(this.code, [this.extended = false]);
  final int code;
  final bool extended;
}

/// US layout set-1 scancodes keyed by the unshifted ASCII character code.
const Map<int, int> _usScancodes = {
  0x60: 0x29, // `
  0x31: 0x02,
  0x32: 0x03,
  0x33: 0x04,
  0x34: 0x05,
  0x35: 0x06,
  0x36: 0x07,
  0x37: 0x08,
  0x38: 0x09,
  0x39: 0x0A,
  0x30: 0x0B,
  0x2D: 0x0C, // -
  0x3D: 0x0D, // =
  0x71: 0x10, // q
  0x77: 0x11,
  0x65: 0x12,
  0x72: 0x13,
  0x74: 0x14,
  0x79: 0x15,
  0x75: 0x16,
  0x69: 0x17,
  0x6F: 0x18,
  0x70: 0x19,
  0x5B: 0x1A, // [
  0x5D: 0x1B, // ]
  0x61: 0x1E, // a
  0x73: 0x1F,
  0x64: 0x20,
  0x66: 0x21,
  0x67: 0x22,
  0x68: 0x23,
  0x6A: 0x24,
  0x6B: 0x25,
  0x6C: 0x26,
  0x3B: 0x27, // ;
  0x27: 0x28, // '
  0x5C: 0x2B, // backslash
  0x7A: 0x2C, // z
  0x78: 0x2D,
  0x63: 0x2E,
  0x76: 0x2F,
  0x62: 0x30,
  0x6E: 0x31,
  0x6D: 0x32,
  0x2C: 0x33, // ,
  0x2E: 0x34, // .
  0x2F: 0x35, // /
};

/// Shifted ASCII characters mapped to their unshifted base character.
const Map<int, int> _shiftedBase = {
  0x7E: 0x60, // ~
  0x21: 0x31, // !
  0x40: 0x32,
  0x23: 0x33,
  0x24: 0x34,
  0x25: 0x35,
  0x5E: 0x36,
  0x26: 0x37,
  0x2A: 0x38,
  0x28: 0x39,
  0x29: 0x30,
  0x5F: 0x2D, // _
  0x2B: 0x3D, // +
  0x7B: 0x5B, // {
  0x7D: 0x5D, // }
  0x7C: 0x5C, // |
  0x3A: 0x3B, // :
  0x22: 0x27, // "
  0x3C: 0x2C, // <
  0x3E: 0x2E, // >
  0x3F: 0x2F, // ?
};

_ScanCode? _rdpSpecial(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.escape) return const _ScanCode(0x01);
  if (key == LogicalKeyboardKey.backspace) return const _ScanCode(0x0E);
  if (key == LogicalKeyboardKey.tab) return const _ScanCode(0x0F);
  if (key == LogicalKeyboardKey.insert) return const _ScanCode(0x52, true);
  if (key == LogicalKeyboardKey.delete) return const _ScanCode(0x53, true);
  if (key == LogicalKeyboardKey.home) return const _ScanCode(0x47, true);
  if (key == LogicalKeyboardKey.end) return const _ScanCode(0x4F, true);
  if (key == LogicalKeyboardKey.pageUp) return const _ScanCode(0x49, true);
  if (key == LogicalKeyboardKey.pageDown) return const _ScanCode(0x51, true);
  if (key == LogicalKeyboardKey.arrowLeft) return const _ScanCode(0x4B, true);
  if (key == LogicalKeyboardKey.arrowUp) return const _ScanCode(0x48, true);
  if (key == LogicalKeyboardKey.arrowRight) {
    return const _ScanCode(0x4D, true);
  }
  if (key == LogicalKeyboardKey.arrowDown) return const _ScanCode(0x50, true);
  return null;
}

int? _vncSpecial(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.backspace) return 0xFF08;
  if (key == LogicalKeyboardKey.tab) return 0xFF09;
  if (key == LogicalKeyboardKey.escape) return 0xFF1B;
  if (key == LogicalKeyboardKey.insert) return 0xFF63;
  if (key == LogicalKeyboardKey.delete) return 0xFFFF;
  if (key == LogicalKeyboardKey.home) return 0xFF50;
  if (key == LogicalKeyboardKey.end) return 0xFF57;
  if (key == LogicalKeyboardKey.pageUp) return 0xFF55;
  if (key == LogicalKeyboardKey.pageDown) return 0xFF56;
  if (key == LogicalKeyboardKey.arrowLeft) return 0xFF51;
  if (key == LogicalKeyboardKey.arrowUp) return 0xFF52;
  if (key == LogicalKeyboardKey.arrowRight) return 0xFF53;
  if (key == LogicalKeyboardKey.arrowDown) return 0xFF54;
  return null;
}

/// Map a Flutter [LogicalKeyboardKey] to the remote protocol representations.
RemoteKeyEvent mapKey(LogicalKeyboardKey key) {
  final scancode = _scancodeFor(key);
  final keysym = _keysymFor(key);
  final unicode = scancode == null ? _unicodeFor(key) : null;

  return RemoteKeyEvent(
    keysym: keysym,
    scancode: scancode?.code,
    extended: scancode?.extended ?? false,
    unicode: unicode,
  );
}

/// The unshifted ASCII code for a key, if any.
int? _asciiFor(LogicalKeyboardKey key) {
  final id = key.keyId;
  final ascii = id & 0xFF;
  if (id > 0xFF) return null;
  if (ascii < 0x20 || ascii > 0x7E) return null;
  return _shiftedBase[ascii] ?? ascii;
}

_ScanCode? _scancodeFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return const _ScanCode(0x1C);
  }
  if (key == LogicalKeyboardKey.shiftLeft) return const _ScanCode(0x2A);
  if (key == LogicalKeyboardKey.shiftRight) return const _ScanCode(0x36);
  if (key == LogicalKeyboardKey.controlLeft) return const _ScanCode(0x1D);
  if (key == LogicalKeyboardKey.controlRight) {
    return const _ScanCode(0x1D, true);
  }
  if (key == LogicalKeyboardKey.altLeft) return const _ScanCode(0x38);
  if (key == LogicalKeyboardKey.altRight) return const _ScanCode(0x38, true);
  if (key == LogicalKeyboardKey.metaLeft) return const _ScanCode(0x5B, true);
  if (key == LogicalKeyboardKey.metaRight) return const _ScanCode(0x5C, true);
  if (key == LogicalKeyboardKey.capsLock) return const _ScanCode(0x3A);
  if (key == LogicalKeyboardKey.space) return const _ScanCode(0x39);

  final fKey = _functionScanCode(key);
  if (fKey != null) return fKey;

  final special = _rdpSpecial(key);
  if (special != null) return special;

  final ascii = _asciiFor(key);
  if (ascii != null) {
    final code = _usScancodes[ascii];
    if (code != null) return _ScanCode(code);
  }
  return null;
}

_ScanCode? _functionScanCode(LogicalKeyboardKey key) {
  const fKeys = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
  ];
  final index = fKeys.indexOf(key);
  if (index >= 0) return _ScanCode(0x3B + index);
  if (key == LogicalKeyboardKey.f11) return const _ScanCode(0x57);
  if (key == LogicalKeyboardKey.f12) return const _ScanCode(0x58);
  return null;
}

int? _keysymFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return 0xFF0D;
  }
  if (key == LogicalKeyboardKey.shiftLeft) return 0xFFE1;
  if (key == LogicalKeyboardKey.shiftRight) return 0xFFE2;
  if (key == LogicalKeyboardKey.controlLeft) return 0xFFE3;
  if (key == LogicalKeyboardKey.controlRight) return 0xFFE4;
  if (key == LogicalKeyboardKey.altLeft) return 0xFFE9;
  if (key == LogicalKeyboardKey.altRight) return 0xFFEA;
  if (key == LogicalKeyboardKey.metaLeft) return 0xFFEB;
  if (key == LogicalKeyboardKey.metaRight) return 0xFFEC;
  if (key == LogicalKeyboardKey.capsLock) return 0xFFE5;
  if (key == LogicalKeyboardKey.space) return 0x20;

  final fKey = _functionKeysym(key);
  if (fKey != null) return fKey;

  final special = _vncSpecial(key);
  if (special != null) return special;

  final ascii = _asciiFor(key);
  if (ascii != null) return ascii;
  return null;
}

int? _unicodeFor(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.length == 1) {
    final code = label.codeUnitAt(0);
    if (code >= 0x20) return code;
  }
  if (key.keyId > 0xFF) return key.keyId;
  return null;
}

int? _functionKeysym(LogicalKeyboardKey key) {
  const fKeys = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ];
  final index = fKeys.indexOf(key);
  if (index >= 0) return 0xFFBE + index;
  return null;
}
