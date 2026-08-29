import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// Result of a successful SSH connection with an interactive shell.
class SshConnection {
  final SSHClient client;
  final SSHSession shell;

  SshConnection({
    required this.client,
    required this.shell,
  });
}

/// Parses and decrypts private keys off the UI thread. [SSHKeyPair.fromPem]
/// runs OpenSSH's bcrypt_pbkdf synchronously when the key is passphrase
/// protected, which blocks the caller for seconds. The parsed key pairs are
/// re-serialized unencrypted inside the isolate so only cheap parsing
/// happens on the main thread afterwards.
List<String> unlockKeyPems(List<Object?> args) {
  final pems = (args[0] as List).cast<String>();
  final passphrase = args[1] as String;
  final result = <String>[];
  for (final pem in pems) {
    final pairs =
        SSHKeyPair.fromPem(pem, passphrase.isEmpty ? null : passphrase);
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

  /// Parsed identities keyed by their PEM content + passphrase, so hosts
  /// sharing one identity never re-run the (expensive) key parse.
  final Map<String, List<SSHKeyPair>> _identityCache = {};

  Future<List<SSHKeyPair>> _parseIdentities(
    List<String> pems,
    String? passphrase,
  ) async {
    if (pems.isEmpty) return const [];
    final cacheKey = '${pems.join('|')}|$passphrase';
    final cached = _identityCache[cacheKey];
    if (cached != null) return cached;

    // Unencrypted keys parse instantly on the main thread; only encrypted
    // keys need the bcrypt dance, which runs off-thread.
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
    // bcrypt_pbkdf (OpenSSH encrypted keys) runs inside the isolate.
    final unlocked = await compute(
      unlockKeyPems,
      [pems, passphrase ?? ''],
    );
    // The isolate returns unencrypted PEMs; null passphrase because these
    // keys no longer require one (and dartssh2 rejects a non-null one).
    return [for (final pem in unlocked) ...SSHKeyPair.fromPem(pem, null)];
  }

  /// Establishes an SSH connection and authenticates without opening a
  /// shell. Used for connection types that don't need a PTY, such as SFTP.
  ///
  /// [onVerifyHostKey] receives the key type and OpenSSH-style fingerprint
  /// (e.g. `SHA256:...`) and must return true to accept the host key.
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
    final socket = await SSHSocket.connect(
      host,
      port,
      timeout: socketTimeout,
    );

    final identities = await _parseIdentities(privateKeys, passphrase);

    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: () => password,
      // Hardened servers often disable plain password auth and only accept
      // keyboard-interactive (PAM). Answer every prompt with the stored
      // password so those servers still work without user interaction.
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

  /// Establishes an SSH connection, authenticates and opens an interactive
  /// shell with a PTY.
  ///
  /// [onVerifyHostKey] receives the key type and OpenSSH-style fingerprint
  /// (e.g. `SHA256:...`) and must return true to accept the host key.
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

    return SshConnection(
      client: client,
      shell: shell,
    );
  }

  /// Opens one direct-tcpip channel for a local forward rule. The caller
  /// supplies the already-authenticated [client]; this is just a thin
  /// wrapper around [SSHClient.forwardLocal].
  Future<SSHForwardChannel> openForwardLocalChannel(
    SSHClient client, {
    required String remoteHost,
    required int remotePort,
  }) {
    return client.forwardLocal(remoteHost, remotePort);
  }
}
