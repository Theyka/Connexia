import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:connexia/core/remote/rfb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

void main() {
  late ServerSocket server;
  late Socket? peer;
  late _ServerReader reader;

  setUp(() async {
    peer = null;
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      peer = socket;
      reader = _ServerReader(socket);
    });
  });

  tearDown(() async {
    peer?.destroy();
    await server.close();
  });

  Future<void> waitForPeer() async {
    while (peer == null) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  test('connects with None auth and receives a raw update', () async {
    final update = Completer<Uint8List>();
    final client = RfbClient(
      onFramebufferUpdate: (x, y, w, h, pixels) {
        if (!update.isCompleted) update.complete(pixels);
      },
      onDesktopResize: (_, _) {},
      onClipboard: (_) {},
      onClosed: () {},
      onError: (_) {},
      readRegion: (x, y, w, h) => Uint8List(w * h * 4),
    );

    final connectFuture = client.connect(
      InternetAddress.loopbackIPv4.address,
      server.port,
      'secret',
    );
    await waitForPeer();
    unawaited(_serverHandshake(reader, peer!, securityTypes: [1]));
    await connectFuture;
    await _waitForClientMessages(reader);
    await _sendRawUpdate(peer!);

    final pixels = await update.future.timeout(const Duration(seconds: 3));
    expect(pixels.length, 16);
    expect(pixels.first, 1);
    client.close();
  });

  test('performs VNC (DES) authentication', () async {
    final challenge = Uint8List.fromList(
      List.generate(16, (i) => (i * 7) & 0xFF),
    );
    var responseOk = false;

    final client = RfbClient(
      onFramebufferUpdate: (x, y, w, h, pixels) {},
      onDesktopResize: (_, _) {},
      onClipboard: (_) {},
      onClosed: () {},
      onError: (_) {},
      readRegion: (x, y, w, h) => Uint8List(w * h * 4),
    );

    final connectFuture = client.connect(
      InternetAddress.loopbackIPv4.address,
      server.port,
      'secret',
    );
    await waitForPeer();

    final socket = peer!;
    unawaited(() async {
      socket.add('RFB 003.008\n'.codeUnits);
      await reader.read(12); // client version
      socket.add([1, 2]); // one security type: VNC auth
      await reader.read(1); // chosen type
      socket.add(challenge);
      final response = await reader.read(16);
      responseOk = _bytesEqual(response, _desEncrypt(challenge, 'secret'));
      socket.add([0, 0, 0, 0]); // success
      await _sendServerInit(socket);
    }());

    await connectFuture;
    expect(responseOk, isTrue);
    client.close();
  });
}

Future<void> _serverHandshake(
  _ServerReader reader,
  Socket socket, {
  required List<int> securityTypes,
}) async {
  socket.add('RFB 003.008\n'.codeUnits);
  await reader.read(12);
  socket.add([securityTypes.length, ...securityTypes]);
  await reader.read(1); // chosen type
  await reader.read(1); // client init
  await _sendServerInit(socket);
}

Future<void> _sendServerInit(Socket socket) async {
  final msg = BytesBuilder();
  msg.add([0, 2, 0, 2]); // 2x2
  msg.add([32, 24, 0, 1]);
  msg.add([0, 255, 0, 255, 0, 255]);
  msg.add([0, 8, 16, 0, 0, 0]);
  msg.add([0, 0, 0, 0]); // name length 0
  socket.add(msg.takeBytes());
}

Future<void> _waitForClientMessages(_ServerReader reader) async {
  var requests = 0;
  while (requests < 1) {
    final type = (await reader.read(1))[0];
    switch (type) {
      case 0:
        await reader.read(19);
      case 2:
        final header = await reader.read(3);
        final count = (header[1] << 8) | header[2];
        await reader.read(count * 4);
      case 3:
        await reader.read(9);
        requests++;
      case 4:
        await reader.read(7);
      case 5:
        await reader.read(5);
      case 6:
        final header = await reader.read(7);
        final len =
            (header[3] << 24) |
            (header[4] << 16) |
            (header[5] << 8) |
            header[6];
        await reader.read(len);
      default:
        throw StateError('unexpected client message $type');
    }
  }
}

Future<void> _sendRawUpdate(Socket socket) async {
  final msg = BytesBuilder();
  msg.addByte(0); // FramebufferUpdate
  msg.addByte(0); // padding
  msg.add([0, 1]); // one rect
  msg.add([0, 0]); // x
  msg.add([0, 0]); // y
  msg.add([0, 2]); // w
  msg.add([0, 2]); // h
  msg.add([0, 0, 0, 0]); // raw encoding
  msg.add(List.generate(16, (i) => i + 1));
  socket.add(msg.takeBytes());
}

Uint8List _desEncrypt(Uint8List challenge, String password) {
  final key = _vncKey(password);
  final key24 = Uint8List(24);
  key24.setRange(0, 8, key);
  key24.setRange(8, 16, key);
  key24.setRange(16, 24, key);
  final engine = pc.ECBBlockCipher(pc.DESedeEngine())
    ..init(true, pc.KeyParameter(key24));
  final out = Uint8List(16);
  for (var block = 0; block < 2; block++) {
    engine.processBlock(challenge, block * 8, out, block * 8);
  }
  return out;
}

Uint8List _vncKey(String password) {
  final key = Uint8List(8);
  final bytes = password.codeUnits;
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

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _ServerReader {
  _ServerReader(Stream<Uint8List> stream) {
    stream.listen(_buffer.addAll);
  }

  final List<int> _buffer = [];

  Future<Uint8List> read(int length) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_buffer.length < length) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('timed out waiting for $length bytes');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return result;
  }
}
