import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class AppShortcut {
  final String id;
  final String label;
  final String defaultBinding;

  const AppShortcut({
    required this.id,
    required this.label,
    required this.defaultBinding,
  });
}

ShortcutChord? resolveShortcut(Map<String, String> customShortcuts, String id) {
  for (final s in appShortcuts) {
    if (s.id == id) {
      final binding = customShortcuts[id] ?? s.defaultBinding;
      return ShortcutChord.parse(binding);
    }
  }
  return null;
}

const List<AppShortcut> appShortcuts = [
  AppShortcut(
    id: 'newWindow',
    label: 'New window',
    defaultBinding: 'Ctrl+Shift+N',
  ),
  AppShortcut(
    id: 'editCard',
    label: 'Edit card under cursor',
    defaultBinding: 'E',
  ),
  AppShortcut(
    id: 'search',
    label: 'Toggle find in terminal',
    defaultBinding: 'Ctrl+Shift+F',
  ),
  AppShortcut(
    id: 'copy',
    label: 'Copy selection',
    defaultBinding: 'Ctrl+Shift+C',
  ),
  AppShortcut(
    id: 'paste',
    label: 'Paste clipboard',
    defaultBinding: 'Ctrl+Shift+V',
  ),
  AppShortcut(id: 'zoomIn', label: 'Zoom in', defaultBinding: 'Ctrl+='),
  AppShortcut(id: 'zoomOut', label: 'Zoom out', defaultBinding: 'Ctrl+-'),
  AppShortcut(id: 'zoomReset', label: 'Reset zoom', defaultBinding: 'Ctrl+0'),
];

class ShortcutChord {
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;
  final LogicalKeyboardKey key;

  const ShortcutChord({
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    required this.key,
  });

  static ShortcutChord? parse(String binding) {
    final parts = binding
        .split('+')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    var control = false;
    var shift = false;
    var alt = false;
    var meta = false;
    String? keyPart;
    for (final part in parts) {
      switch (part.toLowerCase()) {
        case 'ctrl':
        case 'control':
          control = true;
          break;
        case 'shift':
          shift = true;
          break;
        case 'alt':
          alt = true;
          break;
        case 'meta':
        case 'win':
        case 'cmd':
          meta = true;
          break;
        default:
          keyPart = part;
      }
    }
    if (keyPart == null) return null;
    final key = _keyFromToken(keyPart);
    if (key == null) return null;
    return ShortcutChord(
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
      key: key,
    );
  }

  String format() {
    final out = <String>[];
    if (control) out.add('Ctrl');
    if (shift) out.add('Shift');
    if (alt) out.add('Alt');
    if (meta) out.add('Meta');
    out.add(_keyToken(key));
    return out.join('+');
  }

  static ShortcutChord fromCurrentState(
    HardwareKeyboard hk,
    LogicalKeyboardKey pressed,
  ) {
    return ShortcutChord(
      control: hk.isControlPressed,
      shift: hk.isShiftPressed,
      alt: hk.isAltPressed,
      meta: hk.isMetaPressed,
      key: pressed,
    );
  }

  SingleActivator toActivator() => SingleActivator(
    key,
    control: control,
    shift: shift,
    alt: alt,
    meta: meta,
  );

  bool matches(HardwareKeyboard hk, LogicalKeyboardKey pressed) {
    return hk.isControlPressed == control &&
        hk.isShiftPressed == shift &&
        hk.isAltPressed == alt &&
        hk.isMetaPressed == meta &&
        pressed == key;
  }

  static LogicalKeyboardKey? _keyFromToken(String token) {
    final lower = token.toLowerCase();
    final letter = _letterKeys[lower];
    if (letter != null) return letter;
    final digit = _digitKeys[lower];
    if (digit != null) return digit;
    switch (lower) {
      case '=':
      case 'plus':
        return LogicalKeyboardKey.equal;
      case '-':
      case 'minus':
        return LogicalKeyboardKey.minus;
      case 'space':
        return LogicalKeyboardKey.space;
      case 'enter':
      case 'return':
        return LogicalKeyboardKey.enter;
      case 'tab':
        return LogicalKeyboardKey.tab;
      case 'escape':
      case 'esc':
        return LogicalKeyboardKey.escape;
      case 'backspace':
        return LogicalKeyboardKey.backspace;
      case 'delete':
        return LogicalKeyboardKey.delete;
      case 'home':
        return LogicalKeyboardKey.home;
      case 'end':
        return LogicalKeyboardKey.end;
      case 'pageup':
        return LogicalKeyboardKey.pageUp;
      case 'pagedown':
        return LogicalKeyboardKey.pageDown;
      case 'up':
        return LogicalKeyboardKey.arrowUp;
      case 'down':
        return LogicalKeyboardKey.arrowDown;
      case 'left':
        return LogicalKeyboardKey.arrowLeft;
      case 'right':
        return LogicalKeyboardKey.arrowRight;
      default:
        return null;
    }
  }

  static const Map<String, LogicalKeyboardKey> _letterKeys = {
    'a': LogicalKeyboardKey.keyA,
    'b': LogicalKeyboardKey.keyB,
    'c': LogicalKeyboardKey.keyC,
    'd': LogicalKeyboardKey.keyD,
    'e': LogicalKeyboardKey.keyE,
    'f': LogicalKeyboardKey.keyF,
    'g': LogicalKeyboardKey.keyG,
    'h': LogicalKeyboardKey.keyH,
    'i': LogicalKeyboardKey.keyI,
    'j': LogicalKeyboardKey.keyJ,
    'k': LogicalKeyboardKey.keyK,
    'l': LogicalKeyboardKey.keyL,
    'm': LogicalKeyboardKey.keyM,
    'n': LogicalKeyboardKey.keyN,
    'o': LogicalKeyboardKey.keyO,
    'p': LogicalKeyboardKey.keyP,
    'q': LogicalKeyboardKey.keyQ,
    'r': LogicalKeyboardKey.keyR,
    's': LogicalKeyboardKey.keyS,
    't': LogicalKeyboardKey.keyT,
    'u': LogicalKeyboardKey.keyU,
    'v': LogicalKeyboardKey.keyV,
    'w': LogicalKeyboardKey.keyW,
    'x': LogicalKeyboardKey.keyX,
    'y': LogicalKeyboardKey.keyY,
    'z': LogicalKeyboardKey.keyZ,
  };

  static const Map<String, LogicalKeyboardKey> _digitKeys = {
    '0': LogicalKeyboardKey.digit0,
    '1': LogicalKeyboardKey.digit1,
    '2': LogicalKeyboardKey.digit2,
    '3': LogicalKeyboardKey.digit3,
    '4': LogicalKeyboardKey.digit4,
    '5': LogicalKeyboardKey.digit5,
    '6': LogicalKeyboardKey.digit6,
    '7': LogicalKeyboardKey.digit7,
    '8': LogicalKeyboardKey.digit8,
    '9': LogicalKeyboardKey.digit9,
  };

  static String _keyToken(LogicalKeyboardKey key) {
    switch (key) {
      case LogicalKeyboardKey.equal:
        return '=';
      case LogicalKeyboardKey.minus:
        return '-';
      default:
        final label = key.keyLabel;
        if (label.length == 1) return label.toUpperCase();
        return key.debugName ?? '?';
    }
  }
}
