import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';

/// Computes the OpenSSH-style SHA256 fingerprint (`SHA256:...`) of the
/// public key derived from a PEM private key. Returns null if the PEM cannot
/// be parsed (e.g. it is still encrypted with a passphrase).
Future<String?> computeKeyFingerprint(String pemText) async {
  try {
    final pairs = SSHKeyPair.fromPem(pemText, '');
    if (pairs.isEmpty) return null;
    final blob = pairs.first.toPublicKey().encode();
    final digest = await Sha256().hash(blob);
    final encoded = base64.encode(digest.bytes).replaceAll('=', '');
    return 'SHA256:$encoded';
  } catch (_) {
    return null;
  }
}

/// Best-effort human label for an SSH key type.
String shortKeyType(String type) {
  if (type.startsWith('ecdsa-')) return 'ECDSA';
  if (type == 'ssh-ed25519') return 'Ed25519';
  if (type == 'ssh-rsa' || type == 'rsa-sha2-256' || type == 'rsa-sha2-512') {
    return 'RSA';
  }
  return type;
}

/// Builds the OpenSSH public key line (`type base64 [comment]`) from a PEM
/// private key. Returns null when the key cannot be parsed.
String? publicKeyFromPem(String pemText, {String comment = ''}) {
  try {
    final pairs = SSHKeyPair.fromPem(pemText, '');
    if (pairs.isEmpty) return null;
    final pub = pairs.first.toPublicKey();
    final blob = pub.encode();
    final type = pairs.first.type;
    final encoded = base64.encode(blob);
    final suffix = comment.isEmpty ? '' : ' $comment';
    return '$type $encoded$suffix';
  } catch (_) {
    return null;
  }
}

/// SSH key types that can be generated.
enum GenKeyType {
  ed25519('ED25519', 'ed25519', 'OpenSSH 6.5+'),
  ecdsa('ECDSA', 'ecdsa', 'OpenSSH 5.7+'),
  rsa('RSA', 'rsa', 'Legacy devices'),
  mlDsa('ML-DSA', 'ml-dsa-87', 'Supported only on ML-DSA-enabled servers');

  const GenKeyType(this.label, this.sshFlag, this.info);

  final String label;
  final String sshFlag;
  final String info;
}

/// Ciphers used to protect generated private keys (OpenSSH `-Z` names).
const genKeyCiphers = [
  (label: 'AES-256', sshName: 'aes256-ctr'),
  (label: 'AES-128', sshName: 'aes128-ctr'),
  (label: '3DES', sshName: '3des-cbc'),
  (label: 'DES', sshName: 'des-cbc'),
];

/// Result of a successful key generation.
class GeneratedKey {
  final String privatePem;
  final String publicKey;

  const GeneratedKey({required this.privatePem, required this.publicKey});
}

/// Locates the OpenSSH `ssh-keygen` binary shipped with Windows.
String? _findSshKeygen() {
  const candidates = [
    r'C:\Windows\System32\OpenSSH\ssh-keygen.exe',
    r'C:\Program Files\OpenSSH\bin\ssh-keygen.exe',
    r'C:\Program Files (x86)\OpenSSH\bin\ssh-keygen.exe',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Generates a new SSH key pair by invoking OpenSSH's `ssh-keygen`.
///
/// [type] selects the key type. [bitSize] applies to RSA (bits) and ECDSA
/// (curve size). [rounds] is the KDF round count for ED25519. [passphrase]
/// protects the private key with [cipher]. Returns the private key PEM and
/// the public key text, or throws a [GenKeyException] on failure.
Future<GeneratedKey> generateSshKey({
  required GenKeyType type,
  int? bitSize,
  int? rounds,
  String? passphrase,
  required String cipher,
  String? comment,
}) async {
  final sshKeygen = _findSshKeygen();
  if (sshKeygen == null) {
    throw GenKeyException(
      'OpenSSH is not installed. Install the Windows OpenSSH client to '
      'generate keys, or import a key instead.',
    );
  }

  final dir = await Directory.systemTemp.createTemp('connexia_keygen');
  final keyPath = '${dir.path}${Platform.pathSeparator}id_key';

  final args = <String>['-q', '-t', type.sshFlag, '-f', keyPath];
  args.add('-N');
  args.add(passphrase ?? '');
  if (bitSize != null) {
    args.addAll(['-b', '$bitSize']);
  }
  if (rounds != null) {
    args.addAll(['-a', '$rounds']);
  }
  args.add('-o');
  if (passphrase != null && passphrase.isNotEmpty) {
    args.addAll(['-Z', cipher]);
  }
  if (comment != null && comment.isNotEmpty) {
    args.addAll(['-C', comment]);
  }

  try {
    final result = await Process.run(sshKeygen, args);
    if (result.exitCode != 0) {
      throw GenKeyException(
        'ssh-keygen could not create a ${type.label} key'
        '${type == GenKeyType.mlDsa ? '. ML-DSA requires OpenSSH 9.9 or newer.' : ''}'
        '\n\n${(result.stderr as String).trim()}',
      );
    }

    final privateFile = File(keyPath);
    final pubFile = File('$keyPath.pub');
    if (!privateFile.existsSync() || !pubFile.existsSync()) {
      throw GenKeyException('ssh-keygen did not produce a key file.');
    }

    return GeneratedKey(
      privatePem: await privateFile.readAsString(),
      publicKey: (await pubFile.readAsString()).trim(),
    );
  } on GenKeyException {
    rethrow;
  } catch (e) {
    throw GenKeyException('Could not run ssh-keygen: $e');
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

class GenKeyException implements Exception {
  final String message;

  const GenKeyException(this.message);

  @override
  String toString() => message;
}
