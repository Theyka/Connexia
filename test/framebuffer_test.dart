import 'dart:typed_data';

import 'package:connexia/core/remote/framebuffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('apply writes a rectangle into the correct location', () {
    final fb = Framebuffer(4, 3);
    final rect = Uint8List.fromList([
      1, 2, 3, 4, 5, 6, 7, 8, // row 0
      9, 10, 11, 12, 13, 14, 15, 16, // row 1
    ]);
    fb.apply(1, 1, 2, 2, rect);

    int pixel(int x, int y) {
      final index = (y * 4 + x) * 4;
      return fb.pixels[index];
    }

    expect(pixel(0, 0), 0);
    expect(pixel(1, 1), 1);
    expect(pixel(2, 1), 5);
    expect(pixel(1, 2), 9);
    expect(pixel(2, 2), 13);
    expect(pixel(3, 2), 0);
  });

  test('copyRegion returns a tightly packed region', () {
    final fb = Framebuffer(3, 2);
    final full = Uint8List.fromList(List.generate(24, (i) => i + 1));
    fb.replace(full);

    final region = fb.copyRegion(1, 0, 2, 2);
    expect(region.length, 2 * 2 * 4);
    expect(region.sublist(0, 4), [5, 6, 7, 8]);
    expect(region.sublist(4, 8), [9, 10, 11, 12]);
  });

  test('resize clears the framebuffer', () {
    final fb = Framebuffer(2, 2);
    fb.replace(Uint8List.fromList(List.generate(16, (i) => i + 1)));
    fb.resize(4, 4);
    expect(fb.width, 4);
    expect(fb.height, 4);
    expect(fb.pixels.length, 4 * 4 * 4);
    expect(fb.pixels.every((byte) => byte == 0), isTrue);
  });
}
