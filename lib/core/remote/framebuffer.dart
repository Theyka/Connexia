import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// A mutable RGBA framebuffer that decodes to a [ui.Image] for painting.
///
/// Clients push rectangle updates with [apply] and call [flush] once per batch;
/// decoding is coalesced so a burst of rectangles results in a single image.
class Framebuffer extends ChangeNotifier {
  Framebuffer(this.width, this.height)
    : _pixels = Uint8List(width * height * 4);

  int width;
  int height;

  Uint8List _pixels;
  ui.Image? _image;
  bool _dirty = false;
  Timer? _decodeTimer;
  bool _decoding = false;
  bool _disposed = false;
  bool _visible = true;

  Uint8List get pixels => _pixels;
  ui.Image? get image => _image;

  void resize(int w, int h) {
    if (w <= 0 || h <= 0 || (w == width && h == height)) return;
    width = w;
    height = h;
    _pixels = Uint8List(w * h * 4);
    _dirty = true;
    _scheduleDecode();
  }

  /// Copy a tightly packed RGBA [src] rectangle into the framebuffer.
  void apply(int x, int y, int w, int h, Uint8List src) {
    if (w <= 0 || h <= 0) return;
    final expected = w * h * 4;
    final available = src.length;
    if (available < expected) return;
    for (var row = 0; row < h; row++) {
      final dy = y + row;
      if (dy < 0 || dy >= height) continue;
      final dstStart = (dy * width + x) * 4;
      final srcStart = row * w * 4;
      final copyLen = w * 4;
      if (dstStart + copyLen > _pixels.length) continue;
      _pixels.setRange(dstStart, dstStart + copyLen, src, srcStart);
    }
    _dirty = true;
  }

  /// Return a tightly packed RGBA copy of the requested region.
  Uint8List copyRegion(int x, int y, int w, int h) {
    final out = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      final dy = y + row;
      if (dy < 0 || dy >= height) continue;
      final srcStart = (dy * width + x) * 4;
      final dstStart = row * w * 4;
      if (srcStart + w * 4 > _pixels.length) continue;
      out.setRange(dstStart, dstStart + w * 4, _pixels, srcStart);
    }
    return out;
  }

  /// Replace the whole framebuffer contents with [src] (tightly packed RGBA).
  void replace(Uint8List src) {
    if (src.length < _pixels.length) return;
    _pixels.setRange(0, _pixels.length, src, 0);
    _dirty = true;
  }

  /// Schedule a decode of the accumulated changes.
  void flush() {
    if (!_dirty) return;
    _scheduleDecode();
  }

  /// Controls whether this framebuffer is currently on screen.
  ///
  /// Background sessions keep accumulating pixels via [apply], but decoding a
  /// full frame to a [ui.Image] is expensive; doing it for every open remote
  /// session (even the ones that are not visible) saturates the UI isolate and
  /// freezes the app. When the buffer becomes visible again the pending changes
  /// are decoded immediately.
  void setVisible(bool visible) {
    if (_visible == visible || _disposed) return;
    _visible = visible;
    if (_visible && _dirty) _scheduleDecode();
  }

  void _scheduleDecode() {
    if (_disposed) return;
    // Skip decoding while off screen; [setVisible] picks the pending changes
    // back up. Decode as soon as the event loop turns: the Rust engine already
    // coalesces updates on a 16ms cadence, so adding another timer here only
    // introduced up to 16ms of extra display latency per frame. If a decode is
    // already in flight it will pick up the new changes when it completes.
    if (!_visible) return;
    _decodeTimer ??= Timer(Duration.zero, _decodeNow);
  }

  void _decodeNow() {
    _decodeTimer = null;
    if (_disposed || _decoding || !_dirty) return;
    _dirty = false;
    _decoding = true;
    final buffer = Uint8List.fromList(_pixels);
    ui.decodeImageFromPixels(buffer, width, height, ui.PixelFormat.rgba8888, (
      image,
    ) {
      _decoding = false;
      if (_disposed) {
        image.dispose();
        return;
      }
      final old = _image;
      _image = image;
      old?.dispose();
      notifyListeners();
      if (_dirty) _scheduleDecode();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _decodeTimer?.cancel();
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
