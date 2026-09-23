import 'package:connexia/core/remote/key_mapping.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('letters map to a US scancode and lowercase keysym', () {
    final event = mapKey(LogicalKeyboardKey.keyA);
    expect(event.scancode, 0x1E);
    expect(event.extended, isFalse);
    expect(event.keysym, 0x61);
    expect(event.unicode, isNull);
  });

  test('digits map correctly', () {
    final event = mapKey(LogicalKeyboardKey.digit1);
    expect(event.scancode, 0x02);
    expect(event.keysym, 0x31);
  });

  test('shifted punctuation uses the unshifted scancode', () {
    expect(mapKey(LogicalKeyboardKey.exclamation).scancode, 0x02);
    expect(mapKey(LogicalKeyboardKey.question).scancode, 0x35);
    expect(mapKey(LogicalKeyboardKey.underscore).scancode, 0x0C);
  });

  test('arrow keys use extended RDP scancodes and X11 keysyms', () {
    final event = mapKey(LogicalKeyboardKey.arrowLeft);
    expect(event.scancode, 0x4B);
    expect(event.extended, isTrue);
    expect(event.keysym, 0xFF51);
    expect(event.unicode, isNull);
  });

  test('enter maps to the standard scancode and keysym', () {
    final event = mapKey(LogicalKeyboardKey.enter);
    expect(event.scancode, 0x1C);
    expect(event.extended, isFalse);
    expect(event.keysym, 0xFF0D);
  });

  test('modifiers map', () {
    expect(mapKey(LogicalKeyboardKey.shiftLeft).scancode, 0x2A);
    expect(mapKey(LogicalKeyboardKey.shiftLeft).keysym, 0xFFE1);
    expect(mapKey(LogicalKeyboardKey.controlRight).extended, isTrue);
    expect(mapKey(LogicalKeyboardKey.controlRight).keysym, 0xFFE4);
  });

  test('function keys map', () {
    expect(mapKey(LogicalKeyboardKey.f5).scancode, 0x3F);
    expect(mapKey(LogicalKeyboardKey.f11).scancode, 0x57);
    expect(mapKey(LogicalKeyboardKey.f12).keysym, 0xFFC9);
  });

  test('delete uses an extended scancode', () {
    final event = mapKey(LogicalKeyboardKey.delete);
    expect(event.scancode, 0x53);
    expect(event.extended, isTrue);
    expect(event.keysym, 0xFFFF);
  });
}
