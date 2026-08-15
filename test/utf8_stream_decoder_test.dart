import 'package:connexia/core/ssh/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('utf8 streaming decoder emits each chunk immediately', () {
    final decoder = Utf8StreamDecoder();
    expect(decoder.add('he'.codeUnits), 'he');
    expect(decoder.add('llo'.codeUnits), 'llo');
    expect(decoder.add(' world'.codeUnits), ' world');
  });

  test('utf8 streaming decoder recombines a CJK char split across chunks',
      () {
    final decoder = Utf8StreamDecoder();
    // 你 = E4 BD A0 (3 bytes)
    final you = [0xE4, 0xBD, 0xA0];
    final hello = 'hello'.codeUnits;

    expect(decoder.add(hello + [you[0]]), 'hello');
    expect(decoder.add([you[1]]), '');
    expect(decoder.add([you[2]] + hello), '你hello');
  });

  test('utf8 streaming decoder keeps a split banner intact', () {
    final decoder = Utf8StreamDecoder();
    const banner = 'Welcome to Ubuntu 24.04\r\n';
    final bytes = banner.codeUnits;
    final splitAt = 13;
    final part1 = decoder.add(bytes.sublist(0, splitAt));
    final part2 = decoder.add(bytes.sublist(splitAt));
    expect(part1 + part2, banner);
  });
}
