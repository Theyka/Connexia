import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class SshConnection {
  final SSHClient client;
  final SSHSession shell;

  SshConnection({required this.client, required this.shell});
}

List<String> unlockKeyPems(List<Object?> args) {
  final pems = (args[0] as List).cast<String>();
  final passphrase = args[1] as String;
  final result = <String>[];
  for (final pem in pems) {
    final pairs = SSHKeyPair.fromPem(
      pem,
      passphrase.isEmpty ? null : passphrase,
    );
    for (final pair in pairs) {
      result.add(pair.toPem());
    }
  }
  return result;
}

class SshService {
  static const Duration socketTimeout = Duration(seconds: 15);
  static const Duration handshakeTimeout = Duration(seconds: 25);
  static const Duration authTimeout = Duration(seconds: 12);

  final Map<String, List<SSHKeyPair>> _identityCache = {};

  Future<List<SSHKeyPair>> _parseIdentities(
    List<String> pems,
    String? passphrase,
  ) async {
    if (pems.isEmpty) return const [];
    final cacheKey = '${pems.join('|')}|$passphrase';
    final cached = _identityCache[cacheKey];
    if (cached != null) return cached;

    final needsIsolate = pems.any((p) => SSHKeyPair.isEncryptedPem(p));
    final identities = needsIsolate
        ? await _unlockInIsolate(pems, passphrase)
        : [for (final p in pems) ...SSHKeyPair.fromPem(p, null)];
    _identityCache[cacheKey] = identities;
    return identities;
  }

  Future<List<SSHKeyPair>> _unlockInIsolate(
    List<String> pems,
    String? passphrase,
  ) async {
    final unlocked = await compute(unlockKeyPems, [pems, passphrase ?? '']);

    return [for (final pem in unlocked) ...SSHKeyPair.fromPem(pem, null)];
  }

  Future<SSHClient> connectClient({
    required String host,
    required int port,
    required String username,
    String? password,
    List<String> privateKeys = const [],
    String? passphrase,
    required Future<bool> Function(String keyType, String fingerprint)
    onVerifyHostKey,
  }) async {
    final socket = await SSHSocket.connect(host, port, timeout: socketTimeout);

    final identities = await _parseIdentities(privateKeys, passphrase);

    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: () => password,

      onUserInfoRequest: password == null
          ? null
          : (request) async => [for (final _ in request.prompts) password],
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fingerprint = utf8.decode(fingerprintBytes);
        return onVerifyHostKey(type, fingerprint);
      },
      handshakeTimeout: handshakeTimeout,
      authTimeout: authTimeout,
    );

    await client.authenticated;
    return client;
  }

  Future<SshConnection> connect({
    required String host,
    required int port,
    required String username,
    String? password,
    List<String> privateKeys = const [],
    String? passphrase,
    required Future<bool> Function(String keyType, String fingerprint)
    onVerifyHostKey,
    int terminalWidth = 80,
    int terminalHeight = 24,
  }) async {
    final client = await connectClient(
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeys: privateKeys,
      passphrase: passphrase,
      onVerifyHostKey: onVerifyHostKey,
    );

    final shell = await client.shell(
      pty: SSHPtyConfig(
        type: 'xterm-256color',
        width: terminalWidth,
        height: terminalHeight,
      ),
    );

    return SshConnection(client: client, shell: shell);
  }

  Future<SSHForwardChannel> openForwardLocalChannel(
    SSHClient client, {
    required String remoteHost,
    required int remotePort,
  }) {
    return client.forwardLocal(remoteHost, remotePort);
  }
}
