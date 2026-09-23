import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// Minimal RFB (VNC) client.
///
/// Supports the None and classic VNC (DES) authentication methods, raw and
/// copy-rectangle encodings, desktop resize, keyboard/pointer input and
/// clipboard (CutText) exchange.
class RfbClient {
  RfbClient({
    required this.onFramebufferUpdate,
    required this.onDesktopResize,
    required this.onClipboard,
    required this.onClosed,
    required this.onError,
    required this.readRegion,
  });

  final void Function(int x, int y, int w, int h, Uint8List pixels)
  onFramebufferUpdate;
  final void Function(int width, int height) onDesktopResize;
  final void Function(String text) onClipboard;
  final void Function() onClosed;
  final void Function(String message) onError;
  final Uint8List Function(int x, int y, int w, int h) readRegion;

  Socket? _socket;
  _ByteReader? _reader;
  bool _closed = false;
  int _width = 0;
  int _height = 0;

  int get width => _width;
  int get height => _height;

  Future<void> connect(String host, int port, String password) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _reader = _ByteReader(socket);

    final version = await _readVersion();
    _socket!.add(utf8.encode('RFB 003.008\n'));

    await _authenticate(version, password);

    // ClientInit with shared flag.
    _socket!.add([1]);

    await _readServerInit();

    // Request a convenient 32-bit RGBA pixel format.
    _sendSetPixelFormat();
    // Advertise the encodings we understand.
    _sendSetEncodings(const [0, 1, -223]);
    _requestUpdate(incremental: false);

    unawaited(_messageLoop());
  }

  Future<String> _readVersion() async {
    final bytes = await _reader!.read(12);
    return latin1.decode(bytes);
  }

  Future<void> _authenticate(String version, String password) async {
    final major = int.tryParse(version.substring(4, 7)) ?? 3;
    final minor = int.tryParse(version.substring(8, 11)) ?? 8;

    if (major == 3 && minor >= 7) {
      final count = (await _reader!.read(1))[0];
      if (count == 0) {
        final reasonLen = _readU32(await _reader!.read(4));
        final reason = utf8.decode(await _reader!.read(reasonLen));
        throw RfbException(reason.isEmpty ? 'Authentication failed' : reason);
      }
      final types = await _reader!.read(count);
      if (types.contains(1)) {
        _socket!.add([1]);
      } else if (types.contains(2)) {
        _socket!.add([2]);
        await _vncAuth(password);
      } else {
        throw RfbException('Server offered no supported authentication method');
      }
    } else {
      final type = _readU32(await _reader!.read(4));
      if (type == 0) {
        final reasonLen = _readU32(await _reader!.read(4));
        final reason = utf8.decode(await _reader!.read(reasonLen));
        throw RfbException(reason.isEmpty ? 'Authentication failed' : reason);
      } else if (type == 1) {
        // None.
      } else if (type == 2) {
        await _vncAuth(password);
      } else {
        throw RfbException('Unsupported security type $type');
      }
    }
  }

  Future<void> _vncAuth(String password) async {
    final challenge = await _reader!.read(16);
    final key = _vncKey(password);
    // Triple DES with three identical keys is equivalent to single DES, which
    // is what the classic VNC authentication scheme requires.
    final key24 = Uint8List(24);
    key24.setRange(0, 8, key);
    key24.setRange(8, 16, key);
    key24.setRange(16, 24, key);
    final engine = pc.ECBBlockCipher(pc.DESedeEngine())
      ..init(true, pc.KeyParameter(key24));
    final response = Uint8List(16);
    for (var block = 0; block < 2; block++) {
      engine.processBlock(challenge, block * 8, response, block * 8);
    }
    _socket!.add(response);

    final result = _readU32(await _reader!.read(4));
    if (result != 0) {
      throw RfbException('VNC authentication failed');
    }
  }

  Future<void> _readServerInit() async {
    final header = await _reader!.read(20);
    _width = (header[0] << 8) | header[1];
    _height = (header[2] << 8) | header[3];
    onDesktopResize(_width, _height);

    final nameLen = _readU32(await _reader!.read(4));
    await _reader!.read(nameLen);
  }

  void _sendSetPixelFormat() {
    final msg = BytesBuilder();
    msg.addByte(0); // SetPixelFormat
    msg.add([0, 0, 0]); // padding
    // 32bpp, 24 depth, little-endian, true colour, max 255, RGBA shifts.
    msg.add([32, 24, 0, 1]);
    msg.add([0, 255]); // red max
    msg.add([0, 255]); // green max
    msg.add([0, 255]); // blue max
    msg.add([0, 8, 16]); // red, green, blue shifts
    msg.add([0, 0, 0]); // padding
    _socket!.add(msg.takeBytes());
  }

  void _sendSetEncodings(List<int> encodings) {
    final msg = BytesBuilder();
    msg.addByte(2); // SetEncodings
    msg.addByte(0); // padding
    msg.add([(encodings.length >> 8) & 0xFF, encodings.length & 0xFF]);
    for (final e in encodings) {
      msg.add([(e >> 24) & 0xFF, (e >> 16) & 0xFF, (e >> 8) & 0xFF, e & 0xFF]);
    }
    _socket!.add(msg.takeBytes());
  }

  void _requestUpdate({
    required bool incremental,
    int? x,
    int? y,
    int? w,
    int? h,
  }) {
    final msg = Uint8List(10);
    msg[0] = 3; // FramebufferUpdateRequest
    msg[1] = incremental ? 1 : 0;
    final rx = x ?? 0;
    final ry = y ?? 0;
    final rw = w ?? _width;
    final rh = h ?? _height;
    msg[2] = (rx >> 8) & 0xFF;
    msg[3] = rx & 0xFF;
    msg[4] = (ry >> 8) & 0xFF;
    msg[5] = ry & 0xFF;
    msg[6] = (rw >> 8) & 0xFF;
    msg[7] = rw & 0xFF;
    msg[8] = (rh >> 8) & 0xFF;
    msg[9] = rh & 0xFF;
    _socket!.add(msg);
  }

  Future<void> _messageLoop() async {
    try {
      while (!_closed) {
        final type = (await _reader!.read(1))[0];
        switch (type) {
          case 0:
            await _readFramebufferUpdate();
          case 1:
            await _skipColourMap();
          case 2:
            // Bell.
            await _reader!.read(0);
          case 3:
            await _readServerCutText();
          default:
            throw RfbException('Unsupported server message $type');
        }
      }
    } on RfbException catch (e) {
      if (!_closed) onError(e.message);
    } catch (e) {
      if (!_closed) onError('$e');
    } finally {
      if (!_closed) {
        _closed = true;
        onClosed();
      }
    }
  }

  Future<void> _readFramebufferUpdate() async {
    await _reader!.read(1); // padding
    final rectCount = _readU16(await _reader!.read(2));
    for (var i = 0; i < rectCount; i++) {
      final header = await _reader!.read(12);
      final x = _readU16(header.sublist(0, 2));
      final y = _readU16(header.sublist(2, 4));
      final w = _readU16(header.sublist(4, 6));
      final h = _readU16(header.sublist(6, 8));
      final encoding = _readI32(header.sublist(8, 12));

      if (encoding == 0) {
        final pixels = await _reader!.read(w * h * 4);
        _forceOpaque(pixels);
        onFramebufferUpdate(x, y, w, h, pixels);
      } else if (encoding == 1) {
        final src = await _reader!.read(4);
        final srcX = _readU16(src.sublist(0, 2));
        final srcY = _readU16(src.sublist(2, 4));
        onFramebufferUpdate(x, y, w, h, readRegion(srcX, srcY, w, h));
      } else if (encoding == -223) {
        onDesktopResize(w, h);
        _width = w;
        _height = h;
      } else if (encoding == -239) {
        // Cursor pseudo-encoding: pixels + bitmask.
        await _reader!.read(w * h * 4);
        await _reader!.read(((w + 7) ~/ 8) * h);
      } else {
        throw RfbException('Unsupported encoding $encoding');
      }
    }
    // Acknowledge and request the next incremental update.
    _requestUpdate(incremental: true);
  }

  Future<void> _skipColourMap() async {
    await _reader!.read(3); // padding
    final count = _readU16(await _reader!.read(2));
    await _reader!.read(count * 6);
  }

  Future<void> _readServerCutText() async {
    await _reader!.read(3); // padding
    final len = _readU32(await _reader!.read(4));
    final bytes = await _reader!.read(len);
    onClipboard(utf8.decode(bytes, allowMalformed: true));
  }

  void sendKey(int keysym, bool down) {
    if (_closed) return;
    final msg = Uint8List(8);
    msg[0] = 4; // KeyEvent
    msg[1] = down ? 1 : 0;
    msg[4] = (keysym >> 24) & 0xFF;
    msg[5] = (keysym >> 16) & 0xFF;
    msg[6] = (keysym >> 8) & 0xFF;
    msg[7] = keysym & 0xFF;
    _socket!.add(msg);
  }

  void sendPointer(int mask, int x, int y) {
    if (_closed) return;
    final msg = Uint8List(6);
    msg[0] = 5; // PointerEvent
    msg[1] = mask & 0xFF;
    msg[2] = (x >> 8) & 0xFF;
    msg[3] = x & 0xFF;
    msg[4] = (y >> 8) & 0xFF;
    msg[5] = y & 0xFF;
    _socket!.add(msg);
  }

  void sendClipboard(String text) {
    if (_closed) return;
    final bytes = utf8.encode(text);
    final msg = BytesBuilder();
    msg.addByte(6); // ClientCutText
    msg.add([0, 0, 0]);
    msg.add([
      (bytes.length >> 24) & 0xFF,
      (bytes.length >> 16) & 0xFF,
      (bytes.length >> 8) & 0xFF,
      bytes.length & 0xFF,
    ]);
    msg.add(bytes);
    _socket!.add(msg.takeBytes());
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket?.destroy();
    _reader?.dispose();
    onClosed();
  }

  static Uint8List _vncKey(String password) {
    final key = Uint8List(8);
    final bytes = utf8.encode(password);
    for (var i = 0; i < 8; i++) {
      var b = i < bytes.length ? bytes[i] : 0;
      var reversed = 0;
      for (var bit = 0; bit < 8; bit++) {
        reversed = (reversed << 1) | (b & 1);
        b >>= 1;
      }
      key[i] = reversed;
    }
    return key;
  }

  /// The RFB pixel format we request leaves the fourth byte unused; force it
  /// to full opacity so the RGBA image is not decoded as fully transparent.
  static void _forceOpaque(Uint8List pixels) {
    for (var i = 3; i < pixels.length; i += 4) {
      pixels[i] = 0xFF;
    }
  }

  static int _readU16(Uint8List b) => (b[0] << 8) | b[1];

  static int _readU32(Uint8List b) =>
      (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

  static int _readI32(Uint8List b) {
    final value = _readU32(b);
    return value >= 0x80000000 ? value - 0x100000000 : value;
  }
}

class RfbException implements Exception {
  RfbException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Buffers socket bytes and provides exact-length reads.
class _ByteReader {
  _ByteReader(Stream<Uint8List> stream) {
    _subscription = stream.listen(
      (data) {
        _buffer.addAll(data);
        _pump();
      },
      onDone: () => _fail(StateError('Connection closed')),
      onError: (Object e) => _fail(e),
      cancelOnError: true,
    );
  }

  final List<int> _buffer = [];
  late final StreamSubscription<Uint8List> _subscription;
  final List<_PendingRead> _pending = [];
  Object? _error;
  bool _done = false;

  Future<Uint8List> read(int length) {
    if (length == 0) return Future.value(Uint8List(0));
    if (_error != null) return Future.error(_error!);
    if (_buffer.length >= length) {
      final result = Uint8List.fromList(_buffer.sublist(0, length));
      _buffer.removeRange(0, length);
      return Future.value(result);
    }
    if (_done) return Future.error(StateError('Connection closed'));
    final completer = Completer<Uint8List>();
    _pending.add(_PendingRead(length, completer));
    return completer.future;
  }

  void _pump() {
    while (_pending.isNotEmpty && _buffer.length >= _pending.first.length) {
      final pending = _pending.removeAt(0);
      final result = Uint8List.fromList(_buffer.sublist(0, pending.length));
      _buffer.removeRange(0, pending.length);
      pending.completer.complete(result);
    }
    if (_error != null && _pending.isNotEmpty) {
      final error = _error!;
      for (final pending in _pending) {
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(error);
        }
      }
      _pending.clear();
    }
  }

  void _fail(Object error) {
    _done = true;
    if (_pending.isEmpty) {
      _error = error;
      return;
    }
    for (final pending in _pending) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pending.clear();
    _error = error;
  }

  void dispose() {
    _subscription.cancel();
  }
}

class _PendingRead {
  _PendingRead(this.length, this.completer);
  final int length;
  final Completer<Uint8List> completer;
}
