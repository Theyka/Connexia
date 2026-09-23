import 'dart:io';

import 'package:connexia/core/telnet/telnet_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServerSocket server;
  late Socket? serverSide;
  final fromClient = <int>[];

  Future<void> setupServer() async {
    fromClient.clear();
    serverSide = null;
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      serverSide = socket;
      socket.listen(fromClient.addAll, onError: (_) {});
    });
  }

  Future<TelnetConnection> connect() async {
    final conn = await TelnetConnection.connect(
      InternetAddress.loopbackIPv4.address,
      server.port,
    );
    // Wait for the server to observe the connection.
    for (var i = 0; i < 100 && serverSide == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return conn;
  }

  Future<List<int>> waitForClientBytes(
    List<int> needle, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_contains(fromClient, needle)) return List<int>.of(fromClient);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting for $needle in $fromClient');
  }

  Future<List<int>> collectOutput(
    TelnetConnection conn, {
    Duration settle = const Duration(milliseconds: 150),
  }) async {
    final out = <int>[];
    final sub = conn.output.listen(out.addAll);
    await Future<void>.delayed(settle);
    await sub.cancel();
    return out;
  }

  setUp(setupServer);
  tearDown(() async {
    serverSide?.destroy();
    await server.close();
  });

  test('strips negotiation and forwards application data', () async {
    final conn = await connect();
    serverSide!.add([0xFF, 0xFD, 31]); // IAC DO NAWS
    serverSide!.add('hello'.codeUnits);
    final out = await collectOutput(conn);
    expect(String.fromCharCodes(out), contains('hello'));
    expect(out.where((b) => b == 0xFF), isEmpty);
    conn.close();
  });

  test('server WILL ECHO is answered with DO ECHO', () async {
    final conn = await connect();
    serverSide!.add([0xFF, 0xFB, 1]); // IAC WILL ECHO
    await waitForClientBytes([0xFF, 0xFD, 1]);
    conn.close();
  });

  test('escaped IAC (0xFF 0xFF) is delivered as a single 0xFF', () async {
    final conn = await connect();
    serverSide!.add([0xFF, 0xFF, 0x41]);
    final out = await collectOutput(conn);
    expect(out, [0xFF, 0x41]);
    conn.close();
  });

  test('subnegotiation is consumed and answered', () async {
    final conn = await connect();
    serverSide!.add([
      0xFF,
      0xFA,
      24,
      1,
      0xFF,
      0xF0,
    ]); // IAC SB TTYPE SEND IAC SE
    await waitForClientBytes([0xFF, 0xFA, 24, 0]);
    final out = await collectOutput(
      conn,
      settle: const Duration(milliseconds: 50),
    );
    expect(out, isEmpty);
    conn.close();
  });

  test('write escapes 0xFF and done completes on close', () async {
    final conn = await connect();
    conn.write([0x41, 0xFF, 0x42]);
    await waitForClientBytes([0x41, 0xFF, 0xFF, 0x42]);
    var done = false;
    conn.done.then((_) => done = true);
    serverSide!.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(done, isTrue);
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
